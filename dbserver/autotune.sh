#!/bin/sh
# Shell port of autotune.py — generates a pgtune-style postgresql.conf include
# on stdout (cgroup/meminfo aware), with NO Python dependency.
#
# This lets the autotune step run on the *stock* `postgres` image via a
# bind-mounted entrypoint (no custom image / no python3 install needed).
#
# It is a faithful port of autotune.py: output is verified byte-identical
# (see `./autotune.sh --test` and the parity check in CI). Floating-point math
# is delegated to awk, which uses the same IEEE-754 doubles as Python, so
# truncation (int()) and unit normalization match exactly.
#
# Quirks deliberately preserved from autotune.py:
#   * POSTGRESQL_RAM_THIS_MUCH_GB is actually treated as MB (as in the original)
#   * the "tweak it orremove it" typo and POSTGRESQL_RAM_THIS_MUCH_DB typo in
#     the forced-RAM comment
#   * int(POSTGRESQL_RAM_PERCENT * 100) for the "%" shown in comments (0.95 -> 94)
set -eu

ONE_GB_IN_KB=1048576 # 1024 * 1024

# --- environment (same names / defaults as autotune.py) -----------------------
RAM_PERCENT="${POSTGRESQL_RAM_PERCENT:-0.95}"
FORCE_RAM="${POSTGRESQL_RAM_THIS_MUCH_GB:-}"
DEFAULT_RAM="${POSTGRESQL_DEFAULT_RAM:-4096}"
UNSAFE_RAW="${POSTGRESQL_UNSAFE_BUT_FAST:-}"
MAX_LOCKS="${POSTGRESQL_MAX_LOCKS_PER_TRANSACTION:-}"
MAX_PRED_LOCKS="${POSTGRESQL_MAX_PRED_LOCKS_PER_TRANSACTION:-}"

# unsafe flag: POSTGRESQL_UNSAFE_BUT_FAST.lower() in (1, true, yes)
UNSAFE=0
case "$(printf '%s' "$UNSAFE_RAW" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes) UNSAFE=1 ;;
esac

# --- RAM / CPU detection ------------------------------------------------------

# /proc/meminfo always shows host RAM, not the container limit — the limit lives
# in the cgroup. Echoes the limit in kB, or nothing when there is no finite limit.
cgroup_limit_kb() {
  if [ -f /sys/fs/cgroup/memory.max ]; then
    cg_raw=$(tr -d '[:space:]' < /sys/fs/cgroup/memory.max 2>/dev/null || true)
    if [ -n "$cg_raw" ] && [ "$cg_raw" != "max" ]; then
      awk -v r="$cg_raw" 'BEGIN { printf "%d", int(r / 1024) }'
      return 0
    fi
  fi
  if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    cg_v=$(tr -d '[:space:]' < /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    # cgroup v1 returns a huge sentinel value when no limit is set (>= 1<<62)
    if [ -n "$cg_v" ]; then
      awk -v v="$cg_v" 'BEGIN { if (v + 0 < 4611686018427387904) printf "%d", int(v / 1024) }'
    fi
  fi
}

host_ram_kb() {
  [ -f /proc/meminfo ] || return 0
  awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo
}

detect_nproc() {
  # Match Python's multiprocessing.cpu_count() == os.cpu_count() == online CPUs.
  np=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "")
  case "$np" in '' | *[!0-9]*) np=$(nproc 2>/dev/null || echo "") ;; esac
  case "$np" in '' | *[!0-9]*) np=1 ;; esac
  printf '%s' "$np"
}

# Sets globals RAM_KB (full-precision double as %.17g) and RAM_COMMENT.
resolve_ram_kb() {
  if [ -n "$FORCE_RAM" ]; then
    RAM_COMMENT="# autotune.py: RAM size for Postgres is ${FORCE_RAM} MB, because of env var POSTGRESQL_RAM_THIS_MUCH_DB setting. Change the env var to tweak it orremove it to use automatic RAM size detection."
    RAM_KB=$(awk -v f="$FORCE_RAM" 'BEGIN { printf "%.17g", int(f) * 1024 }')
    return 0
  fi

  host_kb=$(host_ram_kb)
  cg_kb=$(cgroup_limit_kb)
  pct100=$(awk -v p="$RAM_PERCENT" 'BEGIN { printf "%d", int(p * 100) }')

  if [ -n "$cg_kb" ] && { [ -z "$host_kb" ] || [ "$cg_kb" -lt "$host_kb" ]; }; then
    RAM_COMMENT="# autotune.py: detected cgroup memory limit ${cg_kb} kB (host RAM: ${host_kb:-None} kB); will use ${pct100} % of the cgroup limit"
    RAM_KB=$(awk -v p="$RAM_PERCENT" -v c="$cg_kb" 'BEGIN { printf "%.17g", (p * c / 1024) * 1024 }')
    return 0
  fi

  if [ -n "$host_kb" ]; then
    RAM_COMMENT="# autotune.py: detected ${host_kb} kB RAM; will use ${pct100} % of it"
    RAM_KB=$(awk -v p="$RAM_PERCENT" -v h="$host_kb" 'BEGIN { printf "%.17g", (p * h / 1024) * 1024 }')
    return 0
  fi

  RAM_COMMENT="# autotune.py: unable to detect RAM size, returning default ${DEFAULT_RAM} MB; change environment variable POSTGRESQL_DEFAULT_RAM if you need to change this"
  RAM_KB=$(awk -v d="$DEFAULT_RAM" 'BEGIN { printf "%.17g", d * 1024 }')
}

# --- config generation --------------------------------------------------------

# Emits unsorted "key = value" config lines for a given RAM size in kB ($1).
# Reads globals: NPROC, MAX_PARALLEL, CFG_UNSAFE, MAX_LOCKS, MAX_PRED_LOCKS.
generate_config_lines() {
  awk -v ramkb="$1" -v nproc="$NPROC" -v max_parallel="$MAX_PARALLEL" \
    -v unsafe="$CFG_UNSAFE" -v maxlocks="$MAX_LOCKS" -v maxpredlocks="$MAX_PRED_LOCKS" '
    function normsize(x,   iv) {
      iv = int(x)
      if (iv % GB == 0) return sprintf("%dGB", iv / GB)
      if (iv % MB == 0) return sprintf("%dMB", iv / MB)
      return sprintf("%dkB", iv)
    }
    BEGIN {
      GB = 1048576; MB = 1024

      # Directly from pgtune
      printf "shared_buffers = %s\n", normsize(ramkb / 4)
      printf "effective_cache_size = %s\n", normsize(ramkb * 3 / 4)
      mwm = ramkb / 16; if (mwm > 2 * GB) mwm = 2 * GB
      printf "maintenance_work_mem = %s\n", normsize(mwm)

      # 100 connections per 1 GB RAM, capped at 250
      conns = 100 * ramkb / GB; if (conns > 250) conns = 250
      printf "max_connections = %d\n", int(conns)
      printf "work_mem = %s\n", normsize((ramkb * 3 / 4) / (conns * 3) / max_parallel)

      printf "min_wal_size = %s\n", normsize(GB)
      printf "max_wal_size = %s\n", normsize(4 * GB)

      wb = ramkb * 3 / 4 / 100; if (wb > 16 * MB) wb = 16 * MB
      printf "wal_buffers = %s\n", normsize(wb)

      print "checkpoint_completion_target = 0.7"
      print "default_statistics_target = 100"

      printf "max_worker_processes = %d\n", nproc
      printf "max_parallel_workers_per_gather = %d\n", max_parallel
      printf "max_parallel_workers = %d\n", nproc
      printf "max_parallel_maintenance_workers = %d\n", max_parallel

      if (maxlocks != "") printf "max_locks_per_transaction = %d\n", maxlocks + 0
      if (maxpredlocks != "") printf "max_pred_locks_per_transaction = %d\n", maxpredlocks + 0

      if (unsafe) {
        print "fsync = off"
        print "full_page_writes = off"
        print "synchronous_commit = off"
        print "wal_level = minimal"
        print "max_wal_senders = 0"
        print "archive_mode = off"
        print "wal_writer_delay = 10000ms"
        print "commit_delay = 100000"
        print "random_page_cost = 1.1"
        print "effective_io_concurrency = 200"
      }
    }
  '
}

# max_parallel mirrors autotune.py: 1 (<4 cpus), 2 (>=4), 3 (5-6), 4 (>=7)
compute_max_parallel() {
  MAX_PARALLEL=1
  if [ "$NPROC" -ge 4 ]; then
    MAX_PARALLEL=2
    if [ "$NPROC" -ge 5 ] && [ "$NPROC" -le 6 ]; then MAX_PARALLEL=3; fi
    if [ "$NPROC" -ge 7 ]; then MAX_PARALLEL=4; fi
  fi
}

main() {
  resolve_ram_kb
  NPROC=$(detect_nproc)
  compute_max_parallel
  CFG_UNSAFE="$UNSAFE"

  printf '%s\n' "$RAM_COMMENT"
  printf '# Automatically added by autotune.py\n'
  if [ "$UNSAFE" -eq 1 ]; then
    cat <<'EOF'
#
# *** UWAGA! TRYB POSTGRESQL_UNSAFE_BUT_FAST JEST WŁĄCZONY! ***
# *** fsync, full_page_writes, synchronous_commit WYŁĄCZONE ***
# *** wal_level=minimal, max_wal_senders=0, archive_mode=off ***
# *** DANE MOGĄ ZOSTAĆ UTRACONE! NIE UŻYWAJ W PRODUKCJI! ***
#
EOF
  fi
  generate_config_lines "$RAM_KB" | LC_ALL=C sort
}

# --- self-test (mirrors autotune.py test()) -----------------------------------

TEST_FAIL=0

assert_value() {
  # $1=size kB  $2=key  $3=expected ; reads $TEST_CFG
  av_got=$(printf '%s\n' "$TEST_CFG" | sed -n "s/^$2 = //p")
  if [ "$av_got" != "$3" ]; then
    printf 'FAIL: Postgres at %s kB: %s differs:\n  Got: %s\n  Expected: %s\n' \
      "$1" "$2" "$av_got" "$3" >&2
    TEST_FAIL=1
  fi
}

assert_present() {
  # $1=size kB  $2=key ; reads $TEST_CFG
  if ! printf '%s\n' "$TEST_CFG" | grep -q "^$2 = "; then
    printf 'FAIL: Postgres at %s kB: missing key %s\n' "$1" "$2" >&2
    TEST_FAIL=1
  fi
}

run_tests() {
  NPROC=$(detect_nproc)
  compute_max_parallel
  CFG_UNSAFE=0
  # locks must not leak into the deterministic cases
  saved_locks="$MAX_LOCKS"; saved_pred="$MAX_PRED_LOCKS"
  MAX_LOCKS=""; MAX_PRED_LOCKS=""

  # RAM-dependent (deterministic) values. work_mem and CPU-dependent keys depend
  # on cpu count / max_connections, so we only check their presence (as in py).
  for tc in \
    "524288|shared_buffers=128MB effective_cache_size=384MB maintenance_work_mem=32MB min_wal_size=1GB max_wal_size=4GB checkpoint_completion_target=0.7 wal_buffers=3932kB default_statistics_target=100 max_connections=50" \
    "1048576|shared_buffers=256MB effective_cache_size=768MB maintenance_work_mem=64MB min_wal_size=1GB max_wal_size=4GB checkpoint_completion_target=0.7 wal_buffers=7864kB default_statistics_target=100 max_connections=100" \
    "2097152|shared_buffers=512MB effective_cache_size=1536MB maintenance_work_mem=128MB min_wal_size=1GB max_wal_size=4GB checkpoint_completion_target=0.7 wal_buffers=15728kB default_statistics_target=100 max_connections=200" \
    "4194304|shared_buffers=1GB effective_cache_size=3GB maintenance_work_mem=256MB min_wal_size=1GB max_wal_size=4GB checkpoint_completion_target=0.7 wal_buffers=16MB default_statistics_target=100 max_connections=250"; do
    size=${tc%%|*}
    pairs=${tc#*|}
    TEST_CFG=$(generate_config_lines "$size")
    for p in $pairs; do
      assert_value "$size" "${p%%=*}" "${p#*=}"
    done
    for k in max_worker_processes max_parallel_workers_per_gather \
      max_parallel_workers max_parallel_maintenance_workers work_mem; do
      assert_present "$size" "$k"
    done
  done

  MAX_LOCKS="$saved_locks"; MAX_PRED_LOCKS="$saved_pred"

  # unsafe-mode test (only when the env flag is on, as in autotune.py)
  if [ "$UNSAFE" -eq 1 ]; then
    CFG_UNSAFE=1
    TEST_CFG=$(generate_config_lines "$ONE_GB_IN_KB")
    for k in fsync full_page_writes synchronous_commit archive_mode; do
      assert_value "$ONE_GB_IN_KB" "$k" "off"
    done
    assert_value "$ONE_GB_IN_KB" wal_level minimal
    assert_value "$ONE_GB_IN_KB" max_wal_senders 0
    assert_value "$ONE_GB_IN_KB" random_page_cost 1.1
    assert_value "$ONE_GB_IN_KB" effective_io_concurrency 200
    assert_present "$ONE_GB_IN_KB" wal_writer_delay
    assert_present "$ONE_GB_IN_KB" commit_delay
  fi

  if [ "$TEST_FAIL" -ne 0 ]; then
    exit 1
  fi
  printf 'OK\n' >&2
}

usage() {
  printf 'Usage: %s [--test]\n' "$1" >&2
}

# --- entrypoint ---------------------------------------------------------------
if [ "$#" -eq 0 ]; then
  main
elif [ "$#" -eq 1 ] && [ "$1" = "--test" ]; then
  run_tests
else
  usage "$0"
fi
