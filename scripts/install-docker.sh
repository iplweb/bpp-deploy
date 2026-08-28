#!/usr/bin/env bash
#
# Instalacja Dockera na hoscie.
# Wywolywane przez: make install-docker
#
#   Linux (Debian/Ubuntu) - docker-ce z oficjalnego repozytorium apt.
#   Windows (Git Bash/MSYS2/Cygwin) - Docker Desktop przez winget.
#
# Plik celowo bez polskich znakow diakrytycznych: pod Windows konsola Git
# Basha potrafi pracowac na stronie kodowej innej niz UTF-8 i komunikaty
# rozsypuja sie na krzaki.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# is_windows_shell() - detekcja Git Bash / MSYS2 / Cygwin (cygpath w PATH albo
# uname MINGW*/MSYS*/CYGWIN*). Wspoldzielona z init-configs; biblioteka jest
# bezpieczna do source'owania (zero side-effectow) i pokryta testami
# `make test-config-path`.
# shellcheck source=scripts/lib-config-path.sh
. "$REPO_DIR/scripts/lib-config-path.sh"

# --- Windows: Docker Desktop przez winget ---
#
# Ta galaz MUSI stac PRZED sprawdzeniem roota i przed podbiciem uprawnien:
# pod Git Bash `id -u` nigdy nie zwraca 0 (Windows nie ma uid 0), a `sudo`
# w ogole nie istnieje - skrypt konczylby sie wiec komunikatem o sudo,
# ktorego nie da sie spelnic. Instalator Dockera sam prosi o UAC.
if is_windows_shell; then
    if ! winget --version >/dev/null 2>&1; then
        cat >&2 <<'EOF'

=== Brak wingeta (Instalator aplikacji) ===

Docker Desktop instalujemy przez winget, ktorego na tym systemie nie ma.
Zainstaluj lub zaktualizuj "Instalator aplikacji" ze Sklepu Microsoft:

    https://apps.microsoft.com/detail/9nblggh4nns1?hl=pl-PL&gl=PL

Potem otworz SWIEZE okno Git Basha i powtorz: make install-docker

Alternatywa bez wingeta - pobierz instalator recznie:

    https://www.docker.com/products/docker-desktop/

EOF
        exit 1
    fi

    echo "Instaluje Docker Desktop przez winget..."

    # --source winget jest konieczne: bez niego winget przeszukuje takze
    # Sklep Microsoft (zrodlo msstore) i zamiast instalowac przerywa
    # pytaniem o wybor zrodla albo o akceptacje regulaminu Sklepu.
    winget install -e --id Docker.DockerDesktop --source winget

    echo ""
    echo "Docker Desktop zainstalowany."
    echo "Uruchom go z menu Start i poczekaj, az ikona wieloryba w zasobniku"
    echo "systemowym przestanie sie animowac. Pierwsze uruchomienie moze wlaczyc"
    echo "WSL2 i poprosic o restart komputera."
    exit 0
fi

# --- Linux: podbicie uprawnien ---
#
# Wywolanie sudo siedzi tutaj, a nie w mk/remote.mk, bo pod Git Bash sudo nie
# istnieje i target `make install-docker` wywracalby sie, zanim galaz
# windowsowa powyzej doszlaby do glosu.
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$REPO_DIR/scripts/install-docker.sh" "$@"
    fi
    echo "Ten skrypt musi byc uruchomiony jako root (uzyj sudo)." >&2
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    echo "Brak /etc/os-release - nieobslugiwana dystrybucja." >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    debian)
        DOCKER_REPO_URL="https://download.docker.com/linux/debian"
        ;;
    ubuntu)
        DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
        ;;
    *)
        echo "Nieobslugiwana dystrybucja: ${ID:-nieznana}. Skrypt wspiera Debian i Ubuntu." >&2
        exit 1
        ;;
esac

if [ -z "${VERSION_CODENAME:-}" ]; then
    echo "Brak VERSION_CODENAME w /etc/os-release - nie mozna ustalic wydania dystrybucji." >&2
    exit 1
fi

echo "Instaluje Docker dla ${ID} ${VERSION_CODENAME}..."

# Usuwa stare pakiety jezeli sa zainstalowane.
OLD_PKGS=$(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null | cut -f1 || true)
if [ -n "$OLD_PKGS" ]; then
    # shellcheck disable=SC2086
    apt remove -y $OLD_PKGS || true
fi

apt update
apt install -y ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "${DOCKER_REPO_URL}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_REPO_URL}
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Docker zainstalowany pomyslnie."
