#!/usr/bin/env bash
# Wspolne funkcje mapowania digest <-> tag CalVer dla obrazow iplweb/* na
# Docker Hubie. Source'owana przez scripts/test-upgrade.sh i
# scripts/zaspawaj-wersje.sh - bez side-effectow przy source.
# Zaleznosci: curl, jq, docker (tylko running_repo_digest).
#
# Tagi CalVer obrazow BPP: YYYYMM.NNNN (np. 202606.1386). `latest` na Hubie
# wskazuje ten sam digest co najnowszy tag CalVer.

# Wzorzec tagu CalVer (BSD/GNU `grep -E` compatible).
CALVER_RE='^[0-9]{6}\.[0-9]+$'

# Endpoint API - nadpisywalny w testach.
HUB_API="${HUB_API:-https://hub.docker.com/v2}"

# _hub_tags_json <repo> -- surowy JSON pierwszych 100 tagow repozytorium.
_hub_tags_json() {
    curl -fsS "$HUB_API/repositories/$1/tags?page_size=100"
}

# resolve_latest_calver <repo>
# stdout: najnowszy (numerycznie) tag CalVer; exit 1 gdy brak / blad sieci.
resolve_latest_calver() {
    local repo="$1" tag
    tag="$(_hub_tags_json "$repo" \
        | jq -r '.results[].name' \
        | grep -E "$CALVER_RE" \
        | sort -t. -k1,1n -k2,2n \
        | tail -1)" || true
    if [ -z "$tag" ]; then
        echo "BLAD: nie znaleziono tagu CalVer dla $repo (siec? API Huba?)" >&2
        return 1
    fi
    printf '%s\n' "$tag"
}

# resolve_digest_to_calver <repo> <sha256:...>
# stdout: tag CalVer o tym digescie (manifest-list LUB per-arch z .images[]);
# exit 1 gdy nie znaleziono.
resolve_digest_to_calver() {
    local repo="$1" digest="$2" tag
    tag="$(_hub_tags_json "$repo" \
        | jq -r --arg d "$digest" \
            '.results[]
             | select(((.digest // "") == $d)
                      or (([.images[]?.digest // empty] | index($d)) != null))
             | .name' \
        | grep -E "$CALVER_RE" \
        | head -1)" || true
    if [ -z "$tag" ]; then
        echo "BLAD: digest $digest nie odpowiada zadnemu tagowi CalVer w $repo" >&2
        return 1
    fi
    printf '%s\n' "$tag"
}

# verify_tag_exists <repo> <tag> -- exit 0 gdy tag istnieje na Hubie.
verify_tag_exists() {
    curl -fsS "$HUB_API/repositories/$1/tags/$2" >/dev/null 2>&1
}

# running_repo_digest <compose-service>
# stdout: digest (sha256:...) obrazu, na ktorym CHODZI kontener uslugi -
# celowo nie z lokalnego tagu :latest (po `make pull` bez recreate lokalny
# tag moze juz wskazywac nowszy obraz niz dzialajacy kontener).
# Wymaga CWD = katalog repo (docker compose). exit 1 gdy kontener nie dziala
# albo obraz nie ma RepoDigests (np. budowany lokalnie).
running_repo_digest() {
    local svc="$1" cid img digest
    cid="$(docker compose ps -q "$svc" 2>/dev/null | head -1)"
    if [ -z "$cid" ]; then
        echo "BLAD: kontener uslugi '$svc' nie dziala" >&2
        return 1
    fi
    img="$(docker inspect --format '{{.Image}}' "$cid")"
    digest="$(docker image inspect --format '{{join .RepoDigests "\n"}}' "$img" \
        | head -1 | sed 's/.*@//')"
    if [ -z "$digest" ]; then
        echo "BLAD: obraz uslugi '$svc' nie ma RepoDigests (obraz lokalny?)" >&2
        return 1
    fi
    printf '%s\n' "$digest"
}
