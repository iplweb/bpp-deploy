#!/usr/bin/env bash
#
# Sprawdza czy przypiete wersje obrazow Docker sa aktualne.
# Porownuje wersje z docker-compose.*.yml z najnowszymi tagami na Docker Hub / quay.io.
#
# Uruchomienie:
#   bash repo-management/check-image-versions.sh
#
# Wymaga: curl, python3

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Wyciagnij wszystkie nieblokowane obrazy (pomijamy iplweb/* bo to nasze wlasne)
mapfile -t IMAGES < <(
    grep -h 'image:' "$REPO_DIR"/docker-compose.*.yml \
        | sed 's/.*image: *//' \
        | sed 's/\$\{DOCKER_VERSION:-latest\}/latest/' \
        | sort -u \
        | grep -v 'iplweb/'
)

# Wspolny skrypt Pythona do filtrowania tagow
FILTER_SCRIPT='
import sys, json, re

current = sys.argv[1]
key = sys.argv[2]  # "results" for Docker Hub, "tags" for quay.io

data = json.load(sys.stdin)

# Detect suffix pattern from current tag (e.g. "-management-alpine")
suffix_match = re.match(r"^v?\d+[\d.]*(.*)", current)
suffix = suffix_match.group(1) if suffix_match else ""

skip_words = {"latest", "edge", "nightly", "main", "master", "beta", "alpha", "rc",
              "dev", "debug", "distroless", "windowsservercore", "ltsc", "ubuntu",
              "trixie", "bookworm", "bullseye", "jammy", "noble", "focal"}

tags = []
for t in data.get(key, []):
    name = t["name"]
    name_lower = name.lower()
    if any(w in name_lower for w in skip_words):
        continue
    if not re.match(r"^v?\d+\.\d+", name):
        continue
    if suffix:
        if not name.endswith(suffix):
            continue
    else:
        version_part = re.match(r"^(v?\d+[\d.]*)(.*)", name)
        if version_part and version_part.group(2):
            continue
    tags.append(name)

# Sort by semantic version (descending)
def version_key(tag):
    nums = re.findall(r"\d+", tag)
    return tuple(int(n) for n in nums)

tags.sort(key=version_key, reverse=True)

if tags:
    print(tags[0])
else:
    print("?")
'

get_latest_dockerhub() {
    local repo="$1" current_tag="$2"

    if [[ "$repo" != */* ]]; then
        repo="library/$repo"
    fi

    curl -s "https://hub.docker.com/v2/repositories/$repo/tags/?page_size=100&ordering=last_updated" \
        | python3 -c "$FILTER_SCRIPT" "$current_tag" "results" 2>/dev/null \
        || echo "?"
}

get_latest_quay() {
    local full_repo="$1" current_tag="$2"
    local repo="${full_repo#quay.io/}"

    curl -s "https://quay.io/api/v1/repository/$repo/tag/?limit=100&onlyActiveTags=true" \
        | python3 -c "$FILTER_SCRIPT" "$current_tag" "tags" 2>/dev/null \
        || echo "?"
}

echo "Sprawdzanie wersji obrazow Docker..."
echo ""

OUTDATED=0
for entry in "${IMAGES[@]}"; do
    image="${entry%%:*}"
    current="${entry##*:}"

    if [[ "$image" == quay.io/* ]]; then
        latest=$(get_latest_quay "$image" "$current")
    else
        latest=$(get_latest_dockerhub "$image" "$current")
    fi

    if [ "$latest" = "?" ]; then
        printf "  %-55s  %s\n" "$image:$current" "? (nie udalo sie sprawdzic)"
    elif [ "$latest" = "$current" ]; then
        printf "  %-55s  %s\n" "$image:$current" "OK"
    else
        printf "  %-55s  %s -> %s\n" "$image:$current" "NIEAKTUALNE" "$latest"
        OUTDATED=$((OUTDATED + 1))
    fi
done

echo ""
if [ "$OUTDATED" -gt 0 ]; then
    echo "Znaleziono $OUTDATED nieaktualnych obrazow."
    echo "Aby zaktualizowac, edytuj odpowiedni plik docker-compose.*.yml"
else
    echo "Wszystkie obrazy sa aktualne."
fi
