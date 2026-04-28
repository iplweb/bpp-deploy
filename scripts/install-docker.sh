#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
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
