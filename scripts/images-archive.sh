#!/bin/sh
#
# Archiwum obrazow Dockera i repozytorium bpp-deploy do odtworzenia serwera
# BEZ Docker Huba i GitHuba (`make images-save`, krok 2c nocnego cyklu).
#
# Uzycie:  images-archive.sh save [--force] [--monitoring]
#
# Co zapisuje (jeden zestaw = jeden katalog):
#   $BACKUP_DIR/obrazy/<YYYYMMDD-HHMMSS>/
#     obrazy.tar.gz|obrazy.tar.zst  - `docker save` WSZYSTKICH obrazow naraz
#                                     (obrazy iplweb/bpp_* dziela warstwy, wiec
#                                     jeden save trzyma je tylko raz)
#     manifest.txt                  - obraz -> id -> digest -> wersja, data,
#                                     wersja bpp-deploy, suma archiwum
#     bpp-deploy.bundle             - `git bundle` repozytorium (HEAD + galaz
#                                     + tagi), jesli repo jest dostepne
#
# Ktore obrazy: dokladnie te, na ktorych CHODZA kontenery projektu Compose
# (ID obrazu z kontenera, nie z lokalnego tagu - po `make pull` bez recreate
# lokalny `latest` wskazuje juz cos innego niz produkcja). Monitoring (netdata,
# loki, grafana, alloy, dozzle, flower) domyslnie POMIJANY - to ~1 GB, a bez
# niego BPP dziala; --monitoring albo DJANGO_BPP_BACKUP_IMAGES_MONITORING=1
# go dolacza.
#
# Nowy zestaw powstaje TYLKO, gdy zmienil sie zestaw obrazow (klucz = suma
# sortowanej listy "ref|id"; --force wymusza). Lokalnie zostaje
# DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST najnowszych zestawow (domyslnie 2).
#
# Zmienne (produkcja ustawia tylko pierwsze; reszta to defaulty kontenera
# backup-runner albo furtki dla scripts/test-images.sh):
#   COMPOSE_PROJECT_NAME                 - wymagana (env orkiestratora)
#   DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST   - ile zestawow lokalnie, domyslnie 2
#   DJANGO_BPP_BACKUP_IMAGES_MONITORING  - 1 = dolacz monitoring
#   DJANGO_BPP_BACKUP_IMAGES_MIN_FREE_GB - rezerwa: po zapisie ma zostac
#                                          tyle GB wolnego, domyslnie 10 (0 = bez)
#   DJANGO_BPP_BACKUP_IMAGES_MAX_USED_PCT - rezerwa: po zapisie dysk zajety
#                                          najwyzej w tylu %, domyslnie 80 (0 = bez)
#   BPP_BACKUP_DIR                       - domyslnie /backup
#   BPP_REPO_DIR                         - repo do bundla, domyslnie /repo
#   BPP_IMAGES_COMPRESS                  - auto (domyslnie) | zstd | gzip
#
# Wyjscie: diagnostyka na stderr, OSTATNIA linia stdout to wynik:
#   NOWE <katalog> <rozmiar w bajtach>   |   BEZ-ZMIAN <katalog>
# Exit codes:
#   0 - zestaw utworzony albo bez zmian
#   1 - blad (docker save, kompresja, zapis) - czesciowy zestaw usuniety
#   5 - nie dzialaja appserver/dbserver - nie ma czego wiernie zarchiwizowac
#   6 - za malo miejsca na dysku (nic nie zapisano)
#   7 - inny zapis archiwum trwa
#   8 - zapis zjadlby rezerwe dysku (nic nie zapisano); ostatnia linia stdout:
#       REZERWA wolne=<GB>G zajete=<PCT>%
#
# POSIX sh: dziala pod busybox ash w docker:cli (orkiestrator ma docker CLI,
# socket, git, gzip i sha256sum) i pod bashem na hoscie (testy).

# shellcheck shell=sh
# shellcheck disable=SC3040,SC3043
#   SC3040 `set -o pipefail` (busybox ash i bash maja), SC3043 `local` -
#   ta sama deklaracja co w backup-cycle.sh.
if ! (set -o pipefail) 2>/dev/null; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "BLAD: ten skrypt wymaga powloki z pipefail (busybox ash albo bash)." >&2
    exit 1
fi
set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_DIR="${BPP_BACKUP_DIR:-/backup}"
REPO_SRC="${BPP_REPO_DIR:-/repo}"
OBRAZY_DIR="$BACKUP_DIR/obrazy"
PROJECT="${COMPOSE_PROJECT_NAME:-}"
MONITORING="${DJANGO_BPP_BACKUP_IMAGES_MONITORING:-0}"
FORCE=0
# Uslugi monitoringu - pomijane domyslnie. Lista celowo jawna: wszystko inne,
# co chodzi w projekcie (takze opcjonalne html2docx, motyw-kompilator), jest
# potrzebne do dzialania BPP i trafia do archiwum.
MONITORING_SVCS="netdata loki grafana alloy dozzle flower"

log() { printf '[obrazy] %s\n' "$*" >&2; }
die() { log "BLAD: $*"; exit "${2:-1}"; }

cmd="${1:-}"
[ "$cmd" = save ] || { echo "Uzycie: $0 save [--force] [--monitoring]" >&2; exit 1; }
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --monitoring) MONITORING=1 ;;
        *) die "nieznana opcja: $1" ;;
    esac
    shift
done
[ -n "$PROJECT" ] || die "brak COMPOSE_PROJECT_NAME - nie wiem, ktore kontenery sa nasze"

KEEP="${DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST:-2}"
case "$KEEP" in
    ''|*[!0-9]*|0) log "UWAGA: DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST='$KEEP' - uzywam 2"; KEEP=2 ;;
esac

sha256_of() {   # stdin -> 64 znaki hex
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
    else shasum -a 256 | cut -c1-64; fi
}

# Nazwy zestawow: dokladnie YYYYMMDD-HHMMSS. Cokolwiek innego w obrazy/ jest
# niewidoczne dla porownania i rotacji (nigdy niczego obcego nie kasujemy).
list_sets() {
    [ -d "$OBRAZY_DIR" ] || return 0
    find "$OBRAZY_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sed 's:.*/::' \
        | { grep -E '^[0-9]{8}-[0-9]{6}$' || true; } \
        | sort
}

prune_local() {
    local nadmiar
    nadmiar="$(list_sets | sort -r | awk -v n="$KEEP" 'NR > n')"
    for s in $nadmiar; do
        log "rotacja: usuwam $OBRAZY_DIR/$s (zostaje $KEEP najnowszych)"
        rm -rf "${OBRAZY_DIR:?}/$s" || log "UWAGA: nie udalo sie usunac $OBRAZY_DIR/$s"
    done
}

mkdir -p "$OBRAZY_DIR"

# --- Blokada: nocny cykl i reczne `make images-save` nie moga pisac naraz ---
LOCK="$OBRAZY_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        die "inny zapis archiwum obrazow trwa (pid $owner)" 7
    fi
    log "przejmuje osierocona blokade (pid ${owner:-?} nie zyje)"
    rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || die "nie moge przejac blokady $LOCK" 7
fi
echo "$$" > "$LOCK/pid"

TMP=""
TEMP_TAGS=""
# shellcheck disable=SC2317  # wywolywane przez trap
on_exit() {
    rc=$?
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP" || true; fi
    for t in $TEMP_TAGS; do docker rmi "$t" >/dev/null 2>&1 || true; done
    rm -f "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    exit "$rc"
}
trap on_exit EXIT

# Zestaw porzucony przez zabity proces (`.TS.tmp`) - nigdy nie jest kompletny.
find "$OBRAZY_DIR" -mindepth 1 -maxdepth 1 -type d -name '.*.tmp' -exec rm -rf {} + 2>/dev/null || true

# --- 1. Obrazy dzialajacych kontenerow projektu ---
cids="$(docker ps -q --no-trunc \
    --filter "label=com.docker.compose.project=$PROJECT" \
    --filter status=running)"
[ -n "$cids" ] || die "brak dzialajacych kontenerow projektu $PROJECT" 5
# shellcheck disable=SC2086  # lista ID celowo dzielona na slowa
raw="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.Image}}' $cids)"

pominiete=""
pary=""     # linie "ref|id|usluga"
while IFS='|' read -r svc ref id; do
    [ -n "$svc" ] || continue
    case " $MONITORING_SVCS " in
        *" $svc "*)
            if [ "$MONITORING" != 1 ]; then pominiete="$pominiete $svc"; continue; fi ;;
    esac
    pary="$pary$ref|$id|$svc
"
done <<EOF
$raw
EOF

for wymagana in appserver dbserver; do
    printf '%s' "$pary" | grep -q "|$wymagana\$" \
        || die "nie dziala usluga $wymagana - archiwum nie bedzie wierne produkcji" 5
done

# ref|id -> jedna linia, uslugi zlaczone przecinkiem (workerserver
# i workerserver-status chodza na tym samym obrazie).
obrazy="$(printf '%s' "$pary" | sort -t'|' -k1,1 -k2,2 -k3,3 | awk -F'|' '
    NF < 3 { next }
    { k = $1 "|" $2; if (k in u) u[k] = u[k] "," $3; else { u[k] = $3; o[++n] = k } }
    END { for (i = 1; i <= n; i++) print o[i] "|" u[o[i]] }')"
KLUCZ="$(printf '%s\n' "$obrazy" | cut -d'|' -f1,2 | sort -u | sha256_of)"
[ -z "$pominiete" ] || log "pomijam monitoring:$pominiete (--monitoring dolacza)"

# --- 2. Czy cos sie zmienilo od ostatniego zestawu? ---
OSTATNI="$(list_sets | sed -n '$p')"
if [ "$FORCE" != 1 ] && [ -n "$OSTATNI" ] \
        && grep -qx "klucz=$KLUCZ" "$OBRAZY_DIR/$OSTATNI/manifest.txt" 2>/dev/null; then
    log "zestaw obrazow bez zmian od $OSTATNI - nie tworze nowego archiwum"
    prune_local
    echo "BEZ-ZMIAN $OBRAZY_DIR/$OSTATNI"
    exit 0
fi

# --- 3. Miejsce na dysku: suma rozmiarow obrazow to gorne oszacowanie ---
POTRZEBA_KB=0
ids="$(printf '%s\n' "$obrazy" | cut -d'|' -f2 | sort -u)"
for id in $ids; do
    sz="$(docker image inspect --format '{{.Size}}' "$id")" || die "nie ma obrazu $id"
    POTRZEBA_KB=$(( POTRZEBA_KB + sz / 1024 + 1 ))
done
DF_LINIA="$(df -Pk "$OBRAZY_DIR" | awk 'NR == 2 { print $2, $4 }')" || DF_LINIA=""
CALOSC_KB="${DF_LINIA%% *}"
WOLNE_KB="${DF_LINIA##* }"
case "$CALOSC_KB$WOLNE_KB" in
    ''|*[!0-9]*) log "UWAGA: nie umiem odczytac wolnego miejsca - pomijam kontrole" ;;
    *)
        if [ "$WOLNE_KB" -lt "$POTRZEBA_KB" ]; then
            die "za malo miejsca w $OBRAZY_DIR: wolne $((WOLNE_KB / 1024)) MiB, potrzeba do $((POTRZEBA_KB / 1024)) MiB" 6
        fi
        # Rezerwa: archiwum to dodatek do odtworzenia, nie moze zapchac dysku,
        # na ktorym stoi baza. Liczone od gornego oszacowania (suma obrazow),
        # wiec z zapasem. Ponizej progu krok jest pomijany co noc i sam rusza,
        # gdy przybedzie miejsca - bez zmian w .env.
        MIN_FREE_GB="${DJANGO_BPP_BACKUP_IMAGES_MIN_FREE_GB:-10}"
        MAX_PCT="${DJANGO_BPP_BACKUP_IMAGES_MAX_USED_PCT:-80}"
        case "$MIN_FREE_GB" in *[!0-9]*) log "UWAGA: MIN_FREE_GB='$MIN_FREE_GB' - uzywam 10"; MIN_FREE_GB=10 ;; esac
        case "$MAX_PCT" in *[!0-9]*) log "UWAGA: MAX_USED_PCT='$MAX_PCT' - uzywam 80"; MAX_PCT=80 ;; esac
        PO_KB=$(( WOLNE_KB - POTRZEBA_KB ))
        PO_PCT=$(( (CALOSC_KB - PO_KB) * 100 / CALOSC_KB ))
        TERAZ_GB=$(( WOLNE_KB / 1048576 ))
        TERAZ_PCT=$(( (CALOSC_KB - WOLNE_KB) * 100 / CALOSC_KB ))
        if { [ "$MIN_FREE_GB" -gt 0 ] && [ "$PO_KB" -lt $(( MIN_FREE_GB * 1048576 )) ]; } \
                || { [ "$MAX_PCT" -gt 0 ] && [ "$PO_PCT" -gt "$MAX_PCT" ]; }; then
            log "pomijam archiwum: po zapisie (~$((POTRZEBA_KB / 1048576)) GB) zostaloby $((PO_KB / 1048576)) GB wolnego, dysk zajety w $PO_PCT% (wymagane: >= $MIN_FREE_GB GB i <= $MAX_PCT%)"
            prune_local
            echo "REZERWA wolne=${TERAZ_GB}G zajete=${TERAZ_PCT}%"
            exit 8
        fi ;;
esac

# --- 4. Kompresja: zstd, jesli jest w obrazie pomocniczym; inaczej gzip ---
# docker:28-cli (BPP_HELPER_IMAGE) ma tylko busyboxowy gzip. `-1`: warstwy
# obrazow ze store'u containerd sa juz skompresowane, wyzszy poziom pali CPU
# na nic; na klasycznym overlay2 roznica rozmiaru to kilka procent.
case "${BPP_IMAGES_COMPRESS:-auto}" in
    zstd) KOMPRESJA=zstd ;;
    gzip) KOMPRESJA=gzip ;;
    *) if command -v zstd >/dev/null 2>&1; then KOMPRESJA=zstd; else KOMPRESJA=gzip; fi ;;
esac
if [ "$KOMPRESJA" = zstd ]; then ARCH=obrazy.tar.zst; else ARCH=obrazy.tar.gz; fi
kompresuj() {
    if [ "$KOMPRESJA" = zstd ]; then zstd -q -3 -T0 -c; else gzip -1 -c; fi
}

TS="$(date +%Y%m%d-%H%M%S)"
# Dwa zapisy w tej samej sekundzie (FORCE zaraz po cyklu): `mv` do istniejacego
# katalogu wsadzilby nowy zestaw DO SRODKA starego.
while [ -e "$OBRAZY_DIR/$TS" ]; do sleep 1; TS="$(date +%Y%m%d-%H%M%S)"; done
TMP="$OBRAZY_DIR/.$TS.tmp"
umask 022
mkdir -p "$TMP"

# --- 5. Ref do `docker save` + metadane kazdego obrazu ---
# `docker save <ID>` NIE zapisuje tagow (po `docker load` zostaje obraz bez
# nazwy). Zapisujemy wiec po refie z compose - ale tylko, jesli ten ref wciaz
# wskazuje DZIALAJACY obraz. Gdy nie (po `make pull` bez recreate), obraz
# dostaje tymczasowy tag <repo>:bpp-archiwum-<id12>, zdejmowany po zapisie;
# `make images-load` przepina potem ref z compose na wlasciwy obraz.
repo_of() {
    local r="${1%%@*}" ostatni
    ostatni="${r##*/}"
    case "$ostatni" in *:*) r="${r%:*}" ;; esac
    printf '%s' "$r"
}
tag_of() {
    local r="$1" ostatni
    case "$r" in *@*) printf '%s' -; return ;; esac
    ostatni="${r##*/}"
    case "$ostatni" in *:*) printf '%s' "${ostatni##*:}" ;; *) printf 'latest' ;; esac
}

# CalVer obrazow BPP (wzorzec i rozwiazywanie digest->tag z lib-docker-versions.sh).
CALVER_RE='^[0-9]{6}\.[0-9]+$'
HUB_OK=0
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # shellcheck source=scripts/lib-docker-versions.sh
    . "$SCRIPT_DIR/lib-docker-versions.sh"
    HUB_OK=1
fi
wersja_obrazu() {   # <ref> <id> <repo_digest>
    local ref="$1" id="$2" dig="$3" repo tag t
    repo="$(repo_of "$ref")"; tag="$(tag_of "$ref")"
    case "$tag" in latest|-) ;; *) printf '%s' "$tag"; return ;; esac
    # Inny lokalny tag CalVer tego samego obrazu (np. po `make zaspawaj-wersje`).
    t="$(docker image ls --no-trunc --format '{{.Repository}}:{{.Tag}}|{{.ID}}' "$repo" 2>/dev/null \
        | awk -F'|' -v id="$id" '$2 == id { n = split($1, a, ":"); print a[n] }' \
        | { grep -E "$CALVER_RE" || true; } | sort | sed -n '$p')"
    if [ -n "$t" ]; then printf '%s' "$t"; return; fi
    if [ "$HUB_OK" = 1 ] && [ "$dig" != - ]; then
        case "$repo" in
            iplweb/*) t="$(resolve_digest_to_calver "$repo" "${dig##*@}" 2>/dev/null || true)" ;;
        esac
        if [ -n "$t" ]; then printf '%s' "$t"; return; fi
    fi
    printf '%s' -
}

LINIE=""
SAVE_REFS=""
while IFS='|' read -r ref id uslugi; do
    [ -n "$ref" ] || continue
    save_ref="$ref"
    teraz="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
    if [ "$teraz" != "$id" ]; then
        idk="${id#sha256:}"
        save_ref="$(repo_of "$ref"):bpp-archiwum-$(printf '%s' "$idk" | cut -c1-12)"
        docker tag "$id" "$save_ref" || die "nie moge oznaczyc $id jako $save_ref"
        TEMP_TAGS="$TEMP_TAGS $save_ref"
        log "$ref wskazuje juz inny obraz niz dzialajacy - zapisuje $id jako $save_ref"
    fi
    repo="$(repo_of "$ref")"
    dig="$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$id" \
        | tr ' ' '\n' | awk -v r="$repo" 'index($0, r "@") == 1 { print; exit }')"
    [ -n "$dig" ] || dig="-"
    warstwy="$(docker image inspect --format '{{range .RootFS.Layers}}{{.}} {{end}}' "$id" | sha256_of)"
    wersja="$(wersja_obrazu "$ref" "$id" "$dig")"
    LINIE="${LINIE}obraz|$ref|$save_ref|$id|$warstwy|$dig|$wersja|$uslugi
"
    case " $SAVE_REFS " in *" $save_ref "*) ;; *) SAVE_REFS="$SAVE_REFS $save_ref" ;; esac
done <<EOF
$obrazy
EOF

# --- 6. docker save | kompresja ---
log "docker save$SAVE_REFS -> $ARCH ($KOMPRESJA)"
# shellcheck disable=SC2086  # lista refow celowo dzielona na slowa
if ! docker save $SAVE_REFS | kompresuj > "$TMP/$ARCH"; then
    die "docker save / kompresja nie powiodla sie"
fi
ROZMIAR="$(wc -c < "$TMP/$ARCH" | tr -d ' ')"
SUMA="$(sha256_of < "$TMP/$ARCH")"

# --- 7. git bundle repozytorium bpp-deploy ---
# Bez repo (stary kontener bez mountu /repo, instalacja z archiwum zip) zestaw
# powstaje i tak - obrazy sa wazniejsze, a repo mozna sklonowac z GitHuba.
BUNDLE="brak"; COMMIT="-"; OPIS="-"
if [ -e "$REPO_SRC/.git" ] && command -v git >/dev/null 2>&1; then
    g() { git -C "$REPO_SRC" -c safe.directory="$REPO_SRC" "$@"; }
    galaz="$(g symbolic-ref -q HEAD 2>/dev/null || true)"
    # shellcheck disable=SC2086  # pusta galaz (detached HEAD) ma zniknac
    if g bundle create "$TMP/bpp-deploy.bundle" HEAD $galaz --tags >/dev/null 2>&1; then
        BUNDLE="bpp-deploy.bundle"
        COMMIT="$(g rev-parse HEAD 2>/dev/null || echo -)"
        OPIS="$(g describe --tags --always 2>/dev/null || echo -)"
    else
        rm -f "$TMP/bpp-deploy.bundle"
        log "UWAGA: git bundle nie powiodl sie - zestaw bez repozytorium"
    fi
else
    log "UWAGA: brak repozytorium w $REPO_SRC - zestaw bez bundla (make up dodaje mount)"
fi

# --- 8. Manifest ---
{
    echo "# Archiwum obrazow BPP - manifest v1 (scripts/images-archive.sh)"
    echo "# obraz|ref_compose|ref_w_archiwum|id|warstwy_sha256|repo_digest|wersja|uslugi"
    echo "utworzono=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "projekt=$PROJECT"
    echo "bpp_deploy_wersja=$OPIS"
    echo "bpp_deploy_commit=$COMMIT"
    echo "monitoring=$MONITORING"
    echo "kompresja=$KOMPRESJA"
    echo "archiwum=$ARCH"
    echo "archiwum_sha256=$SUMA"
    echo "archiwum_bajty=$ROZMIAR"
    echo "bundle=$BUNDLE"
    echo "klucz=$KLUCZ"
    printf '%s' "$LINIE"
} > "$TMP/manifest.txt"

# Wlasciciel = wlasciciel katalogu backupow (wzorzec config-backup.sh), zeby
# `make images-load` i rclone dzialaly z konta operatora bez sudo.
if [ "$(id -u)" = 0 ]; then
    owner="$(stat -c '%u:%g' "$BACKUP_DIR" 2>/dev/null || stat -f '%u:%g' "$BACKUP_DIR" 2>/dev/null || true)"
    if [ -n "$owner" ]; then
        chown "$owner" "$OBRAZY_DIR" 2>/dev/null || true
        chown -R "$owner" "$TMP" 2>/dev/null || log "UWAGA: nie udalo sie ustawic wlasciciela $owner"
    fi
fi

mv "$TMP" "$OBRAZY_DIR/$TS"
TMP=""
log "zestaw $OBRAZY_DIR/$TS: $ARCH $((ROZMIAR / 1048576)) MiB, bundle=$BUNDLE"
prune_local
echo "NOWE $OBRAZY_DIR/$TS $ROZMIAR"
