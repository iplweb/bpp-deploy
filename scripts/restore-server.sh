#!/usr/bin/env bash
#
# Odtworzenie CALEGO serwera BPP z kopii ZDALNEJ (rclone) na czystej maszynie,
# takze gdy Docker Hub / GitHub nie dzialaja - i proba tego samego obok
# produkcji.
#
#   make restore-server        # czysta maszyna: Docker + repo (git clone albo
#                              # git clone z bpp-deploy.bundle), BEZ `make`
#   make proba-odtworzenia     # proba na serwerze produkcyjnym: shadow stack
#                              # bpp-shadow-*, produkcja nietknieta
#
# Przebieg (wspolny):
#   1. dostep do kopii: istniejacy rclone.conf albo kreator `rclone config`;
#      remote spoza rclone.conf = ad hoc crypt (sciezka zaszyfrowanych danych
#      + haslo crypt czytane ze stdin, NIGDY w argv - trafia do srodowiska
#      procesu rclone jako RCLONE_CONFIG_BPPODTW_PASSWORD),
#   2. wybor NAJNOWSZEGO KOMPLETU z jednej nocy: db + media + config z tym
#      samym TIMESTAMP (DATA=YYYYMMDD albo YYYYMMDD-HHMMSS wybiera noc),
#   3. pobranie i weryfikacja (gzip/tar, toc.dat, .env w archiwum,
#      `pg_restore --list` w obrazie bazy),
#   4. konfiguracja przez scripts/restore-config.sh (PRZED jakimkolwiek
#      `make` - inaczej init-configs wygenerowalby NOWY klucz szyfrowania),
#   5. obrazy z archiwum REMOTE:obrazy/ (scripts/images-load.sh); bez
#      archiwum `docker pull` dokladnie wersji z manifestu (repo@digest) albo
#      z .env (DOCKER_VERSION),
#   6. baza + media przez scripts/restore.sh, potem `make up`,
#   7. /health/ i / appservera; linia wyniku do $BPP_CONFIGS_DIR/logs/.
#
# Proba (--proba): kroki 1-3 i weryfikacja konfiguracji/archiwum obrazow jak
# wyzej, ale baza, media i appserver lada w shadow stacku (scripts/lib-shadow.sh,
# ta sama blokada co test-upgrade), konfiguracja w katalogu tymczasowym. Zero
# zapisu do .env, produkcyjnych wolumenow, kontenerow i tagow obrazow (bez
# `docker load` - przepialby produkcyjne `latest`). Nic nie jest nigdzie
# wysylane: rclone tylko czyta, kanaly powiadomien shadowa sa wyzerowane.
#
# Zmienne (make przekazuje je z linii polecen):
#   DATA            - noc: YYYYMMDD albo YYYYMMDD-HHMMSS (domyslnie najnowsza kompletna)
#   RCLONE_CONF     - sciezka do rclone.conf (pusta = pytanie / kreator)
#   REMOTE          - remote z kopiami (domyslnie z .env albo backup_enc:)
#   CRYPT_REMOTE    - wymus ad hoc crypt: sciezka zaszyfrowanych danych (np. gdrive:bpp)
#   BPP_CONFIGS_DIR - katalog konfiguracyjny do odtworzenia (pytanie, gdy pusty)
#   OBRAZY          - auto (domyslnie) | archiwum | pull
#   STAGE_DIR       - gdzie pobrac kopie (domyslnie: obok katalogu konfiguracyjnego)
#   KEEP_SHADOW     - proba: 1 zostaw shadow po bledzie, 0 sprzataj (domyslnie: TTY)
#
# Exit: 0 OK, 1 blad, 2 inna proba shadow trwa (tylko --proba).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-rclone.sh
. "$REPO_DIR/scripts/lib-rclone.sh"
# shellcheck source=scripts/lib-shadow.sh
. "$REPO_DIR/scripts/lib-shadow.sh"
# shellcheck source=scripts/lib-config-path.sh
. "$REPO_DIR/scripts/lib-config-path.sh"

# Furtki WYLACZNIE dla scripts/test-restore-server.sh.
RESTORE_CONFIG_SH="${BPP_RESTORE_CONFIG_SH:-$REPO_DIR/scripts/restore-config.sh}"
RESTORE_SH="${BPP_RESTORE_SH:-$REPO_DIR/scripts/restore.sh}"
IMAGES_LOAD_SH="${BPP_IMAGES_LOAD_SH:-$REPO_DIR/scripts/images-load.sh}"
REPO_ENV="${BPP_REPO_ENV_FILE:-$REPO_DIR/.env}"
RCLONE_IMAGE="${BPP_RCLONE_IMAGE:-rclone/rclone:1.71.0}"
HELPER_IMAGE="${BPP_HELPER_IMAGE:-${BPP_ORCHESTRATOR_IMAGE:-docker:28-cli}}"

MODE=real
[ "${1:-}" = "--proba" ] && MODE=proba

START_TS="$(date +%s)"
DATA="${DATA:-}"
OBRAZY="${OBRAZY:-auto}"
case "$OBRAZY" in auto|archiwum|pull) ;; *) echo "BLAD: OBRAZY=auto|archiwum|pull (jest: $OBRAZY)" >&2; exit 1 ;; esac
case "$DATA" in
    ''|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) echo "BLAD: DATA ma postac YYYYMMDD albo YYYYMMDD-HHMMSS (jest: $DATA)" >&2; exit 1 ;;
esac

say()  { printf '%s\n' "$*"; }
krok() { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'BLAD: %s\n' "$*" >&2; exit 1; }

# Odczyt zmiennej z pliku .env (ta sama konwencja co restore.sh/test-upgrade.sh).
env_get() {   # <plik> <ZMIENNA>
    local raw
    raw="$(grep -E "^${2}=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    raw="${raw%$'\r'}"
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then raw="${raw#\"}"; raw="${raw%\"}"; fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then raw="${raw#\'}"; raw="${raw%\'}"; fi
    printf '%s' "$raw"
}

ask() {   # <pytanie> -> REPLY (EOF = pusta odpowiedz)
    printf '%s' "$1" >&2
    REPLY=""
    IFS= read -r REPLY || true
}

# ---------------------------------------------------------------------------
# rclone: binarka hosta (dziala bez Docker Huba) albo obraz rclone.
# ---------------------------------------------------------------------------
# Sekrety wylacznie w SRODOWISKU procesu rclone (`docker run -e VAR` bez
# wartosci). Kopie laduja w $STAGE (host) == /stage (kontener).
RC_ENV_NAMES=()
RC_MODE="${BPP_RESTORE_RCLONE:-}"
RC_CONF=""
STAGE=""

rclone() {
    if [ "$RC_MODE" = host ]; then
        command rclone --config "$RC_CONF" "$@"
    else
        local envargs=() n
        # -t tylko przy terminalu na obu koncach (kreator `rclone config`);
        # w `$( )` stdout to potok i -t popsulby wynik.
        if [ -t 0 ] && [ -t 1 ]; then envargs+=(-t); fi
        for n in "${RC_ENV_NAMES[@]+"${RC_ENV_NAMES[@]}"}"; do envargs+=(-e "$n"); done
        # Jako root (konfiguracja produkcyjna bywa root:root 0600), ale pliki
        # oddajemy uzytkownikowi - sprzatanie i dalsze kroki ida z jego konta.
        # shellcheck disable=SC2016  # rozwija sh w kontenerze
        docker run --rm -i "${envargs[@]+"${envargs[@]}"}" \
            -e BPP_UID="$(id -u):$(id -g)" -e RCLONE_CACHE_DIR=/tmp/rclone-cache \
            -v "$(dirname "$RC_CONF")":/config/rclone \
            -v "$STAGE":/stage \
            --entrypoint sh "$RCLONE_IMAGE" -c \
            'rclone --config "/config/rclone/$0" "$@"; rc=$?; chown -R "$BPP_UID" /stage 2>/dev/null; exit $rc' \
            "$(basename "$RC_CONF")" "$@"
    fi
}
stage_path() { if [ "$RC_MODE" = host ]; then printf '%s/%s' "$STAGE" "$1"; else printf '/stage/%s' "$1"; fi; }

setup_rclone() {
    if [ -z "$RC_MODE" ]; then
        if [ "$MODE" = real ] && command -v rclone >/dev/null 2>&1; then RC_MODE=host; else RC_MODE=docker; fi
    fi
    say "rclone: $([ "$RC_MODE" = host ] && echo "binarka hosta ($(command -v rclone))" || echo "obraz $RCLONE_IMAGE")"

    local conf="${RCLONE_CONF:-}"
    if [ "$MODE" = proba ] && [ -z "$conf" ]; then
        conf="$CFG_DIR/rclone/rclone.conf"
    fi
    if [ -z "$conf" ]; then
        ask "Sciezka do istniejacego rclone.conf (Enter = kreator 'rclone config'): "
        conf="$(normalize_config_path "$REPLY")"
    fi
    if [ "$MODE" = proba ]; then
        # Produkcyjny plik, RW: odswiezony token OAuth musi trafic tam, gdzie
        # czyta go nocny cykl (Box: refresh token jest jednorazowy).
        [ -f "$conf" ] || die "brak $conf - skonfiguruj: make rclone-config"
        RC_CONF="$conf"
    else
        RC_CONF="$WORK/rclone/rclone.conf"
        mkdir -p "$WORK/rclone"
        if [ -n "$conf" ]; then
            [ -f "$conf" ] || die "nie ma pliku $conf"
            cp "$conf" "$RC_CONF"
            RC_CONF_ZRODLO="$conf"
        else
            [ -t 0 ] || die "kreator rclone wymaga terminala - podaj RCLONE_CONF=/sciezka/rclone.conf"
            : > "$RC_CONF"
            say "Uruchamiam kreator rclone (zapis do $RC_CONF)..."
            rclone config
            RC_CONF_ZRODLO="kreator"
        fi
        chmod 600 "$RC_CONF"
    fi

    if [ -z "${REMOTE:-}" ]; then
        local dom="backup_enc:"
        [ "$MODE" = proba ] && dom="$(env_get "$CFG_DIR/.env" DJANGO_BPP_RCLONE_REMOTE)"
        dom="${dom:-backup_enc:}"
        if [ "$MODE" = real ]; then
            ask "Remote z kopiami [$dom]: "
            REMOTE="${REPLY:-$dom}"
        else
            REMOTE="$dom"
        fi
    fi

    local nazwa="${REMOTE%%:*}"
    if [ -z "${CRYPT_REMOTE:-}" ] && [ "$MODE" = real ] \
            && ! rclone listremotes 2>/dev/null | grep -qx "$nazwa:"; then
        say "Remote '$nazwa:' nie istnieje w rclone.conf."
        ask "Zdalna sciezka ZASZYFROWANYCH danych (np. gdrive:bpp-backup; Enter = przerwij): "
        [ -n "$REPLY" ] || die "brak remote'a z kopiami"
        CRYPT_REMOTE="$REPLY"
    fi
    if [ -n "${CRYPT_REMOTE:-}" ]; then
        local haslo haslo2
        printf 'Haslo crypt (nie bedzie widoczne): ' >&2
        IFS= read -rs haslo || true; printf '\n' >&2
        printf 'Drugie haslo crypt / sol (Enter = brak): ' >&2
        IFS= read -rs haslo2 || true; printf '\n' >&2
        [ -n "$haslo" ] || die "puste haslo crypt"
        # `rclone obscure -` czyta haslo ze STDIN - nie z argv.
        RCLONE_CONFIG_BPPODTW_TYPE=crypt
        RCLONE_CONFIG_BPPODTW_REMOTE="$CRYPT_REMOTE"
        RCLONE_CONFIG_BPPODTW_PASSWORD="$(printf '%s' "$haslo" | rclone obscure -)"
        export RCLONE_CONFIG_BPPODTW_TYPE RCLONE_CONFIG_BPPODTW_REMOTE RCLONE_CONFIG_BPPODTW_PASSWORD
        RC_ENV_NAMES+=(RCLONE_CONFIG_BPPODTW_TYPE RCLONE_CONFIG_BPPODTW_REMOTE RCLONE_CONFIG_BPPODTW_PASSWORD)
        if [ -n "$haslo2" ]; then
            RCLONE_CONFIG_BPPODTW_PASSWORD2="$(printf '%s' "$haslo2" | rclone obscure -)"
            export RCLONE_CONFIG_BPPODTW_PASSWORD2
            RC_ENV_NAMES+=(RCLONE_CONFIG_BPPODTW_PASSWORD2)
        fi
        unset haslo haslo2
        REMOTE="bppodtw:"
        RC_CONF_ZRODLO="crypt-ad-hoc"
    fi
    BASE="$(rclone_base "$REMOTE")"
    say "Kopie: $REMOTE"
}

# ---------------------------------------------------------------------------
# Wybor kompletu: najnowsza noc z db + media + config o tym samym TIMESTAMP.
# ---------------------------------------------------------------------------
TS=""; TS_MIESIAC=""
wybierz_komplet() {
    local miesiace m pliki ts t brak niekompletne=""
    if ! miesiace="$(rclone_list_month_dirs "$BASE" 2>"$WORK/lsf.err")"; then
        cat "$WORK/lsf.err" >&2 || true
        die "nie moge wylistowac $REMOTE (zly remote albo brak dostepu)"
    fi
    if [ -z "$miesiace" ]; then
        die "w $REMOTE nie ma ani jednego katalogu YYYY-MM. Przy remote crypt to zwykle
       ZLE HASLO (rclone nie odszyfruje nazw i nic nie pokaze), ewentualnie zly
       remote albo pusta kopia."
    fi
    if [ -n "$DATA" ]; then
        m="${DATA:0:4}-${DATA:4:2}"
        printf '%s\n' "$miesiace" | grep -qx "$m" || die "brak katalogu $m w $REMOTE (DATA=$DATA)"
        miesiace="$m"
    fi
    for m in $(printf '%s\n' "$miesiace" | sort -r); do
        pliki="$(rclone lsf "$BASE$m/" --files-only)" || die "nie moge wylistowac $BASE$m/"
        # Timestampy nocy, ktore maja ktorykolwiek z trzech plikow.
        for ts in $(printf '%s\n' "$pliki" \
                | sed -nE 's/^(db|media|config)-backup-([0-9]{8}-[0-9]{6})\.tar\.gz$/\2/p' \
                | sort -u -r); do
            case "$DATA" in ''|"$ts"|"${ts%%-*}") ;; *) continue ;; esac
            brak=""
            for t in db media config; do
                printf '%s\n' "$pliki" | grep -qx "$t-backup-$ts.tar.gz" || brak="$brak $t"
            done
            if [ -z "$brak" ]; then
                TS="$ts"; TS_MIESIAC="$m"
                [ -z "$niekompletne" ] || say "UWAGA: nowsze NIEKOMPLETNE noce pominiete:$niekompletne"
                return 0
            fi
            niekompletne="$niekompletne
  $ts (brak:$brak)"
        done
        # Bez DATA szukamy dalej w starszych miesiacach.
    done
    if [ -n "$DATA" ]; then
        die "noc DATA=$DATA nie ma kompletu db+media+config:${niekompletne:- brak jakichkolwiek plikow z ta data}"
    fi
    die "w $REMOTE nie ma ani jednej kompletnej nocy (db + media + config z tym samym TIMESTAMP).${niekompletne:+
Niekompletne:$niekompletne}
Kopie sprzed backupu konfiguracji (config-backup) nie wystarcza do odtworzenia serwera."
}

pobierz_komplet() {
    local t
    mkdir -p "$STAGE/dane"
    for t in db media config; do
        say "Pobieram $t-backup-$TS.tar.gz ..."
        rclone copyto "$BASE$TS_MIESIAC/$t-backup-$TS.tar.gz" "$(stage_path "dane/$t-backup-$TS.tar.gz")" \
            || die "pobranie $t-backup-$TS.tar.gz nie powiodlo sie"
    done
}

weryfikuj_archiwa() {
    local d="$STAGE/dane" lista
    say "Sprawdzam archiwa (gzip/tar)..."
    lista="$(tar tzf "$d/db-backup-$TS.tar.gz")" || die "db-backup-$TS.tar.gz uszkodzony"
    printf '%s\n' "$lista" | grep -q "^db-backup-$TS/toc.dat$" \
        || die "db-backup-$TS.tar.gz nie zawiera db-backup-$TS/toc.dat (to nie jest zrzut pg_dump -Fd)"
    tar tzf "$d/media-backup-$TS.tar.gz" >/dev/null || die "media-backup-$TS.tar.gz uszkodzony"
    lista="$(tar tzf "$d/config-backup-$TS.tar.gz")" || die "config-backup-$TS.tar.gz uszkodzony"
    printf '%s\n' "$lista" | grep -qxE '(\./)?\.env' || die "config-backup-$TS.tar.gz nie zawiera .env"
    say "Archiwa OK."
}

# pg_restore --list w obrazie bazy: rozpakowujemy tylko toc.dat (tar i tak
# czyta caly strumien gzip, wiec integralnosc jest sprawdzona w calosci).
pg_restore_list() {   # <obraz>
    say "pg_restore --list (obraz $1)..."
    # shellcheck disable=SC2016  # rozwija sh w kontenerze
    docker run --rm -v "$STAGE/dane":/s:ro --entrypoint sh "$1" -c \
        'set -e; mkdir -p /tmp/x; tar xzf "/s/$1.tar.gz" -C /tmp/x "$1/toc.dat"; pg_restore --list "/tmp/x/$1" > /tmp/x/lista; echo "  obiektow w TOC: $(grep -vc "^;" /tmp/x/lista)"' \
        sh "db-backup-$TS" || die "pg_restore --list nie przeczytal zrzutu db-backup-$TS"
}

# ---------------------------------------------------------------------------
# Archiwum obrazow: zestaw z REMOTE:obrazy/ nie nowszy niz kopia (to na nich
# dzialal serwer tamtej nocy); gdy wszystkie nowsze - najstarszy dostepny.
# ---------------------------------------------------------------------------
OBRAZY_SET=""; OBRAZY_DIR=""
pobierz_obrazy() {
    local sets
    [ "$OBRAZY" != pull ] || { say "OBRAZY=pull - pomijam archiwum obrazow."; return 1; }
    sets="$(rclone_list_image_sets "${BASE}obrazy/" 2>/dev/null || true)"
    if [ -z "$sets" ]; then
        say "Brak archiwum obrazow w ${BASE}obrazy/."
        [ "$OBRAZY" = archiwum ] && die "OBRAZY=archiwum, a archiwum nie ma"
        return 1
    fi
    OBRAZY_SET="$(printf '%s\n' "$sets" | awk -v ts="$TS" '$0 <= ts' | sed -n '$p')"
    [ -n "$OBRAZY_SET" ] || OBRAZY_SET="$(printf '%s\n' "$sets" | sed -n '1p')"
    OBRAZY_DIR="$STAGE/obrazy/$OBRAZY_SET"
    mkdir -p "$OBRAZY_DIR"
    say "Pobieram zestaw obrazow $OBRAZY_SET ..."
    if ! rclone copy "${BASE}obrazy/$OBRAZY_SET/" "$(stage_path "obrazy/$OBRAZY_SET")"; then
        [ "$OBRAZY" = archiwum ] && die "pobranie zestawu obrazow nie powiodlo sie"
        say "UWAGA: pobranie zestawu obrazow nie powiodlo sie."
        return 1
    fi
    return 0
}

# docker pull DOKLADNIE wersji: z manifestu (repo@digest + tag na ref compose),
# a bez manifestu - to, co wskazuje .env (DOCKER_VERSION) przez compose.
pull_obrazow() {
    local man="$OBRAZY_DIR/manifest.txt" typ ref _sr _id _w dig _rest
    if [ -n "$OBRAZY_DIR" ] && [ -f "$man" ]; then
        say "docker pull wersji z manifestu $OBRAZY_SET ..."
        while IFS='|' read -r typ ref _sr _id _w dig _rest; do
            [ "$typ" = obraz ] || continue
            if [ "$dig" != - ]; then
                docker pull "$dig" || die "docker pull $dig nie powiodl sie"
                docker tag "$dig" "$ref"
            else
                docker pull "$ref" || die "docker pull $ref nie powiodl sie"
            fi
        done < "$man"
    else
        say "docker pull wersji z .env (DOCKER_VERSION=$(env_get "$CFG_DIR/.env" DOCKER_VERSION | sed 's/^$/latest/'))..."
        make -C "$REPO_DIR" pull || die "make pull nie powiodl sie (Docker Hub niedostepny? potrzebne archiwum obrazow)"
    fi
}

zapisz_wynik() {   # <wynik> <opis>
    local czas=$(( $(date +%s) - START_TS )) linia plik
    linia="| $(date +%Y-%m-%d) | $([ "$MODE" = proba ] && echo proba || echo odtworzenie) | kopia ${TS:0:4}-${TS:4:2}-${TS:6:2} ${TS:9:2}:${TS:11:2} | $((czas / 60)) min $((czas % 60)) s | $1 | $2 |"
    say ""
    say "WYNIK (do wklejenia do dokumentacji):"
    say "$linia"
    plik="$CFG_DIR/logs/odtworzenie-serwera.log"
    if mkdir -p "$CFG_DIR/logs" 2>/dev/null && printf '%s\n' "$linia" >> "$plik" 2>/dev/null; then
        say "Zapisano w $plik"
    else
        say "UWAGA: nie udalo sie zapisac $plik"
    fi
}

# ===========================================================================
if [ "$MODE" = proba ]; then
    # ---------------------------- PROBA -----------------------------------
    [ -f "$REPO_ENV" ] || die "proba dziala na serwerze z konfiguracja (brak $REPO_ENV); na czystej maszynie: make restore-server"
    CFG_DIR="${BPP_CONFIGS_DIR:-$(env_get "$REPO_ENV" BPP_CONFIGS_DIR)}"
    [ -f "$CFG_DIR/.env" ] || die "brak $CFG_DIR/.env"
    PROD_ENV="$CFG_DIR/.env"
    HOST_BACKUP_DIR="$(env_get "$PROD_ENV" DJANGO_BPP_HOST_BACKUP_DIR)"
    [ -n "$HOST_BACKUP_DIR" ] || HOST_BACKUP_DIR="$(env_get "$PROD_ENV" DJANGO_BPP_BACKUP_DIR)"
    [ -n "$HOST_BACKUP_DIR" ] || HOST_BACKUP_DIR="$(cd "$CFG_DIR/.." && pwd)/backups"
    if [ -z "${KEEP_SHADOW:-}" ]; then
        if [ -t 0 ]; then KEEP_SHADOW=1; else KEEP_SHADOW=0; fi
    fi

    shadow_lock_acquire
    STAGE="${STAGE_DIR:-$HOST_BACKUP_DIR/.proba-odtworzenia-$(date +%Y%m%d-%H%M%S)}"
    WORK="$STAGE/praca"
    SHADOW_STARTED=0
    WYNIK_ZAPISANY=0
    # shellcheck disable=SC2317,SC2329  # wywolywane przez trap
    on_exit() {
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$WYNIK_ZAPISANY" = 0 ] && [ -n "$TS" ]; then
            zapisz_wynik BLAD "przerwane (exit=$rc) - szczegoly wyzej" || true
        fi
        if [ "$SHADOW_STARTED" = 1 ]; then
            if [ "$rc" -ne 0 ] && [ "$KEEP_SHADOW" = 1 ]; then
                echo "Shadow stack ZOSTAJE do inspekcji (docker logs $SHADOW_APP). Sprzatniecie: make test-upgrade-clean" >&2
            else
                shadow_cleanup
            fi
        fi
        rm -rf "$STAGE" 2>/dev/null || echo "UWAGA: nie udalo sie usunac $STAGE" >&2
        shadow_lock_release
        exit "$rc"
    }
    trap on_exit EXIT
    mkdir -p "$WORK"
    chmod 700 "$STAGE"

    krok "[1/6] Dostep do kopii zdalnej"
    setup_rclone
    krok "[2/6] Wybor kompletu"
    wybierz_komplet
    say "Komplet: $TS (katalog $TS_MIESIAC)"
    pobierz_komplet
    weryfikuj_archiwa

    krok "[3/6] Konfiguracja (do katalogu tymczasowego, produkcja nietknieta)"
    BPP_REPO_ENV_FILE="$WORK/repo.env" BPP_CONFIGS_DIR="$STAGE/konfiguracja" \
        FILE="$STAGE/dane/config-backup-$TS.tar.gz" bash "$RESTORE_CONFIG_SH" </dev/null \
        || die "restore-config.sh nie odtworzyl konfiguracji z kopii"
    KENV="$STAGE/konfiguracja/.env"
    for v in DJANGO_BPP_DB_NAME DJANGO_BPP_DB_USER DJANGO_BPP_DB_PASSWORD DJANGO_BPP_SECRET_KEY; do
        [ -n "$(env_get "$KENV" "$v")" ] || die "odtworzony .env nie ma $v"
    done
    KLUCZ_KOPII="$(env_get "$KENV" DJANGO_BPP_FIELD_ENCRYPTION_KEY)"
    KLUCZ_PROD="$(env_get "$PROD_ENV" DJANGO_BPP_FIELD_ENCRYPTION_KEY)"
    if [ -z "$KLUCZ_KOPII" ]; then
        say "UWAGA: kopia konfiguracji bez DJANGO_BPP_FIELD_ENCRYPTION_KEY."
        KLUCZ_MSG="brak klucza"
    elif [ "$KLUCZ_KOPII" = "$KLUCZ_PROD" ]; then
        KLUCZ_MSG="klucz zgodny"
    else
        say "UWAGA: klucz szyfrowania w kopii ROZNI sie od produkcyjnego."
        KLUCZ_MSG="klucz INNY niz produkcja"
    fi
    unset KLUCZ_KOPII KLUCZ_PROD

    krok "[4/6] Archiwum obrazow (weryfikacja bez docker load)"
    OBRAZY_MSG="brak archiwum"
    if pobierz_obrazy; then
        man="$OBRAZY_DIR/manifest.txt"
        [ -f "$man" ] || die "zestaw obrazow $OBRAZY_SET bez manifest.txt"
        arch="$OBRAZY_DIR/$(env_get "$man" archiwum)"
        [ -f "$arch" ] || die "zestaw obrazow $OBRAZY_SET bez archiwum"
        if command -v sha256sum >/dev/null 2>&1; then suma="$(sha256sum < "$arch" | cut -c1-64)"
        else suma="$(shasum -a 256 < "$arch" | cut -c1-64)"; fi
        [ "$suma" = "$(env_get "$man" archiwum_sha256)" ] || die "suma archiwum obrazow $OBRAZY_SET niezgodna z manifestem"
        for u in appserver dbserver; do
            grep -qE "^obraz\|.*\|([a-z0-9-]+,)*$u(,|$)" "$man" || die "manifest $OBRAZY_SET nie ma obrazu uslugi $u"
        done
        if [ -f "$OBRAZY_DIR/bpp-deploy.bundle" ]; then
            git -C "$REPO_DIR" bundle verify "$OBRAZY_DIR/bpp-deploy.bundle" >/dev/null 2>&1 \
                || die "bpp-deploy.bundle w zestawie $OBRAZY_SET nie przechodzi git bundle verify"
            BUNDLE_MSG="bundle OK"
        else
            BUNDLE_MSG="bez bundla"
        fi
        OBRAZY_MSG="obrazy $OBRAZY_SET ($BUNDLE_MSG)"
        say "Zestaw obrazow $OBRAZY_SET: suma OK, manifest OK, $BUNDLE_MSG."
    fi

    krok "[5/6] Shadow stack: baza + media + appserver z kopii"
    # Obraz: ten z manifestu, jesli jest lokalnie; inaczej to, na czym chodzi
    # produkcja. Nigdy `docker load` ani pull po tagu (produkcyjne tagi zostaja).
    obraz_uslugi() {   # <usluga>
        local id="" cid
        if [ -n "$OBRAZY_DIR" ] && [ -f "$OBRAZY_DIR/manifest.txt" ]; then
            id="$(awk -F'|' -v u="$1" '$1 == "obraz" { n = split($8, a, ","); for (i = 1; i <= n; i++) if (a[i] == u) { print $4; exit } }' "$OBRAZY_DIR/manifest.txt")"
            if [ -n "$id" ] && docker image inspect "$id" >/dev/null 2>&1; then printf '%s' "$id"; return; fi
        fi
        cid="$( (cd "$REPO_DIR" && docker compose ps -q "$1" 2>/dev/null) | head -1)" || cid=""
        if [ -n "$cid" ]; then docker inspect --format '{{.Image}}' "$cid"; return; fi
        return 1
    }
    DB_IMAGE="$(obraz_uslugi dbserver)" \
        || DB_IMAGE="postgres:$(env_get "$KENV" DJANGO_BPP_POSTGRESQL_VERSION | sed 's/^$/16.13/')"
    APP_IMAGE="$(obraz_uslugi appserver)" || die "nie znam obrazu appservera (brak lokalnego obrazu z manifestu i dzialajacego appservera)"
    REDIS_IMAGE="$(grep -Eo 'redis:[0-9][0-9.]*' "$REPO_DIR/docker-compose.infrastructure.yml" | head -1)"
    REDIS_IMAGE="${REDIS_IMAGE:-redis:8.6.2}"
    say "Obraz bazy: $DB_IMAGE, appservera: $APP_IMAGE"
    pg_restore_list "$DB_IMAGE"

    shadow_cleanup
    SHADOW_STARTED=1
    shadow_start_db "$DB_IMAGE" "$KENV" "$STAGE/dane" \
        "$(env_get "$KENV" DJANGO_BPP_DB_NAME)" "$(env_get "$KENV" DJANGO_BPP_DB_USER)" \
        "$(env_get "$KENV" DJANGO_BPP_DB_PASSWORD)"
    shadow_start_redis "$REDIS_IMAGE"
    shadow_wait_db "$(env_get "$KENV" DJANGO_BPP_DB_USER)" "$(env_get "$KENV" DJANGO_BPP_DB_NAME)" || exit 1
    shadow_restore_db "db-backup-$TS.tar.gz" "db-backup-$TS" \
        "$(env_get "$KENV" DJANGO_BPP_DB_USER)" "$(env_get "$KENV" DJANGO_BPP_DB_NAME)" "${PARALLEL_JOBS:-4}"
    docker volume create "$SHADOW_MEDIA_VOL" >/dev/null
    docker run --rm -v "$SHADOW_MEDIA_VOL":/dst -v "$STAGE/dane":/s:ro \
        --entrypoint tar "$HELPER_IMAGE" xzf "/s/media-backup-$TS.tar.gz" -C /dst \
        || die "rozpakowanie mediow do wolumenu shadow nie powiodlo sie"
    shadow_start_app "$APP_IMAGE" "$KENV"
    HOSTNAME_APP="$(env_get "$KENV" DJANGO_BPP_HOSTNAMES | cut -d, -f1 | tr -d '[:space:]')"
    [ -n "$HOSTNAME_APP" ] || HOSTNAME_APP="$(env_get "$KENV" DJANGO_BPP_HOSTNAME)"
    if ! shadow_check_app "${HOSTNAME_APP:-localhost}"; then
        shadow_app_logs
        zapisz_wynik BLAD "appserver $SHADOW_APP_ERROR"
        WYNIK_ZAPISANY=1
        exit 1
    fi

    krok "[6/6] Wynik"
    zapisz_wynik OK "baza + media + konfiguracja ($KLUCZ_MSG), $OBRAZY_MSG, / HTTP $SHADOW_ROOT_CODE"
    WYNIK_ZAPISANY=1
    say "Produkcja przez caly czas byla nietknieta."
    exit 0
fi

# ---------------------------- ODTWORZENIE ---------------------------------
command -v docker >/dev/null 2>&1 || die "brak Dockera - zainstaluj: make install-docker"
docker compose version >/dev/null 2>&1 || die "brak Docker Compose (plugin)"

# Bezpiecznik: to NIE jest narzedzie na dzialajacy serwer.
if [ -f "$REPO_ENV" ] && [ -n "$(cd "$REPO_DIR" && docker compose ps -q 2>/dev/null || true)" ]; then
    die "na tym hoscie dziala juz stack BPP. restore-server jest dla CZYSTEJ maszyny;
       na dzialajacym serwerze: make proba-odtworzenia (proba) albo make restore."
fi

CFG_DIR="${BPP_CONFIGS_DIR:-}"
if [ -z "$CFG_DIR" ]; then
    ask "Katalog konfiguracyjny instancji do odtworzenia (absolutna sciezka, np. $HOME/bpp-uczelnia): "
    CFG_DIR="$REPLY"
fi
CFG_DIR="$(absolutize_config_path "$(normalize_config_path "$CFG_DIR")")"
case "$CFG_DIR" in /*) ;; *) die "katalog konfiguracyjny musi byc sciezka absolutna" ;; esac
[ "$CFG_DIR" != / ] || die "katalog konfiguracyjny nie moze byc /"
if config_path_inside_repo "$CFG_DIR" "$REPO_DIR"; then
    die "katalog konfiguracyjny nie moze byc wewnatrz repozytorium ($REPO_DIR)"
fi

STAGE="${STAGE_DIR:-$(dirname "$CFG_DIR")/bpp-odtworzenie-$(date +%Y%m%d-%H%M%S)}"
WORK="$STAGE/praca"
RC_CONF_ZRODLO=""
# 0700 tylko na katalog roboczy (kopia rclone.conf z tokenami). NIE globalne
# `umask 077`: dziedziczylyby je `make ensure-config-files` i compose, a pliki
# konfiguracyjne 0600 sa nieczytelne dla kontenerow bez roota (grafana, loki).
mkdir -p "$WORK"
chmod 700 "$STAGE" "$WORK"
TS=""
# shellcheck disable=SC2317,SC2329  # wywolywane przez trap
on_exit_real() {
    rc=$?
    # Haslo/klucze rclone ad hoc zyly tylko w srodowisku; kopia rclone.conf
    # (z tokenami) - w $WORK. Pobrane kopie zostaja (moga byc potrzebne).
    rm -rf "$WORK" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        echo "" >&2
        echo "Odtworzenie PRZERWANE (exit=$rc). Pobrane pliki: $STAGE" >&2
        if [ -n "$TS" ] && [ -d "$CFG_DIR" ]; then zapisz_wynik BLAD "przerwane (exit=$rc)" || true; fi
    fi
    exit "$rc"
}
trap on_exit_real EXIT
# Wynik do logu RAZ (on_exit_real dopisuje "przerwane" tylko, gdy TS niepusty).
porazka() { zapisz_wynik BLAD "$1"; TS=""; die "$2"; }

krok "[1/8] Dostep do kopii zdalnej"
setup_rclone

krok "[2/8] Wybor kompletu"
wybierz_komplet
say "Komplet: $TS (katalog $TS_MIESIAC)"

krok "[3/8] Pobieranie i weryfikacja"
pobierz_komplet
weryfikuj_archiwa

say ""
say "=========================================================="
say "  ODTWORZENIE SERWERA BPP"
say "  Kopia:          $TS  ($REMOTE$TS_MIESIAC/)"
say "  Konfiguracja -> $CFG_DIR"
say "  Repozytorium:   $REPO_DIR"
say "  Pobrane pliki:  $STAGE"
say "=========================================================="
say "Odtworzona zostanie konfiguracja (z kluczem szyfrowania), obrazy, baza"
say "i media; na koncu make up. Istniejaca baza w tym projekcie zostanie zastapiona."
ask 'Kontynuowac? Wpisz "tak": '
case "$REPLY" in tak|TAK|Tak) ;; *) say "Przerwano - nic nie zostalo zmienione."; TS=""; exit 1 ;; esac

# KOLEJNOSC JEST NOSNA: konfiguracja PRZED jakimkolwiek `make`. Swiezy host
# nie ma repo .env, wiec `make` wszedlby w FIRST_RUN -> setup -> init-configs,
# a ten wygenerowalby NOWY DJANGO_BPP_FIELD_ENCRYPTION_KEY (sekrety w bazie
# stalyby sie nieczytelne). restore-config.sh zapisuje repo .env sam.
krok "[4/8] Konfiguracja (restore-config.sh)"
BPP_REPO_ENV_FILE="$REPO_ENV" BPP_CONFIGS_DIR="$CFG_DIR" \
    FILE="$STAGE/dane/config-backup-$TS.tar.gz" bash "$RESTORE_CONFIG_SH" \
    || die "odtworzenie konfiguracji nie powiodlo sie"
export BPP_CONFIGS_DIR="$CFG_DIR"
KENV="$CFG_DIR/.env"
# Dzialajacy rclone.conf (ten, ktorym wlasnie pobralismy kopie) ma swiezszy
# token OAuth niz plik z archiwum - instalujemy go, zachowujac tamten.
if [ -n "$RC_CONF_ZRODLO" ] && [ "$RC_CONF_ZRODLO" != crypt-ad-hoc ] && [ -f "$RC_CONF" ]; then
    mkdir -p "$CFG_DIR/rclone"
    if [ -f "$CFG_DIR/rclone/rclone.conf" ] && ! cmp -s "$RC_CONF" "$CFG_DIR/rclone/rclone.conf"; then
        cp -p "$CFG_DIR/rclone/rclone.conf" "$CFG_DIR/rclone/rclone.conf.z-kopii-$TS"
    fi
    cp "$RC_CONF" "$CFG_DIR/rclone/rclone.conf"
    chmod 600 "$CFG_DIR/rclone/rclone.conf"
fi
if grep -q '^BPP_DATABASE_COMPOSE=' "$REPO_ENV" 2>/dev/null; then :; else
    say "Baza zewnetrzna? Dopisz BPP_DATABASE_COMPOSE=docker-compose.database.external.yml do $REPO_ENV i uruchom ponownie."
fi

krok "[5/8] Obrazy"
OBRAZY_MSG=""
if pobierz_obrazy; then
    if bash "$IMAGES_LOAD_SH" "$OBRAZY_DIR"; then
        OBRAZY_MSG="obrazy z archiwum $OBRAZY_SET"
    else
        [ "$OBRAZY" = archiwum ] && die "images-load nie powiodl sie"
        say "UWAGA: archiwum obrazow nie wczytalo sie - probuje docker pull wersji z manifestu."
        pull_obrazow
        OBRAZY_MSG="docker pull (manifest $OBRAZY_SET)"
    fi
else
    pull_obrazow
    OBRAZY_MSG="docker pull ($([ -n "$OBRAZY_DIR" ] && echo "manifest $OBRAZY_SET" || echo ".env"))"
fi

krok "[6/8] Weryfikacja zrzutu bazy (pg_restore --list)"
DB_IMG="$(awk -F'|' '$1 == "obraz" && $8 ~ /(^|,)dbserver(,|$)/ { print $2; exit }' "$OBRAZY_DIR/manifest.txt" 2>/dev/null || true)"
[ -n "$DB_IMG" ] || DB_IMG="postgres:$(env_get "$KENV" DJANGO_BPP_POSTGRESQL_VERSION | sed 's/^$/16.13/')"
pg_restore_list "$DB_IMG"

krok "[7/8] Baza + media (restore.sh) i make up"
HB="$(env_get "$KENV" DJANGO_BPP_HOST_BACKUP_DIR)"
[ -n "$HB" ] || HB="$(env_get "$KENV" DJANGO_BPP_BACKUP_DIR)"
[ -n "$HB" ] || HB="$(dirname "$CFG_DIR")/backups"
mkdir -p "$HB"
for t in db media config; do
    cp "$STAGE/dane/$t-backup-$TS.tar.gz" "$HB/"
done
# Pytania o brakujace zmienne i bramka zdrowia nie moga tu zawisnac.
export BPP_NO_CONFIG_PROMPT=1 BPP_SKIP_HEALTH_GATE=1
# Compose interpoluje ${DJANGO_BPP_HOST_BACKUP_DIR} (mount /backup w dbserverze);
# Makefile liczy domyslna wartosc sam, a tu wolamy compose bezposrednio.
export DJANGO_BPP_HOST_BACKUP_DIR="$HB"
make -C "$REPO_DIR" ensure-config-files update-configs || die "przygotowanie konfiguracji (ensure-config-files) nie powiodlo sie"
(cd "$REPO_DIR" && docker compose up -d --wait dbserver) || die "dbserver nie wstal"
# Swiezy host: nie ma czego zabezpieczac (--no-safety-backup); restore.sh
# konczy sie `make up`.
bash "$RESTORE_SH" --timestamp="$TS" --yes --no-safety-backup || die "restore.sh nie powiodl sie"

krok "[8/8] Sprawdzenie /health/ i /"
HOSTNAME_APP="$(env_get "$KENV" DJANGO_BPP_HOSTNAMES | cut -d, -f1 | tr -d '[:space:]')"
[ -n "$HOSTNAME_APP" ] || HOSTNAME_APP="$(env_get "$KENV" DJANGO_BPP_HOSTNAME)"
HOSTNAME_APP="${HOSTNAME_APP:-localhost}"
ok=0
for _ in $(seq 1 60); do
    if (cd "$REPO_DIR" && docker compose exec -T appserver curl -fsS -o /dev/null http://127.0.0.1:8000/health/) >/dev/null 2>&1; then
        ok=1; break
    fi
    sleep 5
done
[ "$ok" = 1 ] || porazka "appserver nie odpowiada na /health/" "appserver nie odpowiada na /health/ (make logs-appserver)"
KOD="$( (cd "$REPO_DIR" && docker compose exec -T appserver curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
    -H "Host: $HOSTNAME_APP" -H "X-Forwarded-Proto: https" http://127.0.0.1:8000/ 2>/dev/null) )" || KOD=""
case "$KOD" in
    2??|3??) ;;
    *) porazka "/ zwraca HTTP ${KOD:-brak}" "strona glowna (Host: $HOSTNAME_APP) zwraca HTTP ${KOD:-brak}" ;;
esac
zapisz_wynik OK "$OBRAZY_MSG, /health/ OK, / HTTP $KOD"
say ""
say "Serwer odtworzony z kopii $TS. Dalej: DNS/certyfikaty (docs: przenosiny serwera)."
say "Pobrane pliki mozna usunac: rm -rf $STAGE"
