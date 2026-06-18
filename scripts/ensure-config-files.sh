#!/usr/bin/env bash
#
# Idempotentne, non-interactive upewnienie sie, ze wszystkie pliki konfiguracyjne
# wymagane przez docker-compose (bind-mounty z $BPP_CONFIGS_DIR) istnieja.
#
# Wywolywane:
#   - przez Makefile targets up / up-quick / refresh jako prerequisit,
#     zeby `git pull && make up` zadzialal nawet jesli nowy release dodal
#     kolejny bind-mount (regresja typu: brakujacy plik -> Docker auto-tworzy
#     pusty katalog w jego miejscu -> runc wywala sie przy tworzeniu mountpointu).
#   - przez scripts/init-configs.sh jako podfragment pierwszej inicjalizacji.
#
# Non-interactive z zalozenia: nie pyta usera o nic, tylko dokopiowuje brakujace
# pliki z defaults/ (copy_if_missing). Nie nadpisuje istniejacych, nie modyfikuje
# .env. Zmiany w .env (nowe zmienne, migracje) to rola init-configs.sh, ktora
# user musi swiadomie wywolac.

set -euo pipefail

: "${BPP_CONFIGS_DIR:?BPP_CONFIGS_DIR nie jest ustawione. Uruchom: make init-configs}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULTS_DIR="$REPO_DIR/defaults"

if [ ! -d "$BPP_CONFIGS_DIR" ]; then
    echo "BLAD: katalog konfiguracyjny nie istnieje: $BPP_CONFIGS_DIR" >&2
    echo "      Uruchom: make init-configs" >&2
    exit 1
fi

mkdir -p "$BPP_CONFIGS_DIR/ssl"
# Let's Encrypt: certyfikaty wystawiane przez certbot (mountowane RW przez
# webserver dla sentinela .reload-needed). Tworzymy pusty katalog niezaleznie
# od DJANGO_BPP_SSL_MODE, zeby bind-mount na webserverze nie wykreowal
# pustego katalogu / nie wywalil sie przy starcie.
mkdir -p "$BPP_CONFIGS_DIR/letsencrypt"
mkdir -p "$BPP_CONFIGS_DIR/rclone"
mkdir -p "$BPP_CONFIGS_DIR/alloy"
mkdir -p "$BPP_CONFIGS_DIR/loki"
mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/datasources"
mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/dashboards"
mkdir -p "$BPP_CONFIGS_DIR/netdata/go.d"
mkdir -p "$BPP_CONFIGS_DIR/netdata/health.d"

# Kopiuje plik tylko jesli nie istnieje. Obsluguje edge-case, gdy Docker
# przy bind-moucie nieistniejacej sciezki hosta utworzyl w tym miejscu pusty
# katalog (bo domyslnie zaklada bind dla katalogu) - wtedy probuje go usunac
# zanim wrzuci plik. Jesli katalog nie jest pusty, odmawia i wymaga recznej
# interwencji zeby nie usunac przypadkiem cudzych danych.
copy_if_missing() {
    local src="$1" dest="$2"

    if [ -d "$dest" ] && ! [ -f "$dest" ]; then
        if ! rmdir "$dest" 2>/dev/null; then
            echo "BLAD: $dest istnieje jako niepusty katalog (spodziewany plik)." >&2
            echo "      Sprawdz recznie - moze to pozostalosc po poprzedniej konfiguracji." >&2
            return 1
        fi
        echo "  ~ usunieto pusty katalog (auto-utworzony przez Docker): $dest"
    fi

    if [ ! -f "$dest" ]; then
        cp "$src" "$dest"
        echo "  + dokopiowano z defaults/: $dest"
    fi
}

# Nadpisuje plik ZAWSZE, jesli rozni sie od wersji w defaults/. Dla wersjonowanych
# artefaktow, ktorych user NIE edytuje recznie - np. provisioned dashboardy Grafany
# (i tak read-only w UI). Bez tego zaktualizowany dashboard nigdy by nie trafil na
# zywy deployment przez make up/refresh/run (copy_if_missing pomijaloby istniejacy).
# cmp: kopiujemy tylko realne zmiany, zeby nie smiecic logiem przy kazdym uruchomieniu.
copy_always() {
    local src="$1" dest="$2"

    if [ -d "$dest" ] && ! [ -f "$dest" ]; then
        if ! rmdir "$dest" 2>/dev/null; then
            echo "BLAD: $dest istnieje jako niepusty katalog (spodziewany plik)." >&2
            return 1
        fi
    fi

    if ! cmp -s "$src" "$dest" 2>/dev/null; then
        cp "$src" "$dest"
        echo "  ~ zsynchronizowano z defaults/ (overwrite): $dest"
    fi
}

copy_if_missing "$DEFAULTS_DIR/alloy/config.alloy" "$BPP_CONFIGS_DIR/alloy/config.alloy"
copy_if_missing "$DEFAULTS_DIR/loki/local-config.yaml" "$BPP_CONFIGS_DIR/loki/local-config.yaml"

while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/grafana/provisioning/"}"
    dest="$BPP_CONFIGS_DIR/grafana/provisioning/$rel"
    case "$rel" in
        # Dashboardy: shipped, read-only w UI -> zawsze swieze z repo.
        dashboards/*) copy_always "$f" "$dest" ;;
        # Szablon datasource'ow tez force-sync: to shipped artefakt (definicje
        # Loki/PostgreSQL + cleanup martwego Prometheusa), renderowany potem
        # przez generate-grafana-datasources. Bez tego upgrade trzymalby stary
        # .tpl (copy_if_missing nie nadpisuje) i np. zmiana na read-only role
        # bpp_monitor nigdy by nie zadzialala na istniejacych wdrozeniach.
        datasources/datasources.yaml.tpl) copy_always "$f" "$dest" ;;
        # Reszta (configi tuningowane recznie) -> tylko gdy brak.
        *)            copy_if_missing "$f" "$dest" ;;
    esac
done < <(find "$DEFAULTS_DIR/grafana/provisioning" -type f -print0)

# Netdata configi (rekursywnie, copy_if_missing). .gitkeep wykluczone -
# jest tylko po to zeby pusty health.d/ trafil do gita.
while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/netdata/"}"
    dest="$BPP_CONFIGS_DIR/netdata/$rel"
    mkdir -p "$(dirname "$dest")"
    copy_if_missing "$f" "$dest"
done < <(find "$DEFAULTS_DIR/netdata" -type f -not -name '.gitkeep' -not -name '*.tpl' -print0)

# Render defaults/netdata/go.d/postgres.conf.tpl -> $BPP_CONFIGS_DIR/...
# go.d.plugin nie expanduje ${VAR} w DSN, wiec rendujemy host-side.
# Read values directly from .env via grep (source-as-bash pada na
# niestandardowych wartosciach typu EMAIL='Name <addr@domain>').
_ENV="$BPP_CONFIGS_DIR/.env"

# Self-heal sekretow wymaganych przez configi monitoringu. Append-only:
# NIGDY nie nadpisujemy istniejacych wartosci (zachowujemy to co ustawil
# init-configs/user), dopisujemy tylko brakujace. Dzieki temu `git pull &&
# make up` na starym .env (bez tych zmiennych) dziala bez recznych krokow -
# zgodnie z regula kompatybilnosci wstecznej (patrz CLAUDE.md).
if [ -f "$_ENV" ]; then
    # Append-only self-heal pojedynczej zmiennej w .env. Wspolna logika dla
    # sekretow (losowych) i zmiennych o stalej wartosci: gdy brak LUB pusta
    # (VAR=) -> dopisujemy VAR=wartosc; niepusta (VAR=cos) -> nie ruszamy.
    # NIGDY nie nadpisujemy wartosci ustawionej przez init-configs/usera. $3 to
    # gotowy komunikat logu (bez wartosci, zeby nie wyciekl sekret).
    _ensure_var() {
        # $1 = nazwa zmiennej, $2 = wartosc dopisywana gdy brak LUB pusta.
        # Pusta linia (VAR=) traktujemy jak brak, bo inaczej np.
        # create-monitoring-user / ntfy dostaja pusty sekret; grep "^VAR="
        # lapal tez taki przypadek i nigdy nie regenerowal. Wymagamy >=1 znaku
        # po '=' (.+).
        if grep -qE "^${1}=.+" "$_ENV" 2>/dev/null; then
            return 0
        fi
        # Usun ewentualna pusta linie 'VAR=' zanim dopiszemy nowa - bez tego
        # zostawilibysmy duplikat klucza (VAR= oraz VAR=wartosc).
        if grep -qE "^${1}=$" "$_ENV" 2>/dev/null; then
            local _t="$_ENV.tmp.$$"
            grep -vE "^${1}=$" "$_ENV" > "$_t" && mv "$_t" "$_ENV"
        fi
        # Zapewnij trailing newline zanim dopiszemy - recznie edytowany .env
        # bez konca-linii inaczej sklei nowa zmienna z ostatnia linia.
        # $(tail -c1) gubi trailing \n: pusty => ostatni bajt to newline.
        if [ -s "$_ENV" ] && [ -n "$(tail -c1 "$_ENV")" ]; then
            printf '\n' >> "$_ENV"
        fi
        printf '%s=%s\n' "$1" "$2" >> "$_ENV"
        echo "$3"
    }
    # Sekret losowy: wartosc NIGDY nie trafia do logu (komunikat bez $2).
    _ensure_secret() { _ensure_var "$1" "$2" "  + wygenerowano brakujacy sekret w .env: $1"; }

    # Haslo read-only roli monitoringu (Grafana datasource + Netdata postgres).
    # openssl rand -hex => tylko [0-9a-f]; create-monitoring-user.sh dodatkowo
    # waliduje alfanumerycznosc (haslo trafia do literalu SQL).
    _ensure_secret DJANGO_BPP_PG_MONITOR_PASSWORD "$(openssl rand -hex 24)"
    # Topic ntfy (sekret chroniacy kanal alertow) - gdy stary .env go nie ma.
    _ensure_secret NTFY_TOPIC "bpp-$(openssl rand -hex 16)"
    # Media root: stala wartosc = punkt montowania wolumenu 'media' (/mediaroot)
    # we wszystkich kontenerach Django. Bez niej Django bierze swoj domyslny
    # MEDIA_ROOT (~/bpp-media = /root/bpp-media w kontenerze), POZA wolumenem -
    # pliki uzytkownikow gina przy recreate i nie sa backupowane. Stare .env
    # (sprzed dodania tej zmiennej) dostaja ja tutaj na zwyklym `make up`,
    # bez koniecznosci recznego `make init-configs`.
    _ensure_var DJANGO_BPP_MEDIA_ROOT "/mediaroot" \
        "  + dopisano brakujace DJANGO_BPP_MEDIA_ROOT=/mediaroot w .env"

    # backup-runner image override - TYLKO w trybie zewnetrznej bazy. Tam
    # dbserver to lekki sentinel postgres:<major>-alpine, wiec backup-runner ma
    # wspoldzielic z nim warstwy (zamiast ciagnac osobny obraz Debianowy ~450MB).
    # W trybie lokalnym ta zmienna POZOSTAJE nieustawiona -> compose bierze pelny
    # obraz dbservera (postgres:<MAJOR.MINOR>), wspoldzielony z prawdziwym PG.
    # Stare instalacje external (sprzed tej zmiennej) dostaja ja tu, bez
    # recznego kroku - zgodnie z regula kompatybilnosci wstecznej.
    _DBCOMPOSE="$(grep -E '^BPP_DATABASE_COMPOSE=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ "$_DBCOMPOSE" = "docker-compose.database.external.yml" ]; then
        _bk_major="$(grep -E '^DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=' "$_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)"
        [ -n "$_bk_major" ] || _bk_major="$(grep -E '^DJANGO_BPP_POSTGRESQL_DB_VERSION=' "$_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)"
        if [ -n "$_bk_major" ]; then
            _ensure_var BPP_BACKUP_PG_IMAGE "postgres:${_bk_major}-alpine" \
                "  + dopisano BPP_BACKUP_PG_IMAGE=postgres:${_bk_major}-alpine (tryb external) w .env"
        fi
    fi
fi

if [ -f "$_ENV" ] && [ -f "$DEFAULTS_DIR/netdata/go.d/postgres.conf.tpl" ]; then
    _get() {
        local raw
        raw="$(grep -E "^${1}=" "$_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
        if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
            raw="${raw#\"}"; raw="${raw%\"}"
        fi
        if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
            raw="${raw#\'}"; raw="${raw%\'}"
        fi
        printf '%s' "$raw"
    }
    # DSN dla kolektora postgres laczy sie jako read-only bpp_monitor (NIE
    # uzytkownik aplikacji) - user wpisany na sztywno w .tpl, tu tylko haslo.
    _PG_MON_PASSWORD="$(_get DJANGO_BPP_PG_MONITOR_PASSWORD)"
    _PG_HOST="$(_get DJANGO_BPP_DB_HOST)"
    _PG_PORT="$(_get DJANGO_BPP_DB_PORT)"
    _PG_DB="$(_get DJANGO_BPP_DB_NAME)"
    # Port domyslny 5432 gdy .env go nie ma - inaczej DSN renderuje sie jako
    # '...@host:/db' (pusty port) i kolektor postgres netdaty nie laczy sie.
    [ -n "$_PG_PORT" ] || _PG_PORT="5432"

    if [ -n "$_PG_MON_PASSWORD" ] && [ -n "$_PG_HOST" ] && [ -n "$_PG_DB" ]; then
        # sed-escape replacementu: backslash MUSI byc pierwszy (inaczej kolejne
        # podstawienia podwajaja juz wstawione backslashe), dopiero potem / i &.
        _esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[\/&]/\\&/g'; }
        _dest="$BPP_CONFIGS_DIR/netdata/go.d/postgres.conf"
        # Render do pliku tymczasowego, chmod 600 PRZED podmiana, potem atomowy
        # mv: DSN zawiera haslo (nie moze byc world-readable), a crash w trakcie
        # nie zostawia obcietego/pustego configu.
        _tmp="${_dest}.tmp.$$"
        sed \
            -e "s/__PG_MON_PASSWORD__/$(_esc "$_PG_MON_PASSWORD")/g" \
            -e "s/__PG_HOST__/$(_esc "$_PG_HOST")/g" \
            -e "s/__PG_PORT__/$(_esc "$_PG_PORT")/g" \
            -e "s/__PG_DB__/$(_esc "$_PG_DB")/g" \
            "$DEFAULTS_DIR/netdata/go.d/postgres.conf.tpl" > "$_tmp"
        chmod 600 "$_tmp"
        mv "$_tmp" "$_dest"
        echo "  ~ wyrenderowano: $_dest"
    elif [ -f "$BPP_CONFIGS_DIR/netdata/go.d/postgres.conf" ]; then
        # Nie udalo sie wyrenderowac (brak hasla/hosta/bazy w .env), a STARY plik
        # juz istnieje - moze pochodzic sprzed migracji na bpp_monitor (DSN z
        # superuserem aplikacji). Ostrzegamy glosno, zeby nie zostawic po cichu
        # kolektora netdaty laczacego sie pelnoprawnym kontem aplikacji.
        echo "  ! UWAGA: pominieto render netdata/go.d/postgres.conf - brak" >&2
        echo "    DJANGO_BPP_PG_MONITOR_PASSWORD / DJANGO_BPP_DB_HOST / DJANGO_BPP_DB_NAME" >&2
        echo "    w .env. Istniejacy plik moze uzywac STAREGO DSN (superuser aplikacji)." >&2
        echo "    Uzupelnij .env i ponow: make ensure-config-files (lub make refresh)." >&2
    fi
fi

# Netdata main config: renderowany host-side z netdata.conf.tpl i FORCE-SYNCOWANY
# (overwrite ZAWSZE, gdy sie rozni - jak dashboardy Grafany). Powod force-sync:
# `registry to announce` musi zawierac publiczny URL tego hosta (https://<host>/netdata),
# zeby przycisk "View node" w powiadomieniu ntfy przekierowywal do LOKALNEJ netdaty
# zamiast do registry.my-netdata.io. netdata.conf NIE interpoluje ${VAR}, wiec hostname
# wstawiamy tu (jak postgres.conf.tpl). copy_if_missing nie wystarczy - zmiana nigdy by
# nie trafila na istniejace wdrozenia (maja juz swoj netdata.conf w config dir).
# Tunowalne knoby (retencja dbengine) parametryzowane przez .env, zeby overwrite nie
# kasowal recznego strojenia na wiekszych hostach.
if [ -f "$_ENV" ] && [ -f "$DEFAULTS_DIR/netdata/netdata.conf.tpl" ]; then
    _nd_get() {
        local raw
        raw="$(grep -E "^${1}=" "$_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
        raw="${raw#\"}"; raw="${raw%\"}"
        raw="${raw#\'}"; raw="${raw%\'}"
        printf '%s' "$raw"
    }
    # Kanoniczny host: pierwszy z DJANGO_BPP_HOSTNAMES (CSV, multi-host),
    # fallback do DJANGO_BPP_HOSTNAME (legacy single). Ta sama logika co letsencrypt.sh.
    # Pierwszy niepusty token wyluskujemy w czystym bashu (for nad word-splitem) -
    # bez `| head -1`, ktory pod `set -o pipefail` moze ubic wczesniejszy etap
    # potoku SIGPIPE-em i przerwac skrypt. Hostname (DNS: alnum/.-) nie zawiera
    # znakow glob, wiec niecytowane rozwiniecie jest bezpieczne.
    _ND_HOSTNAMES="$(_nd_get DJANGO_BPP_HOSTNAMES)"
    _ND_HOSTNAME="$(_nd_get DJANGO_BPP_HOSTNAME)"
    _ND_SRC="$_ND_HOSTNAMES"
    [ -n "$_ND_SRC" ] || _ND_SRC="$_ND_HOSTNAME"
    _ND_NORM="$(printf '%s' "$_ND_SRC" | tr ',' '\n' | tr -d ' \t\r')"
    _ND_CANON=""
    for _h in $_ND_NORM; do _ND_CANON="$_h"; break; done

    # Tunowalne (przezywaja force-sync, bo z .env): defaulty = dotychczasowe wartosci.
    _ND_TIER0="$(_nd_get NETDATA_DBENGINE_TIER0_RETENTION_MB)"; [ -n "$_ND_TIER0" ] || _ND_TIER0="512"
    _ND_PCACHE="$(_nd_get NETDATA_DBENGINE_PAGE_CACHE_MB)"; [ -n "$_ND_PCACHE" ] || _ND_PCACHE="32"

    # Registry: gdy znamy hosta -> wlasny rejestr + announce na publiczny URL.
    # Bez hosta (np. .env jeszcze nie wypelniony) -> degradacja do zachowania sprzed
    # zmiany: rejestr wylaczony, announce na default registry.my-netdata.io.
    if [ -n "$_ND_CANON" ]; then
        _ND_REG_ENABLED="yes"
        _ND_REG_ANNOUNCE="https://${_ND_CANON}/netdata"
        _ND_REG_HOSTNAME="$_ND_CANON"
    else
        _ND_REG_ENABLED="no"
        _ND_REG_ANNOUNCE="https://registry.my-netdata.io"
        _ND_REG_HOSTNAME=""
        echo "  ! UWAGA: brak DJANGO_BPP_HOSTNAMES/DJANGO_BPP_HOSTNAME w .env -" >&2
        echo "    netdata registry zostaje wylaczony, link 'View node' w ntfy poleci" >&2
        echo "    na registry.my-netdata.io. Uzupelnij host i ponow make ensure-config-files." >&2
    fi

    # sed-escape replacementu: backslash MUSI byc pierwszy (jak w renderze postgres.conf).
    _esc_nd() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[\/&]/\\&/g'; }
    _nd_dest="$BPP_CONFIGS_DIR/netdata/netdata.conf"
    _nd_tmp="${_nd_dest}.tmp.$$"
    sed \
        -e "s/__DBENGINE_TIER0_RETENTION_MB__/$(_esc_nd "$_ND_TIER0")/g" \
        -e "s/__DBENGINE_PAGE_CACHE_MB__/$(_esc_nd "$_ND_PCACHE")/g" \
        -e "s/__REGISTRY_ENABLED__/$(_esc_nd "$_ND_REG_ENABLED")/g" \
        -e "s/__REGISTRY_ANNOUNCE__/$(_esc_nd "$_ND_REG_ANNOUNCE")/g" \
        -e "s/__REGISTRY_HOSTNAME__/$(_esc_nd "$_ND_REG_HOSTNAME")/g" \
        "$DEFAULTS_DIR/netdata/netdata.conf.tpl" > "$_nd_tmp"
    # cmp przed mv: nadpisujemy tylko realne zmiany (jak copy_always), bez smiecenia
    # logiem i bez przebudzania netdaty (config jej sie nie zmienil) przy kazdym up.
    if ! cmp -s "$_nd_tmp" "$_nd_dest" 2>/dev/null; then
        mv "$_nd_tmp" "$_nd_dest"
        echo "  ~ zsynchronizowano (render+overwrite): $_nd_dest"
    else
        rm -f "$_nd_tmp"
    fi
fi
