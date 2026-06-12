#!/usr/bin/env bash
set -euo pipefail
#
# "Zaspawanie" wersji obrazow iplweb: utrwala w $BPP_CONFIGS_DIR/.env
# DOCKER_VERSION=<tag CalVer>, na ktorym FAKTYCZNIE chodzi produkcyjny
# appserver (celowo nie: na ktory wskazuje lokalny tag :latest - po
# `make pull` bez recreate te dwa moga sie roznic).
#
# Zasieg: DOCKER_VERSION steruje 5 obrazami iplweb (bpp_appserver,
# bpp_authserver, bpp_workerserver, bpp_denorm_queue, bpp_beatserver).
# Pozostale obrazy sa przypiete na sztywno w plikach compose - nie dotykamy.
#
# Uzycie:
#   make zaspawaj-wersje                  # wersja z dzialajacego appservera
#   make zaspawaj-wersje TAG=202606.1386  # jawny tag
#
# Nic nie jest restartowane - pin obowiazuje od nastepnej operacji compose.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-docker-versions.sh
. "$REPO_DIR/scripts/lib-docker-versions.sh"

# --- BPP_CONFIGS_DIR / ENV_FILE ---
if [ -z "${BPP_CONFIGS_DIR:-}" ] && [ -f "$REPO_DIR/.env" ]; then
    BPP_CONFIGS_DIR="$(grep -E '^BPP_CONFIGS_DIR=' "$REPO_DIR/.env" | tail -1 | cut -d= -f2-)"
fi
if [ -z "${BPP_CONFIGS_DIR:-}" ]; then
    echo "BLAD: BPP_CONFIGS_DIR nie jest ustawione (brak $REPO_DIR/.env?)" >&2
    exit 1
fi
export BPP_CONFIGS_DIR
ENV_FILE="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "BLAD: brak pliku $ENV_FILE" >&2
    exit 1
fi

# --- Helpery .env (kopia per-skrypt; konwencja: configure-resources.sh) ---
env_has_var() { grep -q "^${1}=" "$ENV_FILE" 2>/dev/null; }
set_env_var() {
    local var_name="$1" value="$2" comment="${3:-}"
    if env_has_var "$var_name"; then
        local tmp="$ENV_FILE.tmp.$$"
        awk -v k="$var_name" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
        echo "  ~ zaktualizowano ${var_name}=${value}"
    else
        {
            echo ""
            if [ -n "$comment" ]; then echo "# $comment"; fi
            echo "# Dopisano automatycznie: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "${var_name}=${value}"
        } >> "$ENV_FILE"
        echo "  + dodano ${var_name}=${value}"
    fi
}

APPSERVER_REPO="iplweb/bpp_appserver"
cd "$REPO_DIR"

if [ -n "${TAG:-}" ]; then
    # Jawny tag: walidacja formatu + istnienia na Hubie. Dopiero po OBU
    # sprawdzeniach dotykamy .env.
    if ! printf '%s' "$TAG" | grep -qE "$CALVER_RE"; then
        echo "BLAD: TAG='$TAG' nie wyglada na tag CalVer (oczekiwane np. 202606.1386)" >&2
        exit 1
    fi
    if ! verify_tag_exists "$APPSERVER_REPO" "$TAG"; then
        echo "BLAD: tag '$TAG' nie istnieje w $APPSERVER_REPO na Docker Hubie" >&2
        exit 1
    fi
    VERSION="$TAG"
    echo "Zaspawuje jawnie podana wersje: $VERSION"
else
    echo "Odczytuje wersje z dzialajacego kontenera appserver..."
    DIGEST="$(running_repo_digest appserver)" || {
        echo "Podpowiedz: uruchom stack (make up) albo podaj wersje jawnie:" >&2
        echo "  make zaspawaj-wersje TAG=202606.1386" >&2
        exit 1
    }
    VERSION="$(resolve_digest_to_calver "$APPSERVER_REPO" "$DIGEST")" || {
        echo "Podpowiedz: obraz nie pochodzi z Docker Huba albo jest starszy niz" >&2
        echo "100 ostatnich tagow. Podaj wersje jawnie: make zaspawaj-wersje TAG=..." >&2
        exit 1
    }
    echo "appserver chodzi na ${APPSERVER_REPO}@${DIGEST} = ${VERSION}"

    # Sanity-check (best-effort): czy pozostale uslugi iplweb chodza na tej
    # samej wersji? Kazde repo ma wlasne digesty, wiec porownujemy po
    # rozwiazanych tagach CalVer. Rozjazd = tylko ostrzezenie.
    for pair in authserver:bpp_authserver workerserver:bpp_workerserver \
                denorm-queue:bpp_denorm_queue celerybeat:bpp_beatserver; do
        svc="${pair%%:*}"; repo="iplweb/${pair##*:}"
        svc_digest="$(running_repo_digest "$svc" 2>/dev/null)" || {
            echo "  UWAGA: nie moge odczytac obrazu uslugi '$svc' - pomijam"
            continue
        }
        svc_ver="$(resolve_digest_to_calver "$repo" "$svc_digest" 2>/dev/null)" || {
            echo "  UWAGA: nie moge rozwiazac wersji uslugi '$svc' - pomijam"
            continue
        }
        if [ "$svc_ver" != "$VERSION" ]; then
            echo "  UWAGA: $svc chodzi na $svc_ver != $VERSION (appserver)."
            echo "         Spawam wedlug appservera; rozjazd wyrowna nastepne 'make up'."
        fi
    done
fi

set_env_var "DOCKER_VERSION" "$VERSION" \
    "Wersja obrazow iplweb/bpp_* (zaspawana przez make zaspawaj-wersje)"

echo ""
echo "Zaspawano DOCKER_VERSION=${VERSION} w ${ENV_FILE}."
echo "Nic nie zostalo zrestartowane - pin obowiazuje od nastepnej operacji"
echo "docker compose. Aktualizacja na nowsza wersje:"
echo "  make zaspawaj-wersje TAG=<nowy> && make pull && make up"
