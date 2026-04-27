#!/usr/bin/env bash
#
# Konfiguracja limitow zasobow (RAM + CPU) dla serwisow BPP w Dockerze.
#
# Skrypt wykrywa rozmiar hosta, proponuje podzial proporcjonalny (30% RAM
# dla dbserver, 15% dla Django i workerow itd.) i pyta uzytkownika po
# kolei. Po kazdej odpowiedzi, jesli uzytkownik odszedl od defaultu,
# POZOSTAL budzet jest proporcjonalnie redystrybuowany miedzy pozostale
# serwisy. Wejscie RAM bez sufiksu traktowane jest jako megabajty (100 =
# 100 MB, "1g" = 1024 MB, "512m" = 512 MB).
#
# Wynik laduje w $BPP_CONFIGS_DIR/.env jako zmienne <SERVICE>_MEM_LIMIT
# (zawsze w postaci <N>m) i <SERVICE>_CPU_LIMIT (float). Compose'y
# interpretuja te zmienne w sekcji deploy.resources.limits.
#
# Uruchamianie: make configure-resources (lub bezposrednio skrypt).
# Nie modyfikuje hosta, nie instaluje nic. Jedyny write: $BPP_CONFIGS_DIR/.env.

set -euo pipefail

# --- Wykrywanie parametrow hosta ---

case "$(uname -s)" in
    Linux)
        TOTAL_RAM_KB=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)
        TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
        CPU_COUNT=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
        ;;
    Darwin)
        TOTAL_RAM_BYTES=$(sysctl -n hw.memsize)
        TOTAL_RAM_GB=$(( TOTAL_RAM_BYTES / 1024 / 1024 / 1024 ))
        CPU_COUNT=$(sysctl -n hw.ncpu)
        ;;
    *)
        echo "Blad: nieobslugiwany system operacyjny: $(uname -s)" >&2
        exit 1
        ;;
esac

echo ""
echo "================================================================"
echo "  Konfiguracja limitow zasobow Docker dla BPP"
echo "================================================================"
echo ""
echo "Pracujesz na serwerze z ${TOTAL_RAM_GB} GB RAM i ${CPU_COUNT} rdzeni CPU."
echo ""
echo "WAZNE - rodzaj limitow:"
echo "  RAM to limit TWARDY  - kontener przekraczajacy limit zostaje ubity"
echo "                         przez OOM killera (SIGKILL, dane w locie moga"
echo "                         zostac stracone). Ustawiaj z zapasem."
echo "  CPU to limit MIEKKI  - kontener jest throttlowany (scheduler ogranicza"
echo "                         cykle powyzej limitu), ale nie jest zabijany."
echo "                         Oversubscription jest bezpieczne."
echo ""

if [ "$TOTAL_RAM_GB" -lt 6 ]; then
    echo "UWAGA: host ma mniej niz 6 GB RAM - limity moga byc zbyt ciasne"
    echo "       zeby pomiescic caly stack z komfortowa rezerwa."
    echo ""
fi

# --- Lokalizacja $BPP_CONFIGS_DIR/.env ---

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/.env"
fi
if [ -z "${BPP_CONFIGS_DIR:-}" ]; then
    echo "Blad: BPP_CONFIGS_DIR nie jest ustawione w $REPO_DIR/.env." >&2
    echo "Uruchom najpierw 'make init-configs'." >&2
    exit 1
fi
ENV_FILE="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Blad: brak $ENV_FILE. Uruchom najpierw 'make init-configs'." >&2
    exit 1
fi

# --- Budzet: rezerwa dla OS + malych daemonow ---

RESERVE_GB=2
if [ "$TOTAL_RAM_GB" -le 4 ]; then
    RESERVE_GB=1
fi
BUDGET_GB=$(( TOTAL_RAM_GB - RESERVE_GB ))
if [ "$BUDGET_GB" -lt 4 ]; then
    BUDGET_GB=4
fi
MEM_BUDGET_MB=$(( BUDGET_GB * 1024 ))

# CPU budzet = liczba rdzeni. Waga = procent tej puli. Limity moga
# oversubscrybowac realne rdzenie bez problemow, ale trzymamy sie w
# granicach CPU_COUNT zeby high-risk services nie zabraly calego hosta.
CPU_BUDGET="$CPU_COUNT"

# --- Lista serwisow z wagami ---
#
# Format: name:mem_pct:cpu_pct
# Wagi mem i cpu sumuja sie oddzielnie (ale obie koncza na 100%).

SERVICES=(
    "dbserver:30:25"
    "appserver:15:25"
    "workerserver-general:15:25"
    "workerserver-denorm:15:12.5"
    "redis:13:7.5"
    "loki:5:2.5"
    "prometheus:7:5"
)

# --- Helpery ---

ask() {
    local label="$1" default="$2" answer=""
    # Prompt idzie na stderr, zeby $(ask ...) lapalo tylko wartosc.
    printf "  %-32s [%s]: " "$label" "$default" >&2
    read -r answer || true
    echo "${answer:-$default}"
}

# Jak ask, ale default wyswietlany jest w formacie human-readable (np.
# "18.6 GB"), a przy Enter zwracana jest wartosc raw ($default_raw).
ask_mem() {
    local label="$1" default_raw="$2" default_display="$3" answer=""
    printf "  %-32s [%s]: " "$label" "$default_display" >&2
    read -r answer || true
    echo "${answer:-$default_raw}"
}

# Formatuje liczbe MB do human-readable: < 1024 MB -> "N MB",
# >= 1024 -> "N.N GB" (jedno miejsce po przecinku).
fmt_mb() {
    local mb="$1"
    if [ "$mb" -lt 1024 ]; then
        echo "${mb} MB"
    else
        LC_ALL=C awk -v m="$mb" 'BEGIN { printf "%.1f GB", m / 1024 }'
    fi
}

# Parsuje wejscie RAM i zwraca MB jako integer.
# Akceptuje: "100" (= 100 MB), "100m", "100M", "100mb", "1g", "1G", "2gb".
parse_mem_mb() {
    local input="$1"
    input=$(echo "$input" | tr -d '[:space:]')
    case "$input" in
        '')
            return 1
            ;;
        *g|*G|*gb|*GB|*Gb|*gB)
            local n="${input%[gG]*}"
            [[ "$n" =~ ^[0-9]+$ ]] || return 1
            echo $(( n * 1024 ))
            ;;
        *m|*M|*mb|*MB|*Mb|*mB)
            local n="${input%[mM]*}"
            [[ "$n" =~ ^[0-9]+$ ]] || return 1
            echo "$n"
            ;;
        *[0-9])
            # Sama liczba - traktuj jako MB zgodnie z konwencja skryptu.
            [[ "$input" =~ ^[0-9]+$ ]] || return 1
            echo "$input"
            ;;
        *)
            return 1
            ;;
    esac
}

# Float add/sub/mul/div przez awk z LC_ALL=C (inaczej pl-PL uzywa
# przecinka i psuje parsing po stronie Dockera).
fcalc() {
    LC_ALL=C awk -v a="$1" -v op="$2" -v b="$3" \
        'BEGIN {
            if (op == "+") print a + b
            else if (op == "-") print a - b
            else if (op == "*") print a * b
            else if (op == "/") { if (b == 0) print "0"; else print a / b }
        }'
}

# Zaokraglenie do jednego miejsca po przecinku, LC_ALL=C.
round1() {
    LC_ALL=C awk -v v="$1" 'BEGIN { printf "%.1f", v }'
}

env_has_var() {
    grep -q "^${1}=" "$ENV_FILE" 2>/dev/null
}

set_env_var() {
    local var_name="$1" value="$2"
    if env_has_var "$var_name"; then
        local tmp="$ENV_FILE.tmp.$$"
        awk -v k="$var_name" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
    else
        echo "${var_name}=${value}" >> "$ENV_FILE"
    fi
}

# --- Glowna petla: pytaj + redystrybuuj ---

echo "Budzet po rezerwie ${RESERVE_GB} GB dla OS: $(fmt_mb "$MEM_BUDGET_MB") RAM, ${CPU_BUDGET} CPU."
echo ""
echo "Enter akceptuje wartosc domyslna. Przy odejsciu od defaultu pozostaly"
echo "budzet jest proporcjonalnie redystrybuowany na pozostale serwisy."
echo "RAM: liczba bez sufiksu = MB (np. 500 = 500 MB, 1g = 1024 MB)."
echo "CPU: ulamek rdzeni (np. 2.0 = dwa pelne rdzenie)."
echo ""

# Minimalne progi - ponizej Docker odrzuca limit.
MIN_MEM_MB=64
MIN_CPU="0.1"

remaining_mem_mb=$MEM_BUDGET_MB
remaining_cpu=$CPU_BUDGET
remaining_mem_weight=100
remaining_cpu_weight=100
total_used_mem_mb=0
total_used_cpu="0"

declare -a RESULT_NAMES
declare -a RESULT_MEM_MB
declare -a RESULT_CPU

for entry in "${SERVICES[@]}"; do
    IFS=: read -r svc mem_w cpu_w <<< "$entry"

    # Oblicz defaulty z pozostalego budzetu proporcjonalnie. Clamp do minimow
    # zeby Docker zaakceptowal limit - jesli budzet sie skonczyl, i tak
    # proponujemy minimum i pozwalamy uzytkownikowi zmienic recznie.
    if [ "$remaining_mem_weight" -le 0 ] 2>/dev/null; then
        default_mem_mb=$MIN_MEM_MB
    else
        default_mem_mb=$(LC_ALL=C awk -v r="$remaining_mem_mb" -v w="$mem_w" -v t="$remaining_mem_weight" -v min="$MIN_MEM_MB" \
            'BEGIN { v = r * w / t; if (v < min) v = min; printf "%d", v + 0.5 }')
    fi

    default_cpu=$(LC_ALL=C awk -v r="$remaining_cpu" -v w="$cpu_w" -v t="$remaining_cpu_weight" -v min="$MIN_CPU" \
        'BEGIN { if (t <= 0) v = min; else v = r * w / t; if (v < min) v = min; printf "%.1f", v }')

    # Pytania.
    mem_answer=""
    mem_mb=0
    default_mem_display=$(fmt_mb "$default_mem_mb")
    while true; do
        mem_answer=$(ask_mem "$svc RAM" "$default_mem_mb" "$default_mem_display")
        # Sama liczba, uzyj jako MB. Inaczej sprobuj parse_mem_mb.
        if [[ "$mem_answer" =~ ^[0-9]+$ ]]; then
            mem_mb="$mem_answer"
        elif ! mem_mb=$(parse_mem_mb "$mem_answer"); then
            echo "    Blad: nie rozumiem '$mem_answer'. Podaj liczbe MB, np 500, 500m, 1g." >&2
            continue
        fi
        if [ "$mem_mb" -lt "$MIN_MEM_MB" ]; then
            echo "    Blad: minimum to ${MIN_MEM_MB} MB (Docker odrzuci mniej)." >&2
            continue
        fi
        break
    done

    cpu_answer=""
    while true; do
        cpu_answer=$(ask "$svc CPU" "$default_cpu")
        # Akceptuj liczbe calkowita lub float (kropka).
        if ! [[ "$cpu_answer" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "    Blad: nie rozumiem '$cpu_answer'. Podaj liczbe, np 2.0 lub 1.5." >&2
            continue
        fi
        cpu_answer=$(round1 "$cpu_answer")
        # Sprawdz minimum przez awk (bash nie robi floatow).
        if LC_ALL=C awk -v v="$cpu_answer" -v m="$MIN_CPU" 'BEGIN { exit (v < m) ? 0 : 1 }'; then
            echo "    Blad: minimum to ${MIN_CPU} CPU (Docker odrzuci mniej)." >&2
            continue
        fi
        break
    done

    RESULT_NAMES+=("$svc")
    RESULT_MEM_MB+=("$mem_mb")
    RESULT_CPU+=("$cpu_answer")

    total_used_mem_mb=$(( total_used_mem_mb + mem_mb ))
    total_used_cpu=$(fcalc "$total_used_cpu" "+" "$cpu_answer")

    # Zaktualizuj pozostaly budzet i wagi.
    remaining_mem_mb=$(( remaining_mem_mb - mem_mb ))
    if [ "$remaining_mem_mb" -lt 0 ]; then
        remaining_mem_mb=0
    fi
    remaining_cpu=$(fcalc "$remaining_cpu" "-" "$cpu_answer")
    # Clamp CPU do >= 0.
    remaining_cpu=$(LC_ALL=C awk -v v="$remaining_cpu" 'BEGIN { if (v < 0) v = 0; printf "%.2f", v }')

    remaining_mem_weight=$(fcalc "$remaining_mem_weight" "-" "$mem_w")
    remaining_mem_weight=$(LC_ALL=C awk -v v="$remaining_mem_weight" 'BEGIN { printf "%d", v + 0.5 }')

    remaining_cpu_weight=$(fcalc "$remaining_cpu_weight" "-" "$cpu_w")
    # CPU wagi moga byc ulamkiem (12.5), zostawiamy precyzyjnie.
done

echo ""
echo "Zapisuje do $ENV_FILE..."

# Naglowek sekcji (raz).
if ! env_has_var "DBSERVER_MEM_LIMIT"; then
    {
        echo ""
        echo "# === Limity zasobow Docker (make configure-resources) ==="
        echo "# Host wykryty: ${TOTAL_RAM_GB} GB RAM, ${CPU_COUNT} CPU."
    } >> "$ENV_FILE"
fi

# Mapowanie nazwy serwisu -> prefiks zmiennej.
var_prefix_for() {
    case "$1" in
        dbserver)               echo "DBSERVER" ;;
        appserver)              echo "APPSERVER" ;;
        workerserver-general)   echo "WORKER_GENERAL" ;;
        workerserver-denorm)    echo "WORKER_DENORM" ;;
        redis)                  echo "REDIS" ;;
        loki)                   echo "LOKI" ;;
        prometheus)             echo "PROMETHEUS" ;;
        *) echo "UNKNOWN" ;;
    esac
}

for i in "${!RESULT_NAMES[@]}"; do
    svc="${RESULT_NAMES[$i]}"
    prefix=$(var_prefix_for "$svc")
    set_env_var "${prefix}_MEM_LIMIT" "${RESULT_MEM_MB[$i]}m"
    set_env_var "${prefix}_CPU_LIMIT" "${RESULT_CPU[$i]}"
done

# Dodatkowo: wewnetrzny limit Redisa - ~80% Docker limit, zostawia pole
# dla bufora sieciowego i metadanych.
redis_mem_mb=""
for i in "${!RESULT_NAMES[@]}"; do
    if [ "${RESULT_NAMES[$i]}" = "redis" ]; then
        redis_mem_mb="${RESULT_MEM_MB[$i]}"
    fi
done
if [ -n "$redis_mem_mb" ]; then
    redis_maxmem=$(( redis_mem_mb * 80 / 100 ))
    set_env_var "REDIS_MAXMEMORY" "${redis_maxmem}mb"
fi

echo ""
echo "Gotowe. Podsumowanie:"
printf "  %-25s %-10s %s\n" "serwis" "RAM" "CPU"
for i in "${!RESULT_NAMES[@]}"; do
    printf "  %-25s %-10s %s\n" \
        "${RESULT_NAMES[$i]}" \
        "$(fmt_mb "${RESULT_MEM_MB[$i]}")" \
        "${RESULT_CPU[$i]}"
done
echo ""
printf "  %-25s %-10s %s\n" "RAZEM"    "$(fmt_mb "$total_used_mem_mb")" "${total_used_cpu}"
printf "  %-25s %-10s %s\n" "budzet"   "$(fmt_mb "$MEM_BUDGET_MB")"     "${CPU_BUDGET}"
echo ""

# Ostrzezenie o przekroczeniu budzetu.
mem_over=$(( total_used_mem_mb - MEM_BUDGET_MB ))
cpu_over=$(fcalc "$total_used_cpu" "-" "$CPU_BUDGET")
if [ "$mem_over" -gt 0 ] 2>/dev/null; then
    echo "UWAGA: suma RAM ($(fmt_mb "$total_used_mem_mb")) PRZEKRACZA budzet ($(fmt_mb "$MEM_BUDGET_MB")) o $(fmt_mb "$mem_over")."
    echo "       RAM to limit TWARDY - suma limitow > RAM hosta oznacza ze kilka kontenerow"
    echo "       uderzajacych w gorne granice jednoczesnie spowoduje OOM-kille."
    echo ""
fi
if LC_ALL=C awk -v v="$cpu_over" 'BEGIN { exit (v > 0) ? 0 : 1 }'; then
    echo "UWAGA: suma CPU (${total_used_cpu}) przekracza liczbe rdzeni (${CPU_BUDGET})."
    echo "       Docker limity sa per-kontener, wiec oversubscription jest dozwolone, ale"
    echo "       kilka kontenerow naraz uderzajacych w gorny limit moze wzajemnie konkurowac."
    echo ""
fi

echo "Zeby zastosowac nowe limity, uruchom:"
echo "    make up"
echo ""
