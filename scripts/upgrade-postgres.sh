#!/usr/bin/env bash
#
# Major version upgrade Postgresa (np. 16.13 -> 18.3) dla deploymentu BPP.
#
# Strategia: logical dump & restore.
#   1. pg_dump -Fd -j N (przez `make db-backup`) starego clustra
#   2. zachowanie starego volume jako kopii (na wypadek rollbacku)
#   3. bump DJANGO_BPP_POSTGRESQL_VERSION w $BPP_CONFIGS_DIR/.env
#   4. docker compose pull dbserver -> nowy obraz z nowym majorem
#   5. docker compose up -d dbserver -> initdb na nowej wersji w pustym volume
#   6. pg_restore -Fd -j N z tarballa
#   7. make migrate, make up, smoke test
#
# Wybor dump & restore zamiast pg_upgrade jest swiadomy: obraz iplweb/bpp_dbserver
# ma tylko jeden major Postgresa baked in, wiec pg_upgrade in-place wymagalby
# dedykowanego upgrade-image z dwiema binariami. Logical dump wykorzystuje
# istniejacy `make db-backup` i jest forward-compatible przez wiele majorow.
#
# Tryb external (BPP_DATABASE_COMPOSE=docker-compose.database.external.yml) ma
# wlasna, drastycznie prostsza sciezke - upgrade prawdziwej bazy robi admin po
# stronie hosta, deploy repo tylko bumpuje wersje sentinela/backup-runnera.
#
# Wymagania:
#   - Docker Compose v2.20+ (juz wymagane przez include w docker-compose.yml)
#   - Wystarczajaco miejsca na hoscie na: tarball pg_dump + drugi volume z kopia
#     starego PGDATA. Dla DB rozmiaru X potrzeba ~2.5 * X wolnego miejsca.
#   - Upstream image iplweb/bpp_dbserver:<TAG> z nowym majorem MUSI byc juz
#     wypchniety na Docker Hub. Skrypt nie buduje obrazu.
#
# Wywolanie: `make upgrade-postgres` lub bezposrednio `bash scripts/upgrade-postgres.sh`.
#
# Wznowienie po awarii: `bash scripts/upgrade-postgres.sh --from-step=N`. Skrypt
# pomija kroki 1..N-1 i odtwarza stan z pliku $BPP_CONFIGS_DIR/.upgrade-rollback-<ts>
# (auto-detect najnowszego; override przez --rollback-file=PATH). Plik stanu jest
# tworzony zaraz po potwierdzeniu upgrade'u (przed krokiem 1) i uzupelniany o
# TARBALL po kroku 3, wiec --from-step dziala dla kazdego kroku 2-10.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ENV="$REPO_DIR/.env"

# ---- Parsowanie argumentow ----------------------------------------------
FROM_STEP=1
ROLLBACK_FILE_ARG=""
NOINPUT=0
NEW_VERSION_ARG=""
SKIP_STEPS=""
CURRENT_STEP=0  # tracker dla on_error - aktualizowany przed kazdym krokiem

while [ $# -gt 0 ]; do
    case "$1" in
        --from-step=*)
            FROM_STEP="${1#*=}"
            shift
            ;;
        --from-step)
            FROM_STEP="${2:-}"
            shift 2 || { echo "BLAD: --from-step wymaga wartosci." >&2; exit 1; }
            ;;
        --rollback-file=*)
            ROLLBACK_FILE_ARG="${1#*=}"
            shift
            ;;
        --rollback-file)
            ROLLBACK_FILE_ARG="${2:-}"
            shift 2 || { echo "BLAD: --rollback-file wymaga wartosci." >&2; exit 1; }
            ;;
        --noinput|--non-interactive|--yes)
            NOINPUT=1
            shift
            ;;
        --new-version=*)
            NEW_VERSION_ARG="${1#*=}"
            shift
            ;;
        --new-version)
            NEW_VERSION_ARG="${2:-}"
            shift 2 || { echo "BLAD: --new-version wymaga wartosci." >&2; exit 1; }
            ;;
        --skip-step=*)
            SKIP_STEPS="${1#*=}"
            shift
            ;;
        --skip-step)
            SKIP_STEPS="${2:-}"
            shift 2 || { echo "BLAD: --skip-step wymaga wartosci." >&2; exit 1; }
            ;;
        -h|--help)
            cat <<'HELP_EOF'
Uzycie: upgrade-postgres.sh [OPCJE]

  --from-step=N         Wznow upgrade od kroku N (1-10). Domyslnie 1 (pelny
                        przebieg). Przy N > 1 kroki 1..N-1 sa pomijane - skrypt
                        zaklada ze byly juz wczesniej zrealizowane.

  --rollback-file=PATH  Plik stanu poprzedniego przebiegu
                        ($BPP_CONFIGS_DIR/.upgrade-rollback-<ts>) zawierajacy
                        OLD_*, NEW_*, BACKUP_VOLUME, TARBALL. Wymagany przy
                        --from-step >= 2. Pominiety = auto-detect najnowszego.

  --noinput             Tryb nieinteraktywny (aka --yes, --non-interactive).
                        Wszystkie potwierdzenia (confirm) sa auto-yes, brak
                        `read` promptow. Wymaga --new-version przy fresh runie.
                        Przeznaczone dla testow integracyjnych / CI.

  --new-version=X.Y     Preset wersji docelowej Postgresa (zamiast interaktywnego
                        prompta). Format MAJOR.MINOR, np. 18.3. Przy --noinput
                        obowiazkowy; inaczej opcjonalny (zastepuje `read`).

  --skip-step=N,M,...   Pomija konkretne kroki (przecinkowo). Np. --skip-step=2,10
                        pomija stop serwisow (krok 2) i migrate+up (krok 10) -
                        dla testow ktore nie potrzebuja pelnego stacka aplikacji.

  -h, --help            Ten ekran.

Przyklady:

  # Pelny upgrade od zera (domyslny tryb interaktywny):
  bash scripts/upgrade-postgres.sh

  # Wznow po faile w kroku 8 (nowy dbserver nie wstal):
  bash scripts/upgrade-postgres.sh --from-step=8

  # Wznow konkretny przebieg gdy jest kilka plikow stanu:
  bash scripts/upgrade-postgres.sh --from-step=9 \
      --rollback-file=$BPP_CONFIGS_DIR/.upgrade-rollback-20260418-120000

  # Test integracyjny (tylko dbserver, bez pelnego stacka aplikacji):
  bash scripts/upgrade-postgres.sh \
      --noinput --new-version=18.3 --skip-step=2,10

Kroki:
   1. Pull nowego obrazu dbservera (pre-flight)
   2. Stop serwisow konsumujacych baze
   3. pg_dump (make db-backup)
   4. Stop + rm kontenera dbserver
   5. Kopia volume ${PROJECT}_postgresql_data -> backup volume
   6. Usuniecie oryginalnego volume
   7. Bump DJANGO_BPP_POSTGRESQL_VERSION(+_MAJOR) w .env
   8. Start nowego dbservera (initdb na nowym majorze)
   9. pg_restore z tarballa
  10. make migrate + make up + smoke test

Uwaga: niektore kroki nie sa w pelni idempotentne przy wznowieniu.
Np. krok 5 wywali sie jesli BACKUP_VOLUME juz istnieje (wtedy usun go recznie
i uruchom ponownie), a krok 9 zglosi konflikty jesli baza ma juz dane
z poprzedniej proby restore'a.
HELP_EOF
            exit 0
            ;;
        *)
            echo "BLAD: nieznana opcja '$1'. Uzyj --help." >&2
            exit 1
            ;;
    esac
done

if ! [[ "$FROM_STEP" =~ ^[0-9]+$ ]] || [ "$FROM_STEP" -lt 1 ] || [ "$FROM_STEP" -gt 10 ]; then
    echo "BLAD: --from-step musi byc liczba 1-10, dostalem '$FROM_STEP'." >&2
    exit 1
fi

if [ -n "$SKIP_STEPS" ]; then
    # Walidacja: tylko cyfry + przecinki, kazdy element 1-10.
    if ! [[ "$SKIP_STEPS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "BLAD: --skip-step musi byc liczbami oddzielonymi przecinkami (np. 2,10), dostalem '$SKIP_STEPS'." >&2
        exit 1
    fi
    IFS=',' read -ra _skip_arr <<< "$SKIP_STEPS"
    for _s in "${_skip_arr[@]}"; do
        if [ "$_s" -lt 1 ] || [ "$_s" -gt 10 ]; then
            echo "BLAD: --skip-step: element '$_s' poza zakresem 1-10." >&2
            exit 1
        fi
    done
fi

if [ -n "$NEW_VERSION_ARG" ] && ! [[ "$NEW_VERSION_ARG" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "BLAD: --new-version='$NEW_VERSION_ARG' nie pasuje do formatu MAJOR.MINOR (np. 18.3)." >&2
    exit 1
fi

# Helper uzywany przy gate'owaniu kazdego kroku ponizej.
step_is_skipped() {
    [[ ",${SKIP_STEPS}," == *",${1},"* ]]
}

# Helpery do czytania/pisania .env BEZ `source`. Plik .env uzytkownika moze zawierac
# wartosci ktore shell potraktowalby jako skladnie: `ADMINS=admin <foo@bar.pl>`
# (redirect), backtick w passwordzie, niezamkniete cudzyslowy, znak `$` itd.
# Docker Compose nie ma z tym problemu bo uzywa wlasnego parsera KEY=VALUE,
# a `source` probuje interpretowac cala linie jako bash i sie wywala. Robimy tu
# to co Compose: czytamy tylko surowe pary klucz=wartosc linia po linii.
env_has_var() {
    grep -q "^${1}=" "$2" 2>/dev/null
}

get_env_var() {
    local raw
    raw="$(grep -E "^${1}=" "$2" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

set_env_var() {
    local var_name="$1" value="$2" file="$3"
    if env_has_var "$var_name" "$file"; then
        local tmp="$file.tmp.$$"
        awk -v k="$var_name" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '\n%s=%s\n' "$var_name" "$value" >> "$file"
    fi
}

confirm() {
    local prompt="$1" answer
    if [ "$NOINPUT" = 1 ]; then
        echo "$prompt [auto-yes via --noinput]"
        return 0
    fi
    read -r -p "$prompt [yes/NO]: " answer
    [ "$answer" = "yes" ]
}

run() {
    echo "+ $*"
    "$@"
}

if [ ! -f "$REPO_ENV" ]; then
    echo "BLAD: brak $REPO_ENV. Najpierw uruchom 'make' zeby zainicjalizowac konfiguracje." >&2
    exit 1
fi

# Repo .env trzyma: BPP_CONFIGS_DIR, COMPOSE_PROJECT_NAME, opcjonalnie BPP_DATABASE_COMPOSE.
# Jesli te zmienne sa juz w shell env (np. test integracyjny je wyeksportowal),
# preferujemy ich wartosc. Normalna inwokacja przez `make upgrade-postgres` nie
# eksportuje tych z shella, wiec idziemy do repo .env.
: "${BPP_CONFIGS_DIR:=$(get_env_var BPP_CONFIGS_DIR "$REPO_ENV")}"
: "${COMPOSE_PROJECT_NAME:=$(get_env_var COMPOSE_PROJECT_NAME "$REPO_ENV")}"
: "${BPP_DATABASE_COMPOSE:=$(get_env_var BPP_DATABASE_COMPOSE "$REPO_ENV")}"

if [ -z "$BPP_CONFIGS_DIR" ]; then
    echo "BLAD: BPP_CONFIGS_DIR nie ustawione w $REPO_ENV." >&2
    exit 1
fi

APP_ENV="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$APP_ENV" ]; then
    echo "BLAD: brak $APP_ENV. Uruchom 'make init-configs'." >&2
    exit 1
fi

# Aplikacyjne zmienne - ladujemy tylko to, czego skrypt faktycznie uzywa. NIE
# sourcujemy calego .env (patrz komentarz przy get_env_var powyzej).
DJANGO_BPP_DB_PASSWORD="$(get_env_var DJANGO_BPP_DB_PASSWORD "$APP_ENV")"
DJANGO_BPP_DB_HOST="$(get_env_var DJANGO_BPP_DB_HOST "$APP_ENV")"
DJANGO_BPP_DB_PORT="$(get_env_var DJANGO_BPP_DB_PORT "$APP_ENV")"
DJANGO_BPP_DB_USER="$(get_env_var DJANGO_BPP_DB_USER "$APP_ENV")"
DJANGO_BPP_DB_NAME="$(get_env_var DJANGO_BPP_DB_NAME "$APP_ENV")"
DJANGO_BPP_HOST_BACKUP_DIR="$(get_env_var DJANGO_BPP_HOST_BACKUP_DIR "$APP_ENV")"

cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# Tryb external: nie ma lokalnego clustra do upgrade'u. Pokazujemy instrukcje.
# ---------------------------------------------------------------------------
DATABASE_COMPOSE="${BPP_DATABASE_COMPOSE:-docker-compose.database.yml}"

if [ "$DATABASE_COMPOSE" = "docker-compose.database.external.yml" ]; then
    if [ "$FROM_STEP" -ne 1 ]; then
        echo "BLAD: --from-step nie dziala w trybie external - tam jest tylko" >&2
        echo "      bump .env + recreate sentinela, zero wieloetapowej procedury." >&2
        exit 1
    fi
    # Fallback na stare nazwy (sprzed rename 2026-04-18): jesli .env nie
    # przeszlo jeszcze przez init-configs po git pull, czytamy z legacy var.
    _cur_ext_major="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$APP_ENV")"
    if [ -z "$_cur_ext_major" ]; then
        _cur_ext_major="$(get_env_var DJANGO_BPP_POSTGRESQL_DB_VERSION "$APP_ENV")"
    fi
    cat <<EOF

=== Tryb EXTERNAL ===

Lokalnie nie ma clustra Postgresa do upgrade'u - dbserver to tylko sentinel
postgres:\${DJANGO_BPP_POSTGRESQL_VERSION_MAJOR}-alpine. Prawdziwa baza zyje
poza compose i jej upgrade jest poza scope tego skryptu.

Procedura po stronie BPP (po skutecznym upgrade'ie zewnetrznej bazy):

  1. Upgrade'uj zewnetrzna baze (managed service, RDS blue/green,
     pg_upgradecluster - cokolwiek odpowiednie dla Twojego setupu).

  2. W $APP_ENV bumpnij:
       DJANGO_BPP_POSTGRESQL_VERSION=<nowy_major>
       DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=<nowy_major>
     (obecnie: ${_cur_ext_major:-<nieustawione>})

  3. make up
     -> recreate sentinela i backup-runnera na nowym obrazie
        postgres:<nowy_major>-alpine.

EOF

    if confirm "Wykonac krok 2 i 3 teraz (autopilot)?"; then
        read -r -p "Nowy major Postgresa (np. 18): " NEW_MAJOR
        if ! [[ "$NEW_MAJOR" =~ ^[0-9]+$ ]]; then
            echo "BLAD: '$NEW_MAJOR' nie jest liczba." >&2
            exit 1
        fi
        run set_env_var DJANGO_BPP_POSTGRESQL_VERSION "$NEW_MAJOR" "$APP_ENV"
        run set_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$NEW_MAJOR" "$APP_ENV"
        # Sprzatanie starej nazwy (po rename 2026-04-18) zeby uniknac rozjazdu.
        if env_has_var "DJANGO_BPP_POSTGRESQL_DB_VERSION" "$APP_ENV"; then
            awk '!/^DJANGO_BPP_POSTGRESQL_DB_VERSION=/' "$APP_ENV" > "$APP_ENV.tmp.$$" \
                && mv "$APP_ENV.tmp.$$" "$APP_ENV"
            echo "Usunieto stara DJANGO_BPP_POSTGRESQL_DB_VERSION (po migracji)."
        fi
        # Sync shell env z zapisanym .env. Makefile w liniach 55-58 robi
        # `export $(shell sed 's/=.*//' $(BPP_CONFIGS_DIR)/.env)` wiec dziedziczymy
        # STARE wartosci tych zmiennych w swoim shellu. Docker compose ma
        # udokumentowane pierwszenstwo: shell env > .env file. Bez tego sync
        # ponizszy `docker compose up` wzialby stary tag, mimo ze .env jest juz
        # zaktualizowane.
        export DJANGO_BPP_POSTGRESQL_VERSION="$NEW_MAJOR"
        export DJANGO_BPP_POSTGRESQL_VERSION_MAJOR="$NEW_MAJOR"
        unset DJANGO_BPP_POSTGRESQL_DB_VERSION 2>/dev/null || true
        echo "Zaktualizowano wersje PostgreSQL na $NEW_MAJOR w $APP_ENV"
        run docker compose pull dbserver backup-runner
        run docker compose up -d dbserver backup-runner
        echo
        echo "Gotowe. Sentinel i backup-runner dzialaja na postgres:${NEW_MAJOR}-alpine."
        echo "Sprawdz: docker compose exec dbserver pg_isready -h \$DJANGO_BPP_DB_HOST"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Tryb local: pelna procedura dump & restore.
# ---------------------------------------------------------------------------

if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    echo "BLAD: COMPOSE_PROJECT_NAME nie ustawione w $REPO_ENV (potrzebne do nazwy volume)." >&2
    exit 1
fi

VOLUME_NAME="${COMPOSE_PROJECT_NAME}_postgresql_data"

# TARBALL_NAME/DUMP_DIRNAME sa policzone po kroku 3 (fresh) lub odczytane
# z pliku stanu (resume). Inicjalizacja pusta, zeby nic nie trzymalo smieci
# po poprzednim przebiegu gdy ktos source'uje skrypt.
TARBALL=""
TARBALL_NAME=""
DUMP_DIRNAME=""

if [ "$FROM_STEP" -gt 1 ]; then
    # ------------------------------------------------------------------
    # Tryb RESUME: wczytaj stan z pliku rollback, pomin prompty.
    # ------------------------------------------------------------------
    if [ -z "$ROLLBACK_FILE_ARG" ]; then
        # Auto-detect najnowszego .upgrade-rollback-<ts>. Timestamp jest w
        # nazwie pliku (format YYYYMMDD-HHMMSS) wiec sort alfabetyczny =
        # sort chronologiczny.
        ROLLBACK_FILE_ARG="$(find "$BPP_CONFIGS_DIR" -maxdepth 1 -name '.upgrade-rollback-*' -print 2>/dev/null | sort | tail -1)"
    fi
    if [ -z "$ROLLBACK_FILE_ARG" ] || [ ! -f "$ROLLBACK_FILE_ARG" ]; then
        cat >&2 <<EOF
BLAD: --from-step=$FROM_STEP wymaga pliku stanu poprzedniego przebiegu.
      Szukalem: $BPP_CONFIGS_DIR/.upgrade-rollback-*
      Nie znalazlem zadnego. Opcje:
        - Podaj --rollback-file=PATH jawnie
        - Zacznij od --from-step=1 (pelny przebieg od zera)
EOF
        exit 1
    fi

    ROLLBACK_FILE="$ROLLBACK_FILE_ARG"

    # get_env_var dziala na tym pliku - format to proste KEY=VALUE.
    BACKUP_VOLUME="$(get_env_var OLD_VOLUME "$ROLLBACK_FILE")"
    CURRENT_POSTGRESQL_VERSION="$(get_env_var OLD_POSTGRESQL_VERSION "$ROLLBACK_FILE")"
    NEW_POSTGRESQL_VERSION="$(get_env_var NEW_POSTGRESQL_VERSION "$ROLLBACK_FILE")"
    CURRENT_PG_MAJOR="$(get_env_var OLD_PG_MAJOR "$ROLLBACK_FILE")"
    EXPECTED_MAJOR="$(get_env_var NEW_PG_MAJOR "$ROLLBACK_FILE")"
    TARBALL="$(get_env_var TARBALL "$ROLLBACK_FILE")"
    # TS wydobywamy z nazwy pliku - wzorzec .upgrade-rollback-<ts>.
    TS="${ROLLBACK_FILE##*.upgrade-rollback-}"

    for _var in BACKUP_VOLUME CURRENT_POSTGRESQL_VERSION NEW_POSTGRESQL_VERSION CURRENT_PG_MAJOR EXPECTED_MAJOR; do
        if [ -z "${!_var}" ]; then
            echo "BLAD: brak $_var w $ROLLBACK_FILE - plik uszkodzony lub z za starej wersji skryptu." >&2
            echo "      Zacznij od --from-step=1." >&2
            exit 1
        fi
    done
    if [ "$FROM_STEP" -gt 3 ] && [ -z "$TARBALL" ]; then
        echo "BLAD: --from-step=$FROM_STEP wymaga TARBALL w $ROLLBACK_FILE" >&2
        echo "      (krok 3 db-backup nie zostal wczesniej wykonany). Zacznij od --from-step=3." >&2
        exit 1
    fi

    if [ -n "$TARBALL" ]; then
        TARBALL_NAME="$(basename "$TARBALL")"
        DUMP_DIRNAME="${TARBALL_NAME%.tar.gz}"
    fi

    cat <<EOF

=== PostgreSQL Major Upgrade - TRYB WZNOWIENIA ===

Plik stanu:                      $ROLLBACK_FILE
Timestamp poprzedniego przebiegu: $TS
OLD (wersja do rollbacku):        $CURRENT_POSTGRESQL_VERSION (major $CURRENT_PG_MAJOR)
NEW (wersja docelowa):            $NEW_POSTGRESQL_VERSION (major $EXPECTED_MAJOR)
Backup volume:                    $BACKUP_VOLUME
Tarball pg_dump:                  ${TARBALL:-<brak - krok 3 jeszcze nie wykonany>}

Kroki 1..$((FROM_STEP - 1)) zostana POMINIETE (zakladam ze byly juz wczesniej zrealizowane).
Start od kroku $FROM_STEP/10.

EOF
    if ! confirm "Kontynuowac wznowienie od kroku $FROM_STEP?"; then
        echo "Anulowano."
        exit 0
    fi

else
    # ------------------------------------------------------------------
    # Tryb FRESH: pelny interaktywny flow.
    # ------------------------------------------------------------------
    if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        echo "BLAD: volume $VOLUME_NAME nie istnieje. Czy stack byl kiedykolwiek uruchomiony?" >&2
        exit 1
    fi

    # Sanity check: dbserver dziala i da sie odpytac o wersje.
    if ! docker compose ps --status=running --services 2>/dev/null | grep -qx dbserver; then
        echo "BLAD: dbserver nie dziala. Najpierw uruchom 'make up' zeby moc wykonac pg_dump." >&2
        exit 1
    fi

    CURRENT_PG_VERSION="$(docker compose exec -T dbserver postgres --version 2>/dev/null || echo unknown)"
    CURRENT_PG_MAJOR="$(echo "$CURRENT_PG_VERSION" | grep -oE '[0-9]+' | head -1 || echo 0)"
    # Czytamy z nowej nazwy (DJANGO_BPP_POSTGRESQL_VERSION) z fallbackiem na stara
    # (DJANGO_BPP_DBSERVER_PG_VERSION) - patrz komentarze w docker-compose.database.yml.
    CURRENT_POSTGRESQL_VERSION="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION "$APP_ENV")"
    if [ -z "$CURRENT_POSTGRESQL_VERSION" ]; then
        CURRENT_POSTGRESQL_VERSION="$(get_env_var DJANGO_BPP_DBSERVER_PG_VERSION "$APP_ENV")"
    fi
    CURRENT_POSTGRESQL_VERSION="${CURRENT_POSTGRESQL_VERSION:-16.13 (default z compose, brak w .env)}"

    cat <<EOF

=== PostgreSQL Major Upgrade (tryb LOCAL) ===

Project:                            $COMPOSE_PROJECT_NAME
Volume:                             $VOLUME_NAME
Obecna wersja PG (z kontenera):     $CURRENT_PG_VERSION
Obecny DJANGO_BPP_POSTGRESQL_VERSION: $CURRENT_POSTGRESQL_VERSION

Procedura wykona:
  1. Pull nowego obrazu dbservera (fail-fast - zanim cokolwiek destrukcyjnego;
     jesli siec padnie lub tag nie istnieje, dowiemy sie TERAZ a nie po
     skasowaniu volume)
  2. Zatrzyma serwisy konsumujace baze (appserver, authserver, workery,
     celerybeat, denorm-queue, flower, postgres-exporter, ofelia, backup-runner)
     - po dodatkowym prompcie, zeby bylo jasne co pada
  3. pg_dump aktualnego clustra (przez 'make db-backup') - bez concurrent writes
  4. Zatrzyma i usunie kontener dbserver
  5. Skopiuje obecny volume $VOLUME_NAME do volume backupowego
     (wymaga ~rozmiar_PGDATA wolnego miejsca w docker volumes)
  6. Usunie obecny volume $VOLUME_NAME
     (nowy kontener musi uzywac nowego, pustego woluminu - miedzy majorami
      Postgresa NIE ma binarnej kompatybilnosci formatu PGDATA)
  7. Bumpnie DJANGO_BPP_POSTGRESQL_VERSION + _MAJOR w $APP_ENV
  8. Start nowego dbserver -> initdb na nowym majorze
     (w razie failu - prompt o auto-rollback z backup volume)
  9. pg_restore z tarballa
 10. make migrate, make up, smoke test

Stary volume bedzie zachowany pod nowa nazwa az do recznego usuniecia.
Tarball z pg_dump tez zostaje w \$DJANGO_BPP_HOST_BACKUP_DIR.

Gdy ktorys krok padnie, mozesz wznowic od niego:
  bash scripts/upgrade-postgres.sh --from-step=N

EOF

    if [ -n "$NEW_VERSION_ARG" ]; then
        NEW_POSTGRESQL_VERSION="$NEW_VERSION_ARG"
        echo "Nowa wersja (z --new-version): $NEW_POSTGRESQL_VERSION"
    elif [ "$NOINPUT" = 1 ]; then
        echo "BLAD: --noinput wymaga --new-version=X.Y (skad wziac docelowa wersje?)." >&2
        exit 1
    else
        echo "Dostepne tagi (psql-<ver>): https://hub.docker.com/r/iplweb/bpp_dbserver/tags"
        read -r -p "Nowa wersja dbservera (format MAJOR.MINOR, np. 18.3): " NEW_POSTGRESQL_VERSION
    fi
    if [ -z "$NEW_POSTGRESQL_VERSION" ]; then
        echo "BLAD: wersja nie moze byc pusta." >&2
        exit 1
    fi
    if ! [[ "$NEW_POSTGRESQL_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "BLAD: '$NEW_POSTGRESQL_VERSION' nie pasuje do formatu MAJOR.MINOR (np. 18.3)." >&2
        exit 1
    fi

    EXPECTED_MAJOR="${NEW_POSTGRESQL_VERSION%%.*}"

    if [ "$EXPECTED_MAJOR" -le "$CURRENT_PG_MAJOR" ]; then
        echo "BLAD: nowy major ($EXPECTED_MAJOR) <= obecny ($CURRENT_PG_MAJOR). Upgrade w dol nie jest wspierany." >&2
        echo "      Do minor upgrade'u (np. 16.13 -> 16.14) uzyj zwyklego 'docker compose pull dbserver && docker compose up -d dbserver'." >&2
        exit 1
    fi

    if ! confirm "Kontynuowac upgrade $CURRENT_PG_MAJOR -> $EXPECTED_MAJOR (DJANGO_BPP_POSTGRESQL_VERSION: $CURRENT_POSTGRESQL_VERSION -> $NEW_POSTGRESQL_VERSION)?"; then
        echo "Anulowano."
        exit 0
    fi

    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_VOLUME="${VOLUME_NAME}_pg${CURRENT_PG_MAJOR}_${TS}"
    ROLLBACK_FILE="$BPP_CONFIGS_DIR/.upgrade-rollback-${TS}"

    # Zapisujemy plik stanu WCZESNIE - przed krokiem 1 - zeby --from-step mogl
    # wznowic od dowolnego kroku 2-10. Pole TARBALL uzupelniamy dopiero po
    # kroku 3 (set_env_var na tym samym pliku).
    cat > "$ROLLBACK_FILE" <<EOF
# BPP postgres upgrade rollback info - $TS
OLD_VOLUME=$BACKUP_VOLUME
NEW_VOLUME=$VOLUME_NAME
OLD_POSTGRESQL_VERSION=$CURRENT_POSTGRESQL_VERSION
NEW_POSTGRESQL_VERSION=$NEW_POSTGRESQL_VERSION
OLD_PG_MAJOR=$CURRENT_PG_MAJOR
NEW_PG_MAJOR=$EXPECTED_MAJOR
TARBALL=
EOF
    echo "Plik stanu: $ROLLBACK_FILE"
fi

NEW_DBSERVER_IMAGE="iplweb/bpp_dbserver:psql-${NEW_POSTGRESQL_VERSION}"

# Trap z duzym banerem na wypadek awarii po krytycznym kroku (gdy
# auto_rollback nie zostal wywolany - np. przerwanie Ctrl-C, blad w obcym
# miejscu, user odmowil auto-rollback).
CRITICAL_STAGE_REACHED=0
if [ "$FROM_STEP" -ge 5 ]; then
    # Resume od kroku >= 5 zaklada ze poprzedni przebieg zaszedl co najmniej
    # do polowy kroku 5 - czyli volume juz mogl byc skopiowany i wkrotce
    # skasowany. Od tego momentu kazdy fail wymaga manualnej albo auto
    # recovery, wiec wlaczamy banner od razu.
    CRITICAL_STAGE_REACHED=1
fi
on_error() {
    local exit_code=$?
    local resume_step="${CURRENT_STEP:-?}"
    if [ "$CRITICAL_STAGE_REACHED" = 1 ]; then
        cat >&2 <<EOF

##############################################################################
# UPGRADE PRZERWANY PO KRYTYCZNYM KROKU
##############################################################################
# Exit code: $exit_code
# Krok w trakcie:                 $resume_step/10
#
# Stan:
#   - Stary volume zachowany jako: $BACKUP_VOLUME
#   - Aktualny volume:              $VOLUME_NAME (moze byc pusty lub czesciowo
#                                                  zapelniony nowym clustrem)
#   - Tarball pg_dump:              ${TARBALL:-<krok 3 nie wykonany>}
#   - Plik stanu:                   $ROLLBACK_FILE
#
# ABY WZNOWIC po naprawie problemu:
#   bash scripts/upgrade-postgres.sh --from-step=$resume_step
#   (auto-detect pliku stanu; dla pewnosci mozesz dodac
#    --rollback-file=$ROLLBACK_FILE)
#
# ROLLBACK manualny do starego clustra:
#   1. docker compose stop dbserver
#   2. docker compose rm -f dbserver
#   3. docker volume rm $VOLUME_NAME
#   4. docker volume create $VOLUME_NAME
#   5. docker run --rm \\
#        -v $BACKUP_VOLUME:/from:ro \\
#        -v $VOLUME_NAME:/to \\
#        alpine sh -c 'cp -a /from/. /to/'
#   6. W $APP_ENV:
#        DJANGO_BPP_POSTGRESQL_VERSION=$CURRENT_POSTGRESQL_VERSION
#        DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$CURRENT_PG_MAJOR
#   7. docker compose up -d dbserver
##############################################################################
EOF
    elif [ "$exit_code" != 0 ] && [ -n "${ROLLBACK_FILE:-}" ]; then
        # Blad przed krokiem destrukcyjnym - stan starego clustra nienaruszony.
        cat >&2 <<EOF

##############################################################################
# UPGRADE PRZERWANY PRZED KROKIEM DESTRUKCYJNYM
##############################################################################
# Exit code:       $exit_code
# Krok w trakcie:  $resume_step/10
#
# Stary cluster nienaruszony. Plik stanu: $ROLLBACK_FILE
#
# ABY WZNOWIC po naprawie:
#   bash scripts/upgrade-postgres.sh --from-step=$resume_step
##############################################################################
EOF
    fi
}
trap on_error ERR

# Auto-rollback: odkreca destrukcyjne kroki (bumpa env, skasowanie volume,
# uruchomienie nowego kontenera) wracajac do starego clustra z BACKUP_VOLUME.
# Wywolywane interaktywnie gdy nowy dbserver nie wstaje w [8/10] lub gdy
# wersja kontenera nie pasuje do oczekiwanej. Po wywolaniu BACKUP_VOLUME jest
# usuniety (dane wrocily do $VOLUME_NAME), tarball pg_dump zostaje.
auto_rollback() {
    echo ""
    echo "##############################################################################"
    echo "# AUTO-ROLLBACK"
    echo "##############################################################################"
    run docker compose stop dbserver || true
    run docker compose rm -f dbserver || true
    run docker volume rm "$VOLUME_NAME" 2>/dev/null || true
    run docker volume create "$VOLUME_NAME"
    run docker run --rm \
        -v "$BACKUP_VOLUME:/from:ro" \
        -v "$VOLUME_NAME:/to" \
        alpine sh -c 'cp -a /from/. /to/'
    run docker volume rm "$BACKUP_VOLUME"
    run set_env_var DJANGO_BPP_POSTGRESQL_VERSION "$CURRENT_POSTGRESQL_VERSION" "$APP_ENV"
    run set_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$CURRENT_PG_MAJOR" "$APP_ENV"
    # Sync shell env (patrz komentarz przy kroku [7/10]) - inaczej docker compose
    # wezmie wartosci wyeksportowane przez Makefile (te ktore byly sprzed tego
    # rollbacku - np. juz bumpniete do nowego majora) i wystartuje kontener na
    # ZLYM obrazie zamiast wrocic do oryginalnego.
    export DJANGO_BPP_POSTGRESQL_VERSION="$CURRENT_POSTGRESQL_VERSION"
    export DJANGO_BPP_POSTGRESQL_VERSION_MAJOR="$CURRENT_PG_MAJOR"
    run docker compose up -d dbserver

    echo "Czekam az stary dbserver wstanie (max 60s)..."
    for _i in $(seq 1 20); do
        _state="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q dbserver)" 2>/dev/null || echo none)"
        if [ "$_state" = "healthy" ]; then
            echo "OK - stary cluster wstal."
            # CRITICAL_STAGE zostaje wylaczony zeby trap on_error nie drukowal
            # banera manualnego rollbacku (rollback juz zostal wykonany).
            CRITICAL_STAGE_REACHED=0
            return 0
        fi
        sleep 3
    done
    echo "UWAGA: stary dbserver nie wstal jako healthy w 60s - sprawdz 'docker compose logs dbserver'." >&2
    CRITICAL_STAGE_REACHED=0
    return 1
}

# ---- Krok 1: pre-flight pull (fail-fast) --------------------------------
# WAZNE: robimy to zanim cokolwiek destrukcyjnego. Jesli siec padnie, Docker
# Hub jest nieosiagalny, albo tag nie istnieje (literowka w wersji) - dowiemy
# sie teraz, gdy jeszcze nic nie zostalo zatrzymane ani skasowane. Po sukcesie
# image siedzi w lokalnym cache i krok 8 (up dbserver) jest juz offline-safe.
if [ "$FROM_STEP" -le 1 ] && ! step_is_skipped 1; then
    CURRENT_STEP=1
    echo
    echo "=== [1/10] Pull nowego obrazu dbserver (pre-flight, fail-fast) ==="
    run docker pull "$NEW_DBSERVER_IMAGE"
fi

# ---- Krok 2: stop dependent services ------------------------------------
# WAZNE: stop PRZED db-backupem - zeby pg_dump dostal czysty snapshot bez
# concurrent writes od appservera/workerow i bez interferencji postgres-exportera
# (ktory zrzuca co 15s `pg_stat_*`). ofelia stop = nie wystartuje swojego cronu
# (migrate, denorm-rebuild) w trakcie upgrade'u. backup-runner stop = nie
# wystartuje wlasnego pg_dumpa rownolegle z naszym.
if [ "$FROM_STEP" -le 2 ] && ! step_is_skipped 2; then
    CURRENT_STEP=2
    echo
    echo "=== [2/10] Zatrzymuje serwisy konsumujace baze ==="
    cat <<EOF

Za chwile zatrzymam nastepujace serwisy zeby uzyskac spojny backup i
uniknac konfliktow w trakcie upgrade'u:

  appserver              - aplikacja Django (odetnie uzytkownikow)
  authserver             - serwis autoryzacji (nie bedzie mozna sie logowac)
  workerserver-general   - workery Celery (bieace taski)
  workerserver-denorm    - workery denormalizacji (czekamy az queue sie oprozni)
  celerybeat             - scheduler Celery
  denorm-queue           - LISTEN/NOTIFY bridge
  flower                 - monitoring Celery
  postgres-exporter      - Prometheus metrics (zeby nie kolidowal z pg_dump)
  ofelia                 - Docker cron (zeby nie triggerowal taskow w trakcie)
  backup-runner          - daily backup (zeby nie uruchomil wlasnego pg_dumpa)

Dbserver zostanie uruchomiony - pg_dump musi miec dostep do zywej bazy.
Zatrzymane serwisy wroca same po 'make up' w kroku 10.

EOF
    if ! confirm "Zatrzymac powyzsze serwisy i kontynuowac z backupem?"; then
        echo "Anulowano. Stack pozostaje nienaruszony."
        exit 0
    fi

    # Denorm-queue + workerserver-* + celerybeat maja dedykowany target (wspolny
    # z 'make migrate') - docker compose wysle SIGTERM i poczeka na graceful stop.
    run make stop-denorm-celery
    # Reszta konsumentow bazy + postgres-exporter + ofelia + backup-runner.
    run docker compose stop \
        appserver authserver flower \
        postgres-exporter ofelia backup-runner
fi

# ---- Krok 3: dump --------------------------------------------------------
if [ "$FROM_STEP" -le 3 ] && ! step_is_skipped 3; then
    CURRENT_STEP=3
    echo
    echo "=== [3/10] Dump aktualnej bazy (make db-backup) ==="
    run make db-backup

    # Znajdz najswiezszy tarball - sortowanie po nazwie dziala bo timestamp jest w nazwie.
    TARBALL="$(find "${DJANGO_BPP_HOST_BACKUP_DIR}" -maxdepth 1 -name 'db-backup-*.tar.gz' -print | sort | tail -1)"
    if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
        echo "BLAD: nie znalazlem swiezego tarballa db-backup-*.tar.gz w $DJANGO_BPP_HOST_BACKUP_DIR" >&2
        exit 1
    fi
    TARBALL_NAME="$(basename "$TARBALL")"
    DUMP_DIRNAME="${TARBALL_NAME%.tar.gz}"
    echo "Tarball: $TARBALL"

    # Zapisz TARBALL do pliku stanu zeby --from-step >= 4 mial do niego dostep.
    run set_env_var TARBALL "$TARBALL" "$ROLLBACK_FILE"
fi

# ---- Krok 4: stop+rm dbserver --------------------------------------------
if [ "$FROM_STEP" -le 4 ] && ! step_is_skipped 4; then
    CURRENT_STEP=4
    echo
    echo "=== [4/10] Zatrzymuje i usuwam kontener dbserver ==="
    run docker compose stop dbserver
    run docker compose rm -f dbserver
fi

# Od tego momentu kazdy blad oznacza nieodwracalna zmiane stanu - wlaczamy banner.
# (Przy resume od kroku >= 5 juz wlaczyl sie wczesniej przy inicjalizacji).
CRITICAL_STAGE_REACHED=1

# ---- Krok 5: kopia volume na bok ----------------------------------------
if [ "$FROM_STEP" -le 5 ] && ! step_is_skipped 5; then
    CURRENT_STEP=5
    echo
    echo "=== [5/10] Tworze kopie volume $VOLUME_NAME -> $BACKUP_VOLUME ==="
    run docker volume create "$BACKUP_VOLUME"
    run docker run --rm \
        -v "$VOLUME_NAME:/from:ro" \
        -v "$BACKUP_VOLUME:/to" \
        alpine sh -c 'cp -a /from/. /to/'
fi

# ---- Krok 6: usun stary volume ------------------------------------------
if [ "$FROM_STEP" -le 6 ] && ! step_is_skipped 6; then
    CURRENT_STEP=6
    echo
    echo "=== [6/10] Usuwam obecny volume $VOLUME_NAME ==="
    run docker volume rm "$VOLUME_NAME"
fi

# ---- Krok 7: bump wersji dbservera i backup-runnera ---------------------
# CURRENT_BACKUP_RUNNER_MAJOR zawsze wyliczamy (nawet przy skipie kroku 7) bo
# potrzebujemy go ponizej do decyzji czy eksportowac _MAJOR do shell env.
CURRENT_BACKUP_RUNNER_MAJOR="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$APP_ENV")"
if [ -z "$CURRENT_BACKUP_RUNNER_MAJOR" ]; then
    # Fallback na stara nazwe (pre-rename).
    CURRENT_BACKUP_RUNNER_MAJOR="$(get_env_var DJANGO_BPP_POSTGRESQL_DB_VERSION "$APP_ENV")"
fi

if [ "$FROM_STEP" -le 7 ] && ! step_is_skipped 7; then
    CURRENT_STEP=7
    echo
    echo "=== [7/10] Bumpuje DJANGO_BPP_POSTGRESQL_VERSION w $APP_ENV ==="
    run set_env_var DJANGO_BPP_POSTGRESQL_VERSION "$NEW_POSTGRESQL_VERSION" "$APP_ENV"
    echo "DJANGO_BPP_POSTGRESQL_VERSION: $CURRENT_POSTGRESQL_VERSION -> $NEW_POSTGRESQL_VERSION"

    # Sprzatanie starej nazwy (po rename 2026-04-18) zeby uniknac rozjazdu
    # miedzy VERSION a DBSERVER_PG_VERSION.
    if env_has_var "DJANGO_BPP_DBSERVER_PG_VERSION" "$APP_ENV"; then
        awk '!/^DJANGO_BPP_DBSERVER_PG_VERSION=/' "$APP_ENV" > "$APP_ENV.tmp.$$" \
            && mv "$APP_ENV.tmp.$$" "$APP_ENV"
        echo "Usunieto stara DJANGO_BPP_POSTGRESQL_DBSERVER_PG_VERSION (zastapiona przez _VERSION)."
    fi

    # Jednoczesnie synchronizuj DJANGO_BPP_POSTGRESQL_VERSION_MAJOR (major dla
    # backup-runnera) jesli byla spojna z dbserverem. Gdy byla rozjechana
    # (np. user swiadomie trzyma backup-runner na nowszej wersji), nie ruszamy jej.
    if [ -z "$CURRENT_BACKUP_RUNNER_MAJOR" ] || [ "$CURRENT_BACKUP_RUNNER_MAJOR" = "$CURRENT_PG_MAJOR" ]; then
        run set_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$EXPECTED_MAJOR" "$APP_ENV"
        echo "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR: ${CURRENT_BACKUP_RUNNER_MAJOR:-<puste>} -> $EXPECTED_MAJOR"
    elif [[ "$CURRENT_BACKUP_RUNNER_MAJOR" =~ ^[0-9]+$ ]]; then
        echo "UWAGA: DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$CURRENT_BACKUP_RUNNER_MAJOR rozjechane z"
        echo "       dbserver ($CURRENT_PG_MAJOR) - nie ruszam (backup-runner moze miec >= wersja serwera)."
        if [ "$CURRENT_BACKUP_RUNNER_MAJOR" -lt "$EXPECTED_MAJOR" ]; then
            echo "       ALE: $CURRENT_BACKUP_RUNNER_MAJOR < $EXPECTED_MAJOR - rozwaz recznie bumpnac po upgrade."
        fi
    else
        echo "UWAGA: DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$CURRENT_BACKUP_RUNNER_MAJOR nie jest liczba - nie ruszam."
    fi

    # Sprzatanie starej nazwy dla majora (po rename 2026-04-18).
    if env_has_var "DJANGO_BPP_POSTGRESQL_DB_VERSION" "$APP_ENV"; then
        awk '!/^DJANGO_BPP_POSTGRESQL_DB_VERSION=/' "$APP_ENV" > "$APP_ENV.tmp.$$" \
            && mv "$APP_ENV.tmp.$$" "$APP_ENV"
        echo "Usunieto stara DJANGO_BPP_POSTGRESQL_DB_VERSION (zastapiona przez _MAJOR)."
    fi
fi

# Sync shell environment z zapisanym .env przed `docker compose up`.
# Robimy to ZAWSZE (nawet w trybie resume gdzie krok 7 byl skipowany) bo
# Makefile wyeksportowal do shella wartosci z .env sprzed bumpa. Docker Compose
# ma udokumentowane pierwszenstwo `shell env > .env file`, wiec bez tego sync
# `docker compose up dbserver` wzialby stary tag.
export DJANGO_BPP_POSTGRESQL_VERSION="$NEW_POSTGRESQL_VERSION"
unset DJANGO_BPP_DBSERVER_PG_VERSION 2>/dev/null || true
# _MAJOR eksportujemy tylko gdy faktycznie bylo bumpniete w .env (byloby spojne
# lub puste). Jesli user swiadomie trzyma rozjazd, zostawiamy wartosc z shell env.
if [ -z "$CURRENT_BACKUP_RUNNER_MAJOR" ] || [ "$CURRENT_BACKUP_RUNNER_MAJOR" = "$CURRENT_PG_MAJOR" ]; then
    export DJANGO_BPP_POSTGRESQL_VERSION_MAJOR="$EXPECTED_MAJOR"
fi
unset DJANGO_BPP_POSTGRESQL_DB_VERSION 2>/dev/null || true

# ---- Krok 8: start dbserver ----------------------------------------------
# Obraz jest juz pulled w kroku 1 (lub w poprzednim przebiegu przy resume),
# wiec `up` jest offline-safe.
if [ "$FROM_STEP" -le 8 ] && ! step_is_skipped 8; then
    CURRENT_STEP=8
    echo
    echo "=== [8/10] Start nowego dbserver ==="
    run docker compose up -d dbserver

    echo "Czekam az dbserver bedzie healthy (max 180s)..."
    HEALTHY=0
    for i in $(seq 1 60); do
        STATE="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q dbserver)" 2>/dev/null || echo none)"
        if [ "$STATE" = "healthy" ]; then
            HEALTHY=1
            echo "OK po ${i}*3s."
            break
        fi
        sleep 3
    done
    if [ "$HEALTHY" != 1 ]; then
        echo "BLAD: dbserver nie zostal healthy w 180s." >&2
        echo "Logi dbservera (ostatnie 100 linii):" >&2
        docker compose logs --tail=100 dbserver >&2 || true
        echo ""
        if confirm "Wykonac auto-rollback (przywrocic stary cluster z backup volume)?"; then
            auto_rollback || true
            echo ""
            echo "Rollback wykonany. Upgrade nie powiodl sie, stary cluster wrocil."
            echo "Tarball pg_dump zachowany: $TARBALL (mozesz usunac po weryfikacji)."
            exit 1
        fi
        echo ""
        echo "Auto-rollback pominiety. Mozesz wznowic od kroku 8 po naprawie:" >&2
        echo "  bash scripts/upgrade-postgres.sh --from-step=8" >&2
        echo "Albo zobacz banner ponizej dla manualnego rollbacku." >&2
        exit 1
    fi

    NEW_PG_VERSION="$(docker compose exec -T dbserver postgres --version 2>/dev/null || echo unknown)"
    NEW_PG_MAJOR="$(echo "$NEW_PG_VERSION" | grep -oE '[0-9]+' | head -1 || echo 0)"
    echo "Nowa wersja PG: $NEW_PG_VERSION"
    if [ "$NEW_PG_MAJOR" != "$EXPECTED_MAJOR" ]; then
        echo "BLAD: spodziewany major $EXPECTED_MAJOR, dostalem $NEW_PG_MAJOR. Sprawdz tag psql-$NEW_POSTGRESQL_VERSION." >&2
        echo ""
        if confirm "Wykonac auto-rollback (przywrocic stary cluster z backup volume)?"; then
            auto_rollback || true
            echo ""
            echo "Rollback wykonany. Upgrade nie powiodl sie (zly tag), stary cluster wrocil."
            exit 1
        fi
        echo "Auto-rollback pominiety - patrz banner z manualnymi krokami." >&2
        exit 1
    fi
else
    # Resume od kroku >= 9: dbserver powinien juz dzialac. Sanity check + pickup
    # NEW_PG_VERSION zeby finalny baner pokazal poprawne dane.
    NEW_PG_VERSION="$(docker compose exec -T dbserver postgres --version 2>/dev/null || echo unknown)"
fi

# ---- Krok 9: pg_restore -------------------------------------------------
if [ "$FROM_STEP" -le 9 ] && ! step_is_skipped 9; then
    CURRENT_STEP=9
    echo
    echo "=== [9/10] pg_restore z $TARBALL_NAME ==="
    # Tarball jest juz w /backup (bind-mount) - rozpakuj wewnatrz kontenera.
    run docker compose exec -T dbserver tar xzf "/backup/$TARBALL_NAME" -C /backup
    run docker compose exec -T \
        -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" \
        dbserver \
        pg_restore \
            -Fd \
            -j "${PARALLEL_JOBS:-4}" \
            -h "$DJANGO_BPP_DB_HOST" \
            -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" \
            -d "$DJANGO_BPP_DB_NAME" \
            --no-owner --no-privileges \
            "/backup/$DUMP_DIRNAME"
    # Sprzatamy rozpakowany katalog (ale tarball ZOSTAJE jako disaster recovery).
    run docker compose exec -T dbserver rm -rf "/backup/$DUMP_DIRNAME"
fi

# Od tego momentu nowy cluster jest funkcjonalny - blad nie wymaga juz duzego bannera.
CRITICAL_STAGE_REACHED=0

# ---- Krok 10: migrate + up + smoke --------------------------------------
if [ "$FROM_STEP" -le 10 ] && ! step_is_skipped 10; then
    CURRENT_STEP=10
    echo
    echo "=== [10/10] make migrate + make up ==="
    run make migrate
    run make up

    echo
    echo "Smoke test - logi appserver (ostatnie 30 lini):"
    docker compose logs --tail=30 appserver || true
fi

# W trybie resume nie mielismy szansy odpytac starego kontenera o pelny
# "PostgreSQL X.Y.Z on ..." string (on juz nie istnial). Skladamy hybryde
# z wersji z pliku stanu (OLD_POSTGRESQL_VERSION) zeby baner nadal mial sens.
CURRENT_PG_VERSION="${CURRENT_PG_VERSION:-PostgreSQL $CURRENT_POSTGRESQL_VERSION (z pliku stanu)}"
NEW_PG_VERSION="${NEW_PG_VERSION:-PostgreSQL $NEW_POSTGRESQL_VERSION (nie odpytano)}"

cat <<EOF

##############################################################################
# UPGRADE ZAKONCZONY POMYSLNIE
##############################################################################
# $CURRENT_PG_VERSION
#   ->
# $NEW_PG_VERSION
#
# Zachowane (nie usuwane automatycznie):
#   - Stary volume:    $BACKUP_VOLUME
#   - Tarball pg_dump: $TARBALL
#   - Rollback info:   $ROLLBACK_FILE
#
# Sprawdz dzialanie aplikacji w przegladarce + 'make denorm-rebuild' jako
# najbardziej obciazajacy workflow bazy. Kiedy bedziesz zadowolony, sprzatnij:
#
#   docker volume rm $BACKUP_VOLUME
#   rm $ROLLBACK_FILE
#   # tarball mozesz zostawic - jest czescia normalnej rotacji backupow
##############################################################################
EOF
