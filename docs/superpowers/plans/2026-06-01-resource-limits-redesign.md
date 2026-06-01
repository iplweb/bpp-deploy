# Resource Limits Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat-weighted `configure-resources` model with a FIXED-cap + VARIABLE-floor/weight model, cap every reasonable container, set a documented 12 GB minimum, and sync compose defaults + docs + README.

**Architecture:** `scripts/configure-resources.sh` computes `Σ(fixed caps)` upfront (constants), derives `pool = budget − Σfixed`, distributes `pool` across 4 variable services by floor+weight, and writes all `*_MEM_LIMIT` to `.env`. CPU logic stays as today for the same 7 services. Compose `${VAR:-default}` fallbacks are bumped to the new caps; flower gets `--max-tasks 10000`.

**Tech Stack:** Bash (awk for float math), Docker Compose YAML, MkDocs Material.

---

### Task 1: Rewrite the service model in `configure-resources.sh`

**Files:**
- Modify: `scripts/configure-resources.sh`
- Test: `tests/test_makefile.sh`

- [ ] **Step 1: Add the failing test** in `tests/test_makefile.sh` (before the runner block near line 974). It runs the script non-interactively with a temp config dir and asserts the host-independent fixed caps:

```bash
test_configure_resources_fixed_caps() {
    echo "TEST: configure-resources zapisuje stale capy + zmienne uslugi"
    setup_temp
    init_min_env   # helper: writes a minimal .env with BPP_CONFIGS_DIR-independent content
    # 4 variable mem + 7 cpu prompts -> feed plenty of blank lines (Enter = default)
    if ! printf '\n%.0s' {1..20} | BPP_CONFIGS_DIR="$CONFIG_DIR" bash "$REPO_ROOT/scripts/configure-resources.sh" >/dev/null 2>&1; then
        fail "configure-resources zwrocil blad"
        cleanup_temp; return
    fi
    assert_file_contains "redis cap"   "REDIS_MEM_LIMIT=1024m"  "$CONFIG_DIR/.env"
    assert_file_contains "alloy cap"   "ALLOY_MEM_LIMIT=192m"   "$CONFIG_DIR/.env"
    assert_file_contains "loki cap"    "LOKI_MEM_LIMIT=192m"    "$CONFIG_DIR/.env"
    assert_file_contains "flower cap"  "FLOWER_MEM_LIMIT=128m"  "$CONFIG_DIR/.env"
    assert_file_contains "netdata cap" "NETDATA_MEM_LIMIT=320m" "$CONFIG_DIR/.env"
    assert_file_contains "grafana cap" "GRAFANA_MEM_LIMIT=192m" "$CONFIG_DIR/.env"
    assert_file_contains "appserver present" "APPSERVER_MEM_LIMIT=" "$CONFIG_DIR/.env"
    assert_file_contains "dbserver present"  "DBSERVER_MEM_LIMIT="  "$CONFIG_DIR/.env"
    assert_file_contains "redis maxmemory"   "REDIS_MAXMEMORY="     "$CONFIG_DIR/.env"
    cleanup_temp
}
```

Add `init_min_env` helper (near `setup_temp`) and register `test_configure_resources_fixed_caps` in the runner list. `REPO_ROOT` is already defined in the harness (verify; if not, derive from `$(dirname "$0")/..`).

- [ ] **Step 2: Run the test, verify it fails** — `bash tests/test_makefile.sh 2>&1 | grep configure-resources` → FAIL (old script writes flower 768m, alloy 384m, etc., and never writes grafana/redis as 1024m).

- [ ] **Step 3: Make `BPP_CONFIGS_DIR` env take precedence.** Replace the source block (`configure-resources.sh:64-68`):

```bash
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${BPP_CONFIGS_DIR:-}" ] && [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/.env"
fi
```

- [ ] **Step 4: Replace the `SERVICES` array (lines ~97-110)** with three tables:

```bash
# --- Uslugi ze stalym capem (MB). Odejmowane od budzetu w pierwszej kolejnosci. ---
FIXED_MEM=(
    "redis:1024"
    "netdata:320"
    "authserver:320"
    "celerybeat:320"
    "denorm-queue:320"
    "alloy:192"
    "loki:192"
    "grafana:192"
    "flower:128"
    "webserver:256"
    "dozzle:64"
    "ofelia:64"
    "autoheal:32"
)

# --- Uslugi zmienne: floor_mb:surplus_weight. Dziela pule po odjeciu fixed. ---
VARIABLE_MEM=(
    "dbserver:1536:40"
    "appserver:2048:25"
    "workerserver-general:1536:20"
    "workerserver-denorm:1536:15"
)

# --- CPU bez zmian: te same 7 uslug + wagi co dotychczas. ---
CPU_SERVICES=(
    "dbserver:25"
    "appserver:25"
    "workerserver-general:25"
    "workerserver-denorm:12.5"
    "redis:7.5"
    "loki:2.5"
    "netdata:5"
)
```

- [ ] **Step 5: Bump the small-host warning** at `configure-resources.sh:56` from `-lt 6` to `-lt 12`, and update the message text to reference 12 GB minimum:

```bash
if [ "$TOTAL_RAM_GB" -lt 12 ]; then
    echo "UWAGA: host ma mniej niz 12 GB RAM - minimalne wymaganie BPP."
    echo "       Limity floor (dbserver/appserver/workery) moga sie nie zmiescic;"
    echo "       skrypt przypisze floory i ostrzeze o ryzyku OOM. Zalecane 16 GB+."
    echo ""
fi
```

- [ ] **Step 6: Replace the main loop (lines ~207-306)** with: (a) sum fixed caps, (b) compute pool + surplus, (c) interactive MEM for the 4 variable services with redistribution, (d) the existing CPU loop over `CPU_SERVICES`. Full replacement:

```bash
echo "Budzet po rezerwie ${RESERVE_GB} GB dla OS: $(fmt_mb "$MEM_BUDGET_MB") RAM, ${CPU_BUDGET} CPU."
echo ""

MIN_MEM_MB=64
MIN_CPU="0.1"

# (a) Suma fixed capow (stale).
fixed_total_mb=0
for entry in "${FIXED_MEM[@]}"; do
    IFS=: read -r _svc cap <<< "$entry"
    fixed_total_mb=$(( fixed_total_mb + cap ))
done

# (b) Pula dla uslug zmiennych + suma floorow.
pool_mb=$(( MEM_BUDGET_MB - fixed_total_mb ))
[ "$pool_mb" -lt 0 ] && pool_mb=0
floors_total_mb=0
for entry in "${VARIABLE_MEM[@]}"; do
    IFS=: read -r _svc floor _w <<< "$entry"
    floors_total_mb=$(( floors_total_mb + floor ))
done
surplus_mb=$(( pool_mb - floors_total_mb ))

echo "Uslugi ze stalym limitem (lacznie $(fmt_mb "$fixed_total_mb")) sa przypisane automatycznie."
echo "Pozostala pula $(fmt_mb "$pool_mb") jest dzielona miedzy dbserver/appserver/workery."
if [ "$surplus_mb" -lt 0 ]; then
    echo ""
    echo "UWAGA: pula ($(fmt_mb "$pool_mb")) jest mniejsza niz suma minimow"
    echo "       ($(fmt_mb "$floors_total_mb")). Przypisuje minima; suma limitow przekroczy"
    echo "       budzet - ryzyko OOM. To host ponizej minimum 12 GB. Zalecane 16 GB+."
fi
echo ""
echo "Enter akceptuje wartosc domyslna. RAM bez sufiksu = MB (np. 500, 1g = 1024 MB)."
echo "CPU: ulamek rdzeni (np. 2.0)."
echo ""

declare -a RESULT_NAMES RESULT_MEM_MB
declare -A MEM_BY_NAME

# (c) Interaktywny MEM dla uslug zmiennych z redystrybucja nadwyzki.
remaining_surplus_mb=$surplus_mb
[ "$remaining_surplus_mb" -lt 0 ] && remaining_surplus_mb=0
remaining_weight=100
for entry in "${VARIABLE_MEM[@]}"; do
    IFS=: read -r svc floor weight <<< "$entry"
    if [ "$remaining_weight" -le 0 ]; then
        default_mem_mb=$floor
    else
        default_mem_mb=$(LC_ALL=C awk -v f="$floor" -v s="$remaining_surplus_mb" -v w="$weight" -v t="$remaining_weight" \
            'BEGIN { printf "%d", f + s * w / t + 0.5 }')
    fi
    [ "$default_mem_mb" -lt "$MIN_MEM_MB" ] && default_mem_mb=$MIN_MEM_MB

    while true; do
        mem_answer=$(ask_mem "$svc RAM" "$default_mem_mb" "$(fmt_mb "$default_mem_mb")")
        if [[ "$mem_answer" =~ ^[0-9]+$ ]]; then
            mem_mb="$mem_answer"
        elif ! mem_mb=$(parse_mem_mb "$mem_answer"); then
            echo "    Blad: nie rozumiem '$mem_answer'. Podaj liczbe MB, np 500, 1g." >&2; continue
        fi
        [ "$mem_mb" -lt "$MIN_MEM_MB" ] && { echo "    Blad: minimum to ${MIN_MEM_MB} MB." >&2; continue; }
        break
    done

    RESULT_NAMES+=("$svc"); RESULT_MEM_MB+=("$mem_mb"); MEM_BY_NAME["$svc"]=$mem_mb

    # Redystrybucja: odejmij to co poszlo ponad floor od puli nadwyzki.
    used_surplus=$(( mem_mb - floor ))
    remaining_surplus_mb=$(( remaining_surplus_mb - used_surplus ))
    [ "$remaining_surplus_mb" -lt 0 ] && remaining_surplus_mb=0
    remaining_weight=$(LC_ALL=C awk -v t="$remaining_weight" -v w="$weight" 'BEGIN { printf "%d", t - w + 0.5 }')
done

# Fixed: przypisz capy (bez pytania).
for entry in "${FIXED_MEM[@]}"; do
    IFS=: read -r svc cap <<< "$entry"
    RESULT_NAMES+=("$svc"); RESULT_MEM_MB+=("$cap"); MEM_BY_NAME["$svc"]=$cap
done

# (d) CPU - logika bez zmian, te same 7 uslug.
declare -A CPU_BY_NAME
remaining_cpu=$CPU_BUDGET
remaining_cpu_weight=102.5
for entry in "${CPU_SERVICES[@]}"; do
    IFS=: read -r svc cpu_w <<< "$entry"
    default_cpu=$(LC_ALL=C awk -v r="$remaining_cpu" -v w="$cpu_w" -v t="$remaining_cpu_weight" -v min="$MIN_CPU" \
        'BEGIN { if (t <= 0) v = min; else v = r * w / t; if (v < min) v = min; printf "%.1f", v }')
    while true; do
        cpu_answer=$(ask "$svc CPU" "$default_cpu")
        [[ "$cpu_answer" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "    Blad: podaj liczbe, np 2.0." >&2; continue; }
        cpu_answer=$(round1 "$cpu_answer")
        if LC_ALL=C awk -v v="$cpu_answer" -v m="$MIN_CPU" 'BEGIN { exit (v < m) ? 0 : 1 }'; then
            echo "    Blad: minimum to ${MIN_CPU} CPU." >&2; continue
        fi
        break
    done
    CPU_BY_NAME["$svc"]=$cpu_answer
    remaining_cpu=$(fcalc "$remaining_cpu" "-" "$cpu_answer")
    remaining_cpu=$(LC_ALL=C awk -v v="$remaining_cpu" 'BEGIN { if (v < 0) v = 0; printf "%.2f", v }')
    remaining_cpu_weight=$(fcalc "$remaining_cpu_weight" "-" "$cpu_w")
done

total_used_mem_mb=0
for v in "${RESULT_MEM_MB[@]}"; do total_used_mem_mb=$(( total_used_mem_mb + v )); done
```

- [ ] **Step 7: Update the write-out section (lines ~320-352).** Extend `var_prefix_for` with all services and write MEM for every `RESULT_NAMES`, CPU only for `CPU_BY_NAME`:

```bash
var_prefix_for() {
    case "$1" in
        dbserver) echo "DBSERVER" ;;
        appserver) echo "APPSERVER" ;;
        workerserver-general) echo "WORKER_GENERAL" ;;
        workerserver-denorm) echo "WORKER_DENORM" ;;
        redis) echo "REDIS" ;;
        loki) echo "LOKI" ;;
        netdata) echo "NETDATA" ;;
        authserver) echo "AUTHSERVER" ;;
        celerybeat) echo "CELERYBEAT" ;;
        denorm-queue) echo "DENORM_QUEUE" ;;
        alloy) echo "ALLOY" ;;
        grafana) echo "GRAFANA" ;;
        flower) echo "FLOWER" ;;
        webserver) echo "WEBSERVER" ;;
        dozzle) echo "DOZZLE" ;;
        ofelia) echo "OFELIA" ;;
        autoheal) echo "AUTOHEAL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

for i in "${!RESULT_NAMES[@]}"; do
    svc="${RESULT_NAMES[$i]}"; prefix=$(var_prefix_for "$svc")
    set_env_var "${prefix}_MEM_LIMIT" "${RESULT_MEM_MB[$i]}m"
    if [ -n "${CPU_BY_NAME[$svc]:-}" ]; then
        set_env_var "${prefix}_CPU_LIMIT" "${CPU_BY_NAME[$svc]}"
    fi
done

redis_mem_mb="${MEM_BY_NAME[redis]:-}"
if [ -n "$redis_mem_mb" ]; then
    set_env_var "REDIS_MAXMEMORY" "$(( redis_mem_mb * 80 / 100 ))mb"
fi
```

Update the summary loop + over-budget warning to use `total_used_mem_mb` (already computed). The existing summary/warning block (lines ~354-382) works as-is.

- [ ] **Step 8: Run the test, verify it passes** — `bash tests/test_makefile.sh 2>&1 | grep -A12 configure-resources` → all PASS. Also run `bash -n scripts/configure-resources.sh` (syntax) and shellcheck if available.

- [ ] **Step 9: Commit**

```bash
git add scripts/configure-resources.sh tests/test_makefile.sh
git commit -m "feat(configure-resources): fixed-cap + variable-floor RAM model"
```

---

### Task 2: Sync compose defaults to the new caps

**Files:**
- Modify: `docker-compose.infrastructure.yml` (redis), `docker-compose.monitoring.yml` (netdata, alloy, loki), `docker-compose.workers.yml` (flower, worker-general, worker-denorm), `docker-compose.application.yml` (appserver)

- [ ] **Step 1: Bump each `${VAR:-default}`** with exact edits:
  - `REDIS_MEM_LIMIT:-256m` → `:-1g`
  - `NETDATA_MEM_LIMIT:-256m` → `:-320m`
  - `ALLOY_MEM_LIMIT:-384m` → `:-192m`
  - `LOKI_MEM_LIMIT:-256m` → `:-192m`
  - `FLOWER_MEM_LIMIT:-768m` → `:-128m`
  - `WORKER_GENERAL_MEM_LIMIT:-1g` → `:-1536m`
  - `WORKER_DENORM_MEM_LIMIT:-1g` → `:-1536m`
  - `APPSERVER_MEM_LIMIT:-1g` → `:-2g`

- [ ] **Step 2: Add flower `--max-tasks 10000`.** In `docker-compose.workers.yml` flower `environment:` block add `- FLOWER_MAX_TASKS=10000` after `FLOWER_URL_PREFIX`.

- [ ] **Step 3: Verify** — `grep -E "MEM_LIMIT:-" docker-compose.*.yml` shows the new defaults; `grep FLOWER_MAX_TASKS docker-compose.workers.yml` present. Run `docker compose config -q` if Docker available (else skip).

- [ ] **Step 4: Commit**

```bash
git add docker-compose.*.yml
git commit -m "feat(compose): sync MEM_LIMIT defaults to new caps + flower --max-tasks"
```

---

### Task 3: Docs + README (via docs-sync)

**Files:**
- Modify: `docs/konfiguracja/limity-zasobow.md`, `README.md`

- [ ] **Step 1: Invoke the `docs-sync` skill** to confirm placement, then rewrite `docs/konfiguracja/limity-zasobow.md`: intro states 12 GB min / 16 GB recommended; replace the "Wysokie ryzyko/Demony" tables with FIXED (cap) + VARIABLE (floor/weight) tables matching the spec; keep the "Bez limitu" section and add `certbot`; add a note that netdata's 320m cap must rise with `NETDATA_DBENGINE_*` retention knobs.

- [ ] **Step 2: Add "Wymagania sprzętowe" to `README.md`** before `## Jak zainstalować` (after line 21): a short block stating **minimum 12 GB RAM, zalecane 16 GB+**, ~2 rdzenie CPU min, disk note, pointing to the limity-zasobow docs page.

- [ ] **Step 3: Validate** — `mkdocs build --strict` (must pass: no broken links/nav gaps).

- [ ] **Step 4: Commit**

```bash
git add docs/ README.md
git commit -m "docs: 12 GB minimum + new resource-limits model"
```

---

### Task 4: PR

- [ ] **Step 1:** `git push -u origin feature/resource-limits-12gb-redesign`
- [ ] **Step 2:** `gh pr create` with a body summarizing the model, the 12 GB minimum, the lowered-ceiling backwards-compat note, and the test.
