# `make test-upgrade` + `make zaspawaj-wersje` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dwa ręczne cele make: `test-upgrade` (próba generalna migracji obrazu-kandydata na kopii produkcyjnej bazy, bez dotykania produkcji) i `zaspawaj-wersje` (pinowanie `DOCKER_VERSION` w `.env` do wersji, na której faktycznie chodzi appserver).

**Architecture:** Wspólna biblioteka shellowa (`lib-docker-versions.sh`) mapuje digesty obrazów ↔ tagi CalVer przez API Docker Huba. `zaspawaj-wersje.sh` zapisuje wynik do `.env` stabilnym helperem `set_env_var`. `test-upgrade.sh` stawia shadow stack (dbserver+redis) czystym `docker run` poza projektem Compose, restoruje świeży dump i odpala `manage.py migrate` obrazem-kandydatem z nadpisanym entrypointem. Spec: `docs/superpowers/specs/2026-06-12-test-upgrade-zaspawaj-wersje-design.md`.

**Tech Stack:** bash (BSD/GNU-portable — testy biegają też na macOS), curl + jq, docker / docker compose, GNU make. Testy jednostkowe w konwencji repo (`scripts/test-letsencrypt.sh`): mockowane `curl`/`docker` w PATH, zero sieci, zero Docker daemona.

---

## File Structure

| Plik | Odpowiedzialność |
|---|---|
| `scripts/lib-docker-versions.sh` (create) | Czyste funkcje: `resolve_latest_calver`, `resolve_digest_to_calver`, `verify_tag_exists`, `running_repo_digest`. Source'owana, bez side-effectów. |
| `scripts/test-docker-versions.sh` (create) | Testy jednostkowe lib + `zaspawaj-wersje.sh` + `test-upgrade.sh --clean` (mock curl/docker). |
| `scripts/zaspawaj-wersje.sh` (create) | Pinowanie `DOCKER_VERSION` w `.env` (z `TAG=` lub z działającego kontenera). |
| `scripts/test-upgrade.sh` (create) | Próba generalna + `--clean`. |
| `mk/configs.mk` (modify) | Target `zaspawaj-wersje`. |
| `mk/misc.mk` (modify) | Target `test-docker-versions`. |
| `mk/deployment.mk` (modify) | Targety `test-upgrade`, `test-upgrade-clean`. |
| `Makefile` (modify) | Wpisy w `make help`. |
| `docs/eksploatacja/komendy.md` (modify) | Sekcja operatorska dla obu celów. |
| `CLAUDE.md` (modify) | Kontrakt pinowania `DOCKER_VERSION` (agent steering). |

Konwencje repo, których trzymamy się wszędzie:

- Helpery `.env` (`env_has_var`/`get_env_var`/`set_env_var`) są **kopiowane per-skrypt** (precedens: `scripts/configure-resources.sh`), nie source'owane z `init-configs.sh` (tamten skrypt wykonuje się przy source).
- Komunikaty PL bez ogonków w skryptach (konwencja: `init-configs.sh`, `test-letsencrypt.sh`).
- BSD/GNU-portability: `grep -E`, `df -Pm`, bez bashowych tablic asocjacyjnych (macOS ma bash 3.2).
- Po edycji docs: `mkdocs build --strict`.

---

### Task 1: Biblioteka `lib-docker-versions.sh` (TDD)

**Files:**
- Create: `scripts/test-docker-versions.sh`
- Create: `scripts/lib-docker-versions.sh`

- [ ] **Step 1: Napisz failing testy (harness + testy samej lib)**

Utwórz `scripts/test-docker-versions.sh` (chmod +x):

```bash
#!/usr/bin/env bash
#
# Testy scripts/lib-docker-versions.sh, scripts/zaspawaj-wersje.sh oraz
# scripts/test-upgrade.sh (sciezka --clean).
#
# Bez sieci i bez Docker daemona: `curl` i `docker` sa mockowane
# stub-skryptami w PATH (konwencja: scripts/test-letsencrypt.sh).
#
# Uruchomienie: `make test-docker-versions` lub
#   `bash scripts/test-docker-versions.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/scripts/lib-docker-versions.sh"

TEST_ROOT="$(mktemp -d -t bpp-docker-versions-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
CURL_LOG="$TEST_ROOT/curl-calls.log"
DOCKER_LOG="$TEST_ROOT/docker-calls.log"
FIXTURES="$TEST_ROOT/fixtures"
mkdir -p "$MOCK_BIN" "$FIXTURES"

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
PASS=0; FAIL=0
pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else
        fail "$name (oczekiwane '$expected', otrzymano '$actual')"; fi
}
assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else
        fail "$name (oczekiwany exit=$expected, otrzymany exit=$actual)"; fi
}
assert_nonzero() {
    local actual="$1" name="$2"
    if [ "$actual" != "0" ]; then pass "$name"; else
        fail "$name (oczekiwany exit != 0, otrzymany 0)"; fi
}
assert_file_contains() {
    local file="$1" needle="$2" name="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then pass "$name"; else
        fail "$name (brak '$needle' w $file)"; fi
}
assert_file_not_contains() {
    local file="$1" needle="$2" name="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        fail "$name ('$needle' obecne w $file)"; else pass "$name"; fi
}

# --- Mock curl ---
# Ostatni argument wywolania = URL.
#   .../tags?page_size=... -> cat $CURL_FIXTURE (lista tagow)
#   .../tags/<tag>         -> exit 0 gdy CURL_TAG_EXISTS=1 (domyslnie), inaczej 22
cat > "$MOCK_BIN/curl" <<EOF
#!/bin/sh
for last; do :; done
echo "\$last" >> "$CURL_LOG"
case "\$last" in
  *"/tags?page_size="*)
      if [ -n "\${CURL_FIXTURE:-}" ]; then cat "\$CURL_FIXTURE"; else exit 22; fi ;;
  *"/tags/"*)
      [ "\${CURL_TAG_EXISTS:-1}" = "1" ] || exit 22 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$MOCK_BIN/curl"

# --- Mock docker ---
#   compose ps -q appserver  -> cid (pusty gdy MOCK_APPSERVER_RUNNING=0)
#   compose ps -q <inne>     -> cid-other
#   inspect --format {{.Image}} cid-* -> img-123
#   image inspect --format ... img-123 -> repo digest (MOCK_RUNNING_DIGEST)
cat > "$MOCK_BIN/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$DOCKER_LOG"
case "\$*" in
  "compose ps -q appserver")
      if [ "\${MOCK_APPSERVER_RUNNING:-1}" = "1" ]; then echo "cid-app"; fi ;;
  "compose ps -q "*)
      echo "cid-other" ;;
  "inspect --format {{.Image}} cid-"*)
      echo "img-123" ;;
  "image inspect --format "*)
      echo "iplweb/bpp_appserver@\${MOCK_RUNNING_DIGEST:-sha256:aaa}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_BIN/docker"

export PATH="$MOCK_BIN:$PATH"

# --- Fixtures API Docker Huba ---
cat > "$FIXTURES/tags.json" <<'EOF'
{"results":[
 {"name":"latest","digest":"sha256:aaa","images":[{"digest":"sha256:arm64aaa"},{"digest":"sha256:amd64aaa"}]},
 {"name":"feature-multi-hosted-config","digest":"sha256:fff","images":[]},
 {"name":"sha-56127ac","digest":"sha256:aaa","images":[]},
 {"name":"202606.1386","digest":"sha256:aaa","images":[{"digest":"sha256:arm64aaa"},{"digest":"sha256:amd64aaa"}]},
 {"name":"202606.999","digest":"sha256:bbb","images":[{"digest":"sha256:armbbb"}]},
 {"name":"202605.1300","digest":"sha256:ccc","images":[]}
]}
EOF
cat > "$FIXTURES/no-calver.json" <<'EOF'
{"results":[{"name":"latest","digest":"sha256:aaa","images":[]}]}
EOF

# ===================== Testy lib-docker-versions.sh =====================
echo "== lib-docker-versions.sh =="
# shellcheck source=/dev/null
. "$LIB"

export CURL_FIXTURE="$FIXTURES/tags.json"

out="$(resolve_latest_calver iplweb/bpp_appserver)"
assert_eq "202606.1386" "$out" "resolve_latest_calver: najnowszy numerycznie (1386 > 999)"

out="$(resolve_digest_to_calver iplweb/bpp_appserver sha256:aaa)"
assert_eq "202606.1386" "$out" "resolve_digest_to_calver: digest manifest-list"

out="$(resolve_digest_to_calver iplweb/bpp_appserver sha256:armbbb)"
assert_eq "202606.999" "$out" "resolve_digest_to_calver: digest per-arch (images[])"

rc=0; resolve_digest_to_calver iplweb/bpp_appserver sha256:zzz >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "resolve_digest_to_calver: nieznany digest -> exit != 0"

CURL_FIXTURE="$FIXTURES/no-calver.json"
rc=0; resolve_latest_calver iplweb/bpp_appserver >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "resolve_latest_calver: brak tagow CalVer -> exit != 0"
CURL_FIXTURE="$FIXTURES/tags.json"

rc=0; verify_tag_exists iplweb/bpp_appserver 202606.1386 || rc=$?
assert_exit 0 "$rc" "verify_tag_exists: istniejacy tag -> exit 0"

rc=0; CURL_TAG_EXISTS=0 verify_tag_exists iplweb/bpp_appserver 999999.1 || rc=$?
assert_nonzero "$rc" "verify_tag_exists: brak tagu -> exit != 0"

out="$(running_repo_digest appserver)"
assert_eq "sha256:aaa" "$out" "running_repo_digest: digest z dzialajacego kontenera"

rc=0; MOCK_APPSERVER_RUNNING=0 running_repo_digest appserver >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "running_repo_digest: kontener nie dziala -> exit != 0"

# ======================= Podsumowanie =======================
echo ""
echo "Wynik: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

(Testy `zaspawaj-wersje.sh` i `--clean` dojdą w Taskach 2 i 4 — sekcje wstawiane PRZED blokiem `Podsumowanie`.)

- [ ] **Step 2: Uruchom testy — mają polec (brak lib)**

Run: `bash scripts/test-docker-versions.sh`
Expected: błąd przy `. "$LIB"` (No such file or directory), exit != 0.

- [ ] **Step 3: Zaimplementuj `scripts/lib-docker-versions.sh`**

```bash
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
```

- [ ] **Step 4: Uruchom testy — mają przejść**

Run: `bash scripts/test-docker-versions.sh`
Expected: `PASS=9 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib-docker-versions.sh scripts/test-docker-versions.sh
git commit -m "feat(versions): lib digest<->CalVer dla obrazow iplweb + testy (mock curl/docker)"
```

---

### Task 2: `scripts/zaspawaj-wersje.sh` (TDD)

**Files:**
- Modify: `scripts/test-docker-versions.sh` (dopisz sekcję testów przed `Podsumowanie`)
- Create: `scripts/zaspawaj-wersje.sh`

- [ ] **Step 1: Dopisz failing testy**

W `scripts/test-docker-versions.sh`, PRZED blokiem `# ======================= Podsumowanie =======================`, wstaw:

```bash
# ===================== Testy zaspawaj-wersje.sh =====================
echo ""
echo "== zaspawaj-wersje.sh =="
ZW="$REPO_DIR/scripts/zaspawaj-wersje.sh"

make_env() {  # make_env <nazwa> -> sciezka swiezego katalogu konfiguracyjnego
    local dir="$TEST_ROOT/configs-$1"
    mkdir -p "$dir"
    cat > "$dir/.env" <<'ENVEOF'
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=sekret
ENVEOF
    printf '%s' "$dir"
}

# 1. Jawny TAG, poprawny i istniejacy -> wpis w .env, exit 0
cfg="$(make_env tag-ok)"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=202606.1386 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "zaspawaj: TAG poprawny -> exit 0"
assert_file_contains "$cfg/.env" "DOCKER_VERSION=202606.1386" "zaspawaj: DOCKER_VERSION zapisany"

# 2. TAG o zlym formacie -> exit != 0, .env nietkniety
cfg="$(make_env tag-bad)"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=latest bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "zaspawaj: TAG=latest odrzucony (nie-CalVer)"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION" "zaspawaj: .env nietkniety po blednym TAG"

# 3. TAG nieistniejacy na Hubie -> exit != 0, .env nietkniety
cfg="$(make_env tag-missing)"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=209912.1 CURL_TAG_EXISTS=0 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "zaspawaj: TAG nieistniejacy na Hubie odrzucony"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION" "zaspawaj: .env nietkniety po nieistniejacym TAG"

# 4. Bez TAG: wersja rozwiazana z digestu dzialajacego appservera
cfg="$(make_env running)"
rc=0; BPP_CONFIGS_DIR="$cfg" bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "zaspawaj: bez TAG -> exit 0 (digest dzialajacego appservera)"
assert_file_contains "$cfg/.env" "DOCKER_VERSION=202606.1386" "zaspawaj: wersja z digestu sha256:aaa"

# 5. Istniejacy DOCKER_VERSION jest nadpisywany (idempotentne przybicie)
cfg="$(make_env overwrite)"
echo "DOCKER_VERSION=202601.1" >> "$cfg/.env"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=202606.1386 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "zaspawaj: nadpisanie istniejacej wartosci -> exit 0"
assert_file_contains "$cfg/.env" "DOCKER_VERSION=202606.1386" "zaspawaj: nowa wartosc zapisana"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION=202601.1" "zaspawaj: stara wartosc usunieta"

# 6. Appserver nie dziala (i brak TAG) -> exit != 0, .env nietkniety
cfg="$(make_env not-running)"
rc=0; BPP_CONFIGS_DIR="$cfg" MOCK_APPSERVER_RUNNING=0 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "zaspawaj: appserver nie dziala -> exit != 0"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION" "zaspawaj: .env nietkniety gdy appserver nie dziala"
```

- [ ] **Step 2: Uruchom testy — nowa sekcja ma polec**

Run: `bash scripts/test-docker-versions.sh`
Expected: 9 PASS z Taska 1, potem FAIL-e sekcji zaspawaj (brak skryptu), exit != 0.

- [ ] **Step 3: Zaimplementuj `scripts/zaspawaj-wersje.sh`**

```bash
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
```

(chmod +x)

- [ ] **Step 4: Uruchom testy — mają przejść**

Run: `bash scripts/test-docker-versions.sh`
Expected: `PASS=22 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/zaspawaj-wersje.sh scripts/test-docker-versions.sh
git commit -m "feat(zaspawaj-wersje): pinowanie DOCKER_VERSION do wersji dzialajacego appservera"
```

---

### Task 3: Targety make + help dla `zaspawaj-wersje` i `test-docker-versions`

**Files:**
- Modify: `mk/configs.mk` (linia 1: `.PHONY`, koniec pliku: target)
- Modify: `mk/misc.mk` (linia 1: `.PHONY`, koniec pliku: target)
- Modify: `Makefile` (sekcja help "Configuration", po linii `fix-env-quotes`, ok. linii 147)

- [ ] **Step 1: Dodaj target w `mk/configs.mk`**

W linii 1 dopisz do `.PHONY`: `zaspawaj-wersje`. Na końcu pliku:

```makefile
# Przypina DOCKER_VERSION w $(BPP_CONFIGS_DIR)/.env do wersji CalVer, na
# ktorej faktycznie chodzi appserver (lub jawnej: TAG=202606.1386).
# Szczegoly i kontrakt: docs/eksploatacja/komendy.md, CLAUDE.md.
zaspawaj-wersje:
	@TAG="$(TAG)" bash scripts/zaspawaj-wersje.sh
```

- [ ] **Step 2: Dodaj target w `mk/misc.mk`**

W linii 1 dopisz do `.PHONY`: `test-docker-versions`. Na końcu pliku:

```makefile
test-docker-versions:
	@bash scripts/test-docker-versions.sh
```

- [ ] **Step 3: Dodaj wpisy do `make help` w `Makefile`**

Po linii `@echo "    fix-env-quotes       - Auto-strip cudzyslowy z .env (z backupem .bak.<ts>)"` dopisz:

```makefile
	@echo "    zaspawaj-wersje      - Przypnij DOCKER_VERSION do wersji dzialajacego appservera (lub TAG=...)"
	@echo "    test-docker-versions - Unit-testy logiki wersji obrazow (mock curl/docker, no network)"
```

- [ ] **Step 4: Zweryfikuj**

Run: `make test-docker-versions`
Expected: `PASS=20 FAIL=0`.

Run: `make help | grep -E "zaspawaj|test-docker"`
Expected: obie linie widoczne.

Run: `make -n zaspawaj-wersje TAG=202606.1386`
Expected: wypisuje `TAG="202606.1386" bash scripts/zaspawaj-wersje.sh` (dry-run, nic nie wykonuje).

- [ ] **Step 5: Commit**

```bash
git add mk/configs.mk mk/misc.mk Makefile
git commit -m "feat(make): targety zaspawaj-wersje + test-docker-versions"
```

---

### Task 4: `scripts/test-upgrade.sh` (próba generalna + `--clean`)

**Files:**
- Modify: `scripts/test-docker-versions.sh` (sekcja testów `--clean` przed `Podsumowanie`)
- Create: `scripts/test-upgrade.sh`

- [ ] **Step 1: Dopisz failing testy `--clean`**

W `scripts/test-docker-versions.sh`, PRZED blokiem `Podsumowanie`, wstaw:

```bash
# ===================== Testy test-upgrade.sh (--clean) =====================
echo ""
echo "== test-upgrade.sh --clean =="
TU="$REPO_DIR/scripts/test-upgrade.sh"

: > "$DOCKER_LOG"
rc=0; bash "$TU" --clean >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "test-upgrade --clean: exit 0"
assert_file_contains "$DOCKER_LOG" "rm -f bpp-shadow-dbserver bpp-shadow-redis" "--clean: usuwa kontenery shadow"
assert_file_contains "$DOCKER_LOG" "volume rm -f bpp-shadow-pgdata" "--clean: usuwa wolumen shadow"
assert_file_contains "$DOCKER_LOG" "network rm bpp-shadow" "--clean: usuwa siec shadow"

rc=0; bash -n "$TU" || rc=$?
assert_exit 0 "$rc" "test-upgrade.sh: poprawna skladnia (bash -n)"
```

- [ ] **Step 2: Uruchom testy — sekcja `--clean` ma polec**

Run: `bash scripts/test-docker-versions.sh`
Expected: dotychczasowe 22 PASS, FAIL-e w sekcji test-upgrade, exit != 0.

- [ ] **Step 3: Zaimplementuj `scripts/test-upgrade.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
#
# Proba generalna aktualizacji: czy migracje obrazu-kandydata przechodza na
# kopii produkcyjnej bazy? Dziala CALKOWICIE obok produkcji:
#   - shadow stack (dbserver+redis) czystym `docker run`, poza projektem
#     Compose, na wlasnej sieci bpp-shadow,
#   - pull kandydata PO TAGU WERSJI - lokalny tag :latest produkcji
#     pozostaje nietkniety,
#   - zero zapisu do .env, zero operacji na kontenerach/wolumenach produkcji.
#
# Uzycie:
#   make test-upgrade                  # kandydat = najnowszy CalVer z Huba
#   make test-upgrade TAG=202606.1386  # jawny kandydat
#   make test-upgrade-clean            # sprzatniecie shadow stacka
#
# Wynik: exit 0 = migracje przechodza (shadow posprzatany);
#        exit != 0 = blad (shadow ZOSTAJE do inspekcji).

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-docker-versions.sh
. "$REPO_DIR/scripts/lib-docker-versions.sh"

SHADOW_NET="bpp-shadow"
SHADOW_DB="bpp-shadow-dbserver"
SHADOW_REDIS="bpp-shadow-redis"
SHADOW_VOL="bpp-shadow-pgdata"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
# Limity zasobow shadow stacka - przyciete, zeby nie zaglodzic produkcji.
SHADOW_DB_MEM="${SHADOW_DB_MEM:-1g}"
SHADOW_DB_CPUS="${SHADOW_DB_CPUS:-1.0}"
SHADOW_REDIS_MEM="${SHADOW_REDIS_MEM:-256m}"
SHADOW_MIGRATE_MEM="${SHADOW_MIGRATE_MEM:-2g}"

cleanup_shadow() {
    docker rm -f "$SHADOW_DB" "$SHADOW_REDIS" >/dev/null 2>&1 || true
    docker volume rm -f "$SHADOW_VOL" >/dev/null 2>&1 || true
    docker network rm "$SHADOW_NET" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--clean" ]; then
    echo "Sprzatam shadow stack ($SHADOW_DB, $SHADOW_REDIS, $SHADOW_VOL, $SHADOW_NET)..."
    cleanup_shadow
    echo "OK."
    exit 0
fi

print_inspect_help() {
    echo "" >&2
    echo "Shadow stack ZOSTAJE do inspekcji:" >&2
    echo "  docker exec -it $SHADOW_DB psql -U \"\$DJANGO_BPP_DB_USER\" -d \"\$DJANGO_BPP_DB_NAME\"" >&2
    echo "Sprzatniecie: make test-upgrade-clean" >&2
}
trap print_inspect_help ERR

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

# --- Helper .env (kopia per-skrypt; konwencja: init-configs.sh) ---
get_env_var() {
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

DB_NAME="$(get_env_var DJANGO_BPP_DB_NAME)"
DB_USER="$(get_env_var DJANGO_BPP_DB_USER)"
DB_PASSWORD="$(get_env_var DJANGO_BPP_DB_PASSWORD)"
if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    echo "BLAD: brak DJANGO_BPP_DB_NAME/USER/PASSWORD w $ENV_FILE" >&2
    exit 1
fi

# Wersja PG: ta sama logika dwuwarstwowego fallbacku co docker-compose.database.yml.
PG_VERSION="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION)"
[ -n "$PG_VERSION" ] || PG_VERSION="$(get_env_var DJANGO_BPP_DBSERVER_PG_VERSION)"
[ -n "$PG_VERSION" ] || PG_VERSION="16.13"

# Katalog backupow: ta sama logika fallbacku co mk/database.mk.
BACKUP_DIR="$(get_env_var DJANGO_BPP_HOST_BACKUP_DIR)"
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$(get_env_var DJANGO_BPP_BACKUP_DIR)"
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$(cd "$BPP_CONFIGS_DIR/.." && pwd)/backups"
mkdir -p "$BACKUP_DIR"

# Wersja redisa: ta sama co produkcyjna (z compose - zero driftu).
REDIS_IMAGE="$(grep -Eo 'redis:[0-9][0-9.]*' "$REPO_DIR/docker-compose.infrastructure.yml" | head -1)"
[ -n "$REDIS_IMAGE" ] || REDIS_IMAGE="redis:8.6.2"

APPSERVER_REPO="iplweb/bpp_appserver"
cd "$REPO_DIR"

# --- [1/6] Kandydat ---
echo "=== [1/6] Rozwiazuje obraz-kandydata ==="
if [ -n "${TAG:-}" ]; then
    if ! printf '%s' "$TAG" | grep -qE "$CALVER_RE"; then
        echo "BLAD: TAG='$TAG' nie wyglada na tag CalVer (np. 202606.1386)" >&2
        exit 1
    fi
    CANDIDATE="$TAG"
else
    CANDIDATE="$(resolve_latest_calver "$APPSERVER_REPO")"
fi
echo "Kandydat: ${APPSERVER_REPO}:${CANDIDATE}"
# Pull po tagu wersji - lokalny :latest produkcji nietkniety.
docker pull "${APPSERVER_REPO}:${CANDIDATE}"

# --- [2/6] Kontrola miejsca na dysku ---
echo "=== [2/6] Kontrola miejsca na dysku ==="
if [ "${SKIP_DISK_CHECK:-0}" != "1" ]; then
    DB_SIZE_MB="$(docker compose exec -T dbserver psql -U "$DB_USER" -d "$DB_NAME" \
        -tAc "SELECT pg_database_size('$DB_NAME')/1024/1024;" | tr -d '[:space:]')"
    NEED_MB=$(( DB_SIZE_MB * 5 / 2 ))   # ~2.5x: dump + untar + shadow volume
    FREE_BACKUP_MB="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
    FREE_DOCKER_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$FREE_DOCKER_MB" ] || FREE_DOCKER_MB="$FREE_BACKUP_MB"
    echo "Baza: ${DB_SIZE_MB} MB; wymagane ~${NEED_MB} MB wolnego miejsca."
    if [ "$FREE_BACKUP_MB" -lt "$NEED_MB" ] || [ "$FREE_DOCKER_MB" -lt "$NEED_MB" ]; then
        echo "BLAD: za malo miejsca (backup dir: ${FREE_BACKUP_MB} MB, docker root: ${FREE_DOCKER_MB} MB)." >&2
        echo "Wymuszenie pominiecia kontroli: SKIP_DISK_CHECK=1 make test-upgrade" >&2
        exit 1
    fi
else
    echo "(pominieta: SKIP_DISK_CHECK=1)"
fi

# --- [3/6] Backup produkcyjnej bazy ---
echo "=== [3/6] Backup produkcyjnej bazy (make db-backup) ==="
make -C "$REPO_DIR" db-backup
BACKUP_TAR_PATH="$(ls -t "$BACKUP_DIR"/db-backup-*.tar.gz 2>/dev/null | head -1)"
if [ -z "$BACKUP_TAR_PATH" ]; then
    echo "BLAD: nie znalazlem swiezego dumpa w $BACKUP_DIR" >&2
    exit 1
fi
BACKUP_TAR="$(basename "$BACKUP_TAR_PATH")"
BACKUP_DIRNAME="${BACKUP_TAR%.tar.gz}"
echo "Dump: $BACKUP_TAR_PATH"

# --- [4/6] Shadow stack ---
echo "=== [4/6] Stawiam shadow stack (siec $SHADOW_NET) ==="
cleanup_shadow   # zombie z poprzedniego przebiegu
docker network create "$SHADOW_NET" >/dev/null
docker volume create "$SHADOW_VOL" >/dev/null
docker run -d --name "$SHADOW_DB" --network "$SHADOW_NET" \
    -e POSTGRES_DB="$DB_NAME" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -v "$SHADOW_VOL":/var/lib/postgresql/data \
    -v "$BACKUP_DIR":/backup:ro \
    --memory "$SHADOW_DB_MEM" --cpus "$SHADOW_DB_CPUS" \
    "iplweb/bpp_dbserver:psql-${PG_VERSION}" >/dev/null
docker run -d --name "$SHADOW_REDIS" --network "$SHADOW_NET" \
    --memory "$SHADOW_REDIS_MEM" \
    "$REDIS_IMAGE" >/dev/null

echo "Czekam na gotowosc shadow-postgresa..."
for i in $(seq 1 60); do
    if docker exec "$SHADOW_DB" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "BLAD: shadow-postgres nie wstal w 120 s" >&2
        exit 1
    fi
    sleep 2
done

# --- [5/6] Restore dumpa do shadow-bazy ---
echo "=== [5/6] Restore dumpa do shadow-bazy (pg_restore -j $PARALLEL_JOBS) ==="
docker exec "$SHADOW_DB" mkdir -p /tmp/restore
docker exec "$SHADOW_DB" tar xzf "/backup/$BACKUP_TAR" -C /tmp/restore
docker exec "$SHADOW_DB" pg_restore -Fd -j "$PARALLEL_JOBS" --no-owner \
    -U "$DB_USER" -d "$DB_NAME" "/tmp/restore/$BACKUP_DIRNAME"

# --- [6/6] Migracja obrazem-kandydatem ---
echo "=== [6/6] manage.py migrate obrazem ${APPSERVER_REPO}:${CANDIDATE} ==="
# Entrypoint nadpisany: zadnych faz startowych (staticfiles, gunicorn) -
# wylacznie migracja. --env-file daje komplet zmiennych jak w produkcji,
# -e nadpisuje hosty na shadow.
set +e
docker run --rm --network "$SHADOW_NET" \
    --env-file "$ENV_FILE" \
    -e DJANGO_BPP_DB_HOST="$SHADOW_DB" \
    -e DJANGO_BPP_DB_PORT=5432 \
    -e DJANGO_BPP_REDIS_HOST="$SHADOW_REDIS" \
    --memory "$SHADOW_MIGRATE_MEM" \
    --entrypoint python \
    "${APPSERVER_REPO}:${CANDIDATE}" src/manage.py migrate --noinput
MIGRATE_RC=$?
set -e

if [ "$MIGRATE_RC" -eq 0 ]; then
    trap - ERR
    echo ""
    echo "=== OK: migracje ${CANDIDATE} przechodza na kopii produkcyjnej bazy ==="
    echo "Sprzatam shadow stack..."
    cleanup_shadow
    echo "Gotowe. Produkcja przez caly czas byla nietknieta."
    exit 0
else
    echo "" >&2
    echo "=== BLAD: migracja ${CANDIDATE} NIE przeszla (exit=$MIGRATE_RC) ===" >&2
    echo "Shadow stack ZOSTAJE do inspekcji:" >&2
    echo "  docker exec -it $SHADOW_DB psql -U $DB_USER -d $DB_NAME" >&2
    echo "Ponowna proba migracji (po obejrzeniu):" >&2
    echo "  TAG=$CANDIDATE make test-upgrade" >&2
    echo "Sprzatniecie: make test-upgrade-clean" >&2
    exit 1
fi
```

(chmod +x)

- [ ] **Step 4: Uruchom testy — mają przejść**

Run: `bash scripts/test-docker-versions.sh`
Expected: `PASS=27 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/test-upgrade.sh scripts/test-docker-versions.sh
git commit -m "feat(test-upgrade): proba generalna migracji kandydata na shadow stacku"
```

---

### Task 5: Targety make + help dla `test-upgrade`

**Files:**
- Modify: `mk/deployment.mk` (linia 1: `.PHONY`, koniec pliku: targety)
- Modify: `Makefile` (sekcja help "Deployment", po linii `wait`, ok. linii 94)

- [ ] **Step 1: Dodaj targety w `mk/deployment.mk`**

W linii 1 dopisz do `.PHONY`: `test-upgrade test-upgrade-clean`. Na końcu pliku (przed linią `run: ...` lub po niej — bez znaczenia, byle nie wewnątrz innego targetu):

```makefile
# Proba generalna aktualizacji: backup -> shadow stack (dbserver+redis poza
# projektem Compose) -> restore -> migrate obrazem-kandydatem. Produkcja
# (kontenery, wolumeny, lokalny tag :latest, .env) pozostaje nietknieta.
# Uwaga: NIE mylic z test-upgrade-postgres (unit-testy upgrade'u PG).
test-upgrade: validate-env-quotes
	@TAG="$(TAG)" bash scripts/test-upgrade.sh

test-upgrade-clean:
	@bash scripts/test-upgrade.sh --clean
```

- [ ] **Step 2: Dodaj wpisy do `make help` w `Makefile`**

Po linii `@echo "    wait                 - Wait for Docker build, then pull and restart"` dopisz:

```makefile
	@echo "    test-upgrade         - Proba generalna: migracje kandydata na kopii bazy (TAG=...)"
	@echo "    test-upgrade-clean   - Sprzatniecie shadow stacka po nieudanym test-upgrade"
```

- [ ] **Step 3: Zweryfikuj**

Run: `make help | grep test-upgrade`
Expected: obie nowe linie (oraz istniejące targety bez zmian).

Run: `make -n test-upgrade-clean`
Expected: `bash scripts/test-upgrade.sh --clean`.

Run: `make test-upgrade-clean`
Expected: "Sprzatam shadow stack..." + "OK." (idempotentne — niczego nie ma do sprzątnięcia; wymaga działającego dockera).

- [ ] **Step 4: Commit**

```bash
git add mk/deployment.mk Makefile
git commit -m "feat(make): targety test-upgrade + test-upgrade-clean"
```

---

### Task 6: Dokumentacja (docs-sync)

**Files:**
- Modify: `docs/eksploatacja/komendy.md` (nowa sekcja na końcu pliku)
- Modify: `CLAUDE.md` (nowa podsekcja po "### PostgreSQL version vars")

- [ ] **Step 1: Sekcja w `docs/eksploatacja/komendy.md`**

Na końcu pliku dopisz:

```markdown
## Aktualizacje i wersje obrazów

### `make zaspawaj-wersje` — pinowanie wersji obrazów iplweb

Domyślnie obrazy `iplweb/bpp_*` jadą na ruchomym tagu `latest` — każdy
`make pull` może podmienić wersję. `zaspawaj-wersje` utrwala w
`$BPP_CONFIGS_DIR/.env` zmienną `DOCKER_VERSION=<tag CalVer>` odpowiadającą
wersji, na której **faktycznie chodzi** kontener `appserver` (nie tej, na
którą wskazuje lokalny tag `latest` — po `make pull` bez recreate te dwie
mogą się różnić).

```bash
make zaspawaj-wersje                  # wersja z działającego appservera
make zaspawaj-wersje TAG=202606.1386  # jawny tag
```

Po zaspawaniu `restart`, awaryjny recreate i nocne restarty Ofelii trzymają
się przypiętej wersji. Aktualizacja na nowszą wersję wymaga jawnej decyzji:

```bash
make zaspawaj-wersje TAG=<nowy> && make pull && make up
```

Zmienna obejmuje 5 obrazów iplweb (`bpp_appserver`, `bpp_authserver`,
`bpp_workerserver`, `bpp_denorm_queue`, `bpp_beatserver`). Pozostałe obrazy
(nginx, redis, grafana, …) są przypięte na sztywno w plikach compose;
PostgreSQL ma własną `DJANGO_BPP_POSTGRESQL_VERSION`.

### `make test-upgrade` — próba generalna migracji

Sprawdza, czy migracje bazodanowe obrazu-kandydata przechodzą na **kopii
produkcyjnej bazy**, zanim czegokolwiek dotkniesz na produkcji:

1. pobiera obraz-kandydat **po tagu wersji** (lokalny `latest` nietknięty),
2. robi świeży `make db-backup` (błąd backupu przerywa całość),
3. stawia shadow stack (`bpp-shadow-dbserver` + `bpp-shadow-redis`) na
   osobnej sieci, poza projektem Compose, z przyciętymi limitami zasobów,
4. restoruje dump do shadow-bazy,
5. uruchamia `manage.py migrate` obrazem-kandydatem (entrypoint nadpisany —
   nic poza migracją się nie uruchamia).

```bash
make test-upgrade                  # kandydat = najnowszy tag CalVer z Docker Huba
make test-upgrade TAG=202606.1386  # jawny kandydat
```

**Sukces** → shadow stack jest sprzątany, exit 0. **Porażka** → shadow stack
zostaje do inspekcji (`docker exec -it bpp-shadow-dbserver psql ...`);
sprzątasz przez `make test-upgrade-clean`.

Wymagania: wolne miejsce na dysku ≈ 2,5× rozmiar bazy (kontrolowane przed
startem; wymuszenie pominięcia kontroli: `SKIP_DISK_CHECK=1`). Próba
obciąża CPU/IO hosta na czas dump+restore — na małych hostach uruchamiaj
poza godzinami szczytu.

Typowy przepływ bezpiecznej aktualizacji na zaspawanym hoście:

```bash
make test-upgrade                          # migracje kandydata przechodzą?
make zaspawaj-wersje TAG=<kandydat>        # przypnij nową wersję
make pull && make up                       # właściwy deploy (health-gate --wait)
```
```

- [ ] **Step 2: Podsekcja w `CLAUDE.md`**

Po podsekcji `### PostgreSQL version vars` (przed `## Critical Deployment Patterns`) dopisz:

```markdown
### Image version pinning (`DOCKER_VERSION`) and upgrade rehearsal

`DOCKER_VERSION` pins the 5 `iplweb/bpp_*` images (default `latest` — compose
fallback `${DOCKER_VERSION:-latest}` must stay for backwards compat).
`make zaspawaj-wersje` welds the version **actually running in the appserver
container** (not the local `latest` tag) into `.env` via the stable
`set_env_var` helper; updating a pinned host requires an explicit
`make zaspawaj-wersje TAG=<new>`. `make test-upgrade` is the migration
rehearsal: fresh `db-backup` → shadow stack (`bpp-shadow-*`, plain
`docker run` outside the Compose project) → `pg_restore` → candidate-image
`manage.py migrate` with overridden entrypoint. It must never touch
production containers, volumes, the local `latest` tag, or `.env`. Candidate
images are pulled **by version tag**, never via `:latest`. Shared
digest↔CalVer logic lives in `scripts/lib-docker-versions.sh`
(tests: `make test-docker-versions`). Detail: `docs/eksploatacja/komendy.md`.
```

- [ ] **Step 3: Zbuduj dokumentację**

Run: `mkdocs build --strict`
Expected: build bez warningów/błędów (komenda dostępna w repo; jeśli brak — `pip install mkdocs-material` zgodnie z docs/rozwoj).

- [ ] **Step 4: Commit**

```bash
git add docs/eksploatacja/komendy.md CLAUDE.md
git commit -m "docs: zaspawaj-wersje + test-upgrade (komendy.md, CLAUDE.md)"
```

---

### Task 7: Weryfikacja końcowa

- [ ] **Step 1: Komplet testów jednostkowych repo**

Run: `make test-docker-versions && make test-validate-env-quotes && make test-letsencrypt`
Expected: wszystkie PASS, exit 0.

- [ ] **Step 2: Smoke targetów (dry-run)**

Run: `make -n test-upgrade && make -n test-upgrade-clean && make -n zaspawaj-wersje`
Expected: poprawne komendy, bez błędów make (np. brakujących zależności targetów).

- [ ] **Step 3: Manualny test na hoście stagingowym (poza CI — checklist dla operatora)**

Na hoście z działającym stackiem:

1. `make zaspawaj-wersje` → `DOCKER_VERSION` w `.env` odpowiada wersji działającego appservera; `docker compose config | grep image:` pokazuje przypięte tagi.
2. `make test-upgrade` → pełny przebieg, sukces, shadow posprzątany (`docker ps -a | grep bpp-shadow` puste).
3. Symulowana porażka: `make test-upgrade TAG=<starszy tag z migracjami niekompatybilnymi>` lub przerwanie restore — shadow zostaje, komunikat o inspekcji, `make test-upgrade-clean` sprząta.
4. Uwaga na wynik `pg_restore`: jeśli na realnej bazie zwróci niezerowy kod przez nieszkodliwe błędy (np. `COMMENT ON EXTENSION`), zanotować i rozważyć dopuszczalną listę — NIE maskować ślepo (`|| true` zakazane).

- [ ] **Step 4: Commit końcowy (jeśli były poprawki)**

```bash
git add -A scripts/ mk/ Makefile docs/ CLAUDE.md
git commit -m "fix(test-upgrade): poprawki po weryfikacji"
```

---

## Self-Review (wykonany)

- **Spec coverage:** lib (Task 1), zaspawaj-wersje + tryby błędu (Task 2–3), test-upgrade + clean + gwarancje nienaruszalności + kontrola dysku (Task 4–5), docs + CLAUDE.md + mkdocs strict (Task 6), testy w konwencji repo + manualny staging (Task 1–4, 7). Kompatybilność wsteczna: żadnych nowych wymaganych zmiennych; `${DOCKER_VERSION:-latest}` nietknięte.
- **Placeholder scan:** brak TBD/TODO; każdy krok ma pełny kod lub dokładną komendę.
- **Type consistency:** nazwy funkcji lib (`resolve_latest_calver`, `resolve_digest_to_calver`, `verify_tag_exists`, `running_repo_digest`) i zmiennych shadow (`bpp-shadow-*`) spójne między taskami; liczby PASS narastają 9 → 22 → 27.
