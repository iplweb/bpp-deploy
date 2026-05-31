#!/usr/bin/env bash
# Renderuje datasources.yaml.tpl -> datasources.yaml dla Grafany.
#
# WAZNE: czyta wartosci WPROST z $BPP_CONFIGS_DIR/.env (nie z eksportu make).
# Makefile eksportuje .env w czasie PARSOWANIA, zanim odpali sie jakikolwiek
# recipe. Sekret swiezo dopisany przez ensure-config-files.sh w tym samym
# `make up` (np. DJANGO_BPP_PG_MONITOR_PASSWORD na starym .env) nie bylby
# wtedy widoczny dla envsubst i haslo wyrenderowaloby sie PUSTE -> Grafana
# 'password authentication failed'. Czytajac .env z dysku zawsze widzimy
# aktualny stan (ensure-config-files leci jako prerequisite przed tym krokiem).
#
# Renderujemy whitelista zmiennych (envsubst nie tknie innych ${...}, np.
# literalnego $ w customowym datasource). Lista pokrywa zarowno NOWY szablon
# (user: bpp_monitor + ${DJANGO_BPP_PG_MONITOR_PASSWORD}) jak i STARY z czasow
# Prometheusa (user/haslo aplikacji) - na wypadek `make restart`/`update-configs`
# uruchomionych zanim ensure-config-files force-syncuje nowy .tpl.

set -euo pipefail

: "${BPP_CONFIGS_DIR:?BPP_CONFIGS_DIR nie jest ustawione. Uruchom: make init-configs}"

ENV_FILE="$BPP_CONFIGS_DIR/.env"
DS_DIR="$BPP_CONFIGS_DIR/grafana/provisioning/datasources"
TPL="$DS_DIR/datasources.yaml.tpl"
OUT="$DS_DIR/datasources.yaml"

[ -f "$ENV_FILE" ] || { echo "BLAD: brak $ENV_FILE (uruchom: make init-configs)" >&2; exit 1; }
[ -f "$TPL" ] || { echo "BLAD: brak $TPL (uruchom: make ensure-config-files)" >&2; exit 1; }

# Czyta zmienna z .env bez source'owania (wartosci typu 'EMAIL=Name <a@b>'
# wywalaja bash source). Zdejmuje otaczajace cudzyslowy.
_get_env() {
    local raw
    raw="$(grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

# Assign osobno od export (SC2155: export VAR=$(...) maskuje exit code podstawienia).
DJANGO_BPP_DB_HOST="$(_get_env DJANGO_BPP_DB_HOST)"
DJANGO_BPP_DB_PORT="$(_get_env DJANGO_BPP_DB_PORT)"
DJANGO_BPP_DB_NAME="$(_get_env DJANGO_BPP_DB_NAME)"
DJANGO_BPP_DB_USER="$(_get_env DJANGO_BPP_DB_USER)"
DJANGO_BPP_DB_PASSWORD="$(_get_env DJANGO_BPP_DB_PASSWORD)"
DJANGO_BPP_PG_MONITOR_PASSWORD="$(_get_env DJANGO_BPP_PG_MONITOR_PASSWORD)"
export DJANGO_BPP_DB_HOST DJANGO_BPP_DB_PORT DJANGO_BPP_DB_NAME \
       DJANGO_BPP_DB_USER DJANGO_BPP_DB_PASSWORD DJANGO_BPP_PG_MONITOR_PASSWORD

# Port: domyslnie 5432 gdy puste (inaczej 'url: host:' renderuje sie bez portu
# i Grafana nie sparsuje host:port).
[ -n "$DJANGO_BPP_DB_PORT" ] || export DJANGO_BPP_DB_PORT="5432"

# Jesli szablon faktycznie uzywa hasla read-only roli (nowy .tpl), MUSI ono
# byc niepuste - inaczej cicho wyrenderowalibysmy zepsuty datasource. Stary
# .tpl (app user) tej zmiennej nie uzywa, wiec nie wymuszamy jej tam.
if grep -q 'DJANGO_BPP_PG_MONITOR_PASSWORD' "$TPL" && [ -z "$DJANGO_BPP_PG_MONITOR_PASSWORD" ]; then
    echo "BLAD: DJANGO_BPP_PG_MONITOR_PASSWORD puste w $ENV_FILE." >&2
    echo "      Uruchom: make ensure-config-files (wygeneruje sekret), potem ponow." >&2
    exit 1
fi

# Render atomowy (tmp -> mv): crash w trakcie nie zostawia obcietego datasource.
_tmp="${OUT}.tmp.$$"
trap 'rm -f "$_tmp"' EXIT
# sed: zdejmij ewentualne cudzyslowy wokol wartosci (zachowanie z czasow
# Makefile-owego targetu - niektore .env-y maja wartosci w cudzyslowiu).
# shellcheck disable=SC2016  # single-quote CELOWO: envsubst potrzebuje literalnych nazw $VAR (whitelista), nie ich wartosci
envsubst '$DJANGO_BPP_DB_HOST $DJANGO_BPP_DB_PORT $DJANGO_BPP_DB_NAME $DJANGO_BPP_DB_USER $DJANGO_BPP_DB_PASSWORD $DJANGO_BPP_PG_MONITOR_PASSWORD' \
    < "$TPL" \
    | sed 's/"\([^"]*\)"/\1/g' \
    > "$_tmp"
mv "$_tmp" "$OUT"
echo "Wygenerowano $OUT"
