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
    MINGW*|MSYS*|CYGWIN*)
        # Windows (Git Bash / MSYS2 / Cygwin). Runtime MSYS zwykle emuluje
        # /proc/meminfo i dostarcza nproc; gdy ktoregos brak, degradujemy
        # lagodnie (zamiast exit 1, ktore wywalalo job CI na windows-latest).
        # BPP wdraza sie na Linuksie - Windows to tylko srodowisko deweloperskie,
        # wiec wystarczy zeby skrypt dokonczyl i zapisal .env (capy fixed sa
        # niezalezne od hosta). RAM=0 -> budzet spadnie do floora ponizej.
        TOTAL_RAM_KB=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
        if [ -n "${TOTAL_RAM_KB:-}" ]; then
            TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
        else
            TOTAL_RAM_GB=0
        fi
        # nproc bywa w coreutils Git for Windows; fallback do NUMBER_OF_PROCESSORS
        # (zawsze ustawione na Windows), a w ostatecznosci 1.
        CPU_COUNT=$(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-1}")
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

if [ "$TOTAL_RAM_GB" -lt 12 ]; then
    echo "UWAGA: host ma mniej niz 12 GB RAM - minimalne wymaganie BPP."
    echo "       Limity floor (dbserver/appserver/workery) moga sie nie zmiescic;"
    echo "       skrypt przypisze floory i ostrzeze o ryzyku OOM. Zalecane 16 GB+."
    echo ""
fi

# --- Lokalizacja $BPP_CONFIGS_DIR/.env ---

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Juz wyeksportowane BPP_CONFIGS_DIR ma pierwszenstwo (testy + power-userzy);
# repo-local .env jest fallbackiem.
if [ -z "${BPP_CONFIGS_DIR:-}" ] && [ -f "$REPO_DIR/.env" ]; then
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

# --- Model limitow RAM: FIXED (staly cap) + VARIABLE (floor + waga nadwyzki) ---
#
# Uslugi ze stalym capem sa odejmowane od budzetu w pierwszej kolejnosci,
# a pozostala pula jest dzielona miedzy uslugi zmienne (dbserver/appserver/
# workery) wg floor + procentowej wagi nadwyzki. Patrz:
# docs/superpowers/specs/2026-06-01-resource-limits-redesign-design.md

# Format: name:cap_mb. Przypisywane automatycznie (bez pytania).
FIXED_MEM=(
    "redis:1024"
    "netdata:320"
    "authserver:320"
    "celerybeat:480"
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

# Format: name:floor_mb:surplus_weight. Dziela pule po odjeciu fixed.
# Od konsolidacji workerow jest JEDEN worker (`workerserver`, obie kolejki:
# celery + denorm) - przejmuje laczna wage nadwyzki dwoch poprzednich (20+15=35).
# Concurrency Celery liczy obraz (domyslnie 75% rdzeni), wiec realny apetyt jednego
# workera < sumy dwoch poprzednich; floor 1536 z zapasem dla 4-rdzeniowego hosta.
VARIABLE_MEM=(
    "dbserver:1536:40"
    "appserver:2048:25"
    "workerserver:1536:35"
)

# CPU (limit miekki). Format: name:cpu_weight. Sumuja sie do CPU_TOTAL_WEIGHT.
# Po konsolidacji jeden worker przejmuje wage dwoch poprzednich (25+12.5
# zaokraglone do 30 - reszta puli i tak idzie do dbserver/appserver).
CPU_SERVICES=(
    "dbserver:25"
    "appserver:25"
    "workerserver:30"
    "redis:7.5"
    "loki:2.5"
    "netdata:5"
)
# Suma wag CPU_SERVICES - uzywane jako startowa pula w redystrybucji.
CPU_TOTAL_WEIGHT=95

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

# --- Glowna logika: fixed capy -> pula -> uslugi zmienne -> CPU ---

echo "Budzet po rezerwie ${RESERVE_GB} GB dla OS: $(fmt_mb "$MEM_BUDGET_MB") RAM, ${CPU_BUDGET} CPU."
echo ""

# Minimalne progi - ponizej Docker odrzuca limit.
MIN_MEM_MB=64
MIN_CPU="0.1"

# (a) Suma fixed capow (stale, niezalezne od hosta).
fixed_total_mb=0
for entry in "${FIXED_MEM[@]}"; do
    IFS=: read -r _svc cap <<< "$entry"
    fixed_total_mb=$(( fixed_total_mb + cap ))
done

# (b) Pula dla uslug zmiennych = budzet - fixed. Suma floorow.
pool_mb=$(( MEM_BUDGET_MB - fixed_total_mb ))
[ "$pool_mb" -lt 0 ] && pool_mb=0
floors_total_mb=0
for entry in "${VARIABLE_MEM[@]}"; do
    IFS=: read -r _svc floor _w <<< "$entry"
    floors_total_mb=$(( floors_total_mb + floor ))
done
surplus_mb=$(( pool_mb - floors_total_mb ))

echo "Uslugi ze stalym limitem (lacznie $(fmt_mb "$fixed_total_mb")) sa przypisane automatycznie."
echo "Pozostala pula $(fmt_mb "$pool_mb") jest dzielona miedzy dbserver/appserver/worker"
echo "(floor + waga nadwyzki: db 40% / app 25% / worker 35%)."
if [ "$surplus_mb" -lt 0 ]; then
    echo ""
    echo "UWAGA: pula ($(fmt_mb "$pool_mb")) jest mniejsza niz suma minimow"
    echo "       ($(fmt_mb "$floors_total_mb")). Przypisuje minima; suma limitow przekroczy"
    echo "       budzet - ryzyko OOM. To host ponizej minimum 12 GB. Zalecane 16 GB+."
fi
echo ""
echo "Enter akceptuje wartosc domyslna. RAM bez sufiksu = MB (np. 500, 1g = 1024 MB)."
echo "CPU: ulamek rdzeni (np. 2.0 = dwa pelne rdzenie)."
echo ""

# Tylko indeksowane tablice - macOS ma bash 3.2 bez 'declare -A'.
declare -a RESULT_NAMES
declare -a RESULT_MEM_MB
declare -a CPU_NAMES
declare -a CPU_VALS

# Lookup po nazwie w rownoleglych tablicach (zastepuje tablice asocjacyjne).
mem_for() {
    local q="$1" i
    for i in "${!RESULT_NAMES[@]}"; do
        [ "${RESULT_NAMES[$i]}" = "$q" ] && { echo "${RESULT_MEM_MB[$i]}"; return 0; }
    done
    return 1
}
cpu_for() {
    local q="$1" i
    for i in "${!CPU_NAMES[@]}"; do
        [ "${CPU_NAMES[$i]}" = "$q" ] && { echo "${CPU_VALS[$i]}"; return 0; }
    done
    return 1
}

# (c) Interaktywny MEM dla uslug zmiennych z redystrybucja nadwyzki.
remaining_surplus_mb=$surplus_mb
[ "$remaining_surplus_mb" -lt 0 ] && remaining_surplus_mb=0
remaining_weight=100
for entry in "${VARIABLE_MEM[@]}"; do
    IFS=: read -r svc floor weight <<< "$entry"

    # Default = floor + przydzial z pozostalej nadwyzki wg wagi.
    if [ "$remaining_weight" -le 0 ]; then
        default_mem_mb=$floor
    else
        default_mem_mb=$(LC_ALL=C awk -v f="$floor" -v s="$remaining_surplus_mb" -v w="$weight" -v t="$remaining_weight" \
            'BEGIN { printf "%d", f + s * w / t + 0.5 }')
    fi
    [ "$default_mem_mb" -lt "$MIN_MEM_MB" ] && default_mem_mb=$MIN_MEM_MB

    mem_answer=""
    mem_mb=0
    while true; do
        mem_answer=$(ask_mem "$svc RAM" "$default_mem_mb" "$(fmt_mb "$default_mem_mb")")
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

    RESULT_NAMES+=("$svc")
    RESULT_MEM_MB+=("$mem_mb")

    # Redystrybucja: to co poszlo ponad floor zmniejsza pule nadwyzki.
    used_surplus=$(( mem_mb - floor ))
    remaining_surplus_mb=$(( remaining_surplus_mb - used_surplus ))
    [ "$remaining_surplus_mb" -lt 0 ] && remaining_surplus_mb=0
    remaining_weight=$(LC_ALL=C awk -v t="$remaining_weight" -v w="$weight" 'BEGIN { printf "%d", t - w + 0.5 }')
done

# (c2) Fixed: przypisz capy bez pytania.
for entry in "${FIXED_MEM[@]}"; do
    IFS=: read -r svc cap <<< "$entry"
    RESULT_NAMES+=("$svc")
    RESULT_MEM_MB+=("$cap")
done

# (d) CPU - logika i wagi bez zmian (zmiana dotyczy tylko RAM).
remaining_cpu=$CPU_BUDGET
remaining_cpu_weight=$CPU_TOTAL_WEIGHT
for entry in "${CPU_SERVICES[@]}"; do
    IFS=: read -r svc cpu_w <<< "$entry"
    default_cpu=$(LC_ALL=C awk -v r="$remaining_cpu" -v w="$cpu_w" -v t="$remaining_cpu_weight" -v min="$MIN_CPU" \
        'BEGIN { if (t <= 0) v = min; else v = r * w / t; if (v < min) v = min; printf "%.1f", v }')
    cpu_answer=""
    while true; do
        cpu_answer=$(ask "$svc CPU" "$default_cpu")
        if ! [[ "$cpu_answer" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "    Blad: nie rozumiem '$cpu_answer'. Podaj liczbe, np 2.0 lub 1.5." >&2
            continue
        fi
        cpu_answer=$(round1 "$cpu_answer")
        if LC_ALL=C awk -v v="$cpu_answer" -v m="$MIN_CPU" 'BEGIN { exit (v < m) ? 0 : 1 }'; then
            echo "    Blad: minimum to ${MIN_CPU} CPU (Docker odrzuci mniej)." >&2
            continue
        fi
        break
    done
    CPU_NAMES+=("$svc")
    CPU_VALS+=("$cpu_answer")
    remaining_cpu=$(fcalc "$remaining_cpu" "-" "$cpu_answer")
    remaining_cpu=$(LC_ALL=C awk -v v="$remaining_cpu" 'BEGIN { if (v < 0) v = 0; printf "%.2f", v }')
    remaining_cpu_weight=$(fcalc "$remaining_cpu_weight" "-" "$cpu_w")
done

# Sumy do podsumowania.
total_used_mem_mb=0
for v in "${RESULT_MEM_MB[@]}"; do total_used_mem_mb=$(( total_used_mem_mb + v )); done
total_used_cpu="0"
for v in "${CPU_VALS[@]}"; do total_used_cpu=$(fcalc "$total_used_cpu" "+" "$v"); done

echo ""
echo "Zapisuje do $ENV_FILE..."

# Sprzatanie po konsolidacji+renamie: jeden worker (`workerserver`) => WORKER_*.
# Stare WORKER_GENERAL_*/WORKER_DENORM_* nie sa juz uzywane - usuwamy, zeby re-run
# nie zostawial martwych zmiennych w .env. (init-configs robi migracje wartosci.)
for _stale in WORKER_GENERAL_MEM_LIMIT WORKER_GENERAL_CPU_LIMIT \
              WORKER_DENORM_MEM_LIMIT WORKER_DENORM_CPU_LIMIT; do
    if env_has_var "$_stale"; then
        _tmp="$ENV_FILE.tmp.$$"
        awk -v k="$_stale" '$0 !~ "^" k "=" { print }' "$ENV_FILE" > "$_tmp" \
            && mv "$_tmp" "$ENV_FILE"
        echo "  ~ usunieto nieuzywana (po konsolidacji workerow): $_stale"
    fi
done

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
        workerserver)           echo "WORKER" ;;
        redis)                  echo "REDIS" ;;
        loki)                   echo "LOKI" ;;
        netdata)                echo "NETDATA" ;;
        authserver)             echo "AUTHSERVER" ;;
        celerybeat)             echo "CELERYBEAT" ;;
        denorm-queue)           echo "DENORM_QUEUE" ;;
        alloy)                  echo "ALLOY" ;;
        grafana)                echo "GRAFANA" ;;
        flower)                 echo "FLOWER" ;;
        webserver)              echo "WEBSERVER" ;;
        dozzle)                 echo "DOZZLE" ;;
        ofelia)                 echo "OFELIA" ;;
        autoheal)               echo "AUTOHEAL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# MEM dla wszystkich uslug (.env = jedno zrodlo prawdy); CPU tylko dla 7
# uslug z CPU_SERVICES (reszta korzysta z defaultow compose).
for i in "${!RESULT_NAMES[@]}"; do
    svc="${RESULT_NAMES[$i]}"
    prefix=$(var_prefix_for "$svc")
    set_env_var "${prefix}_MEM_LIMIT" "${RESULT_MEM_MB[$i]}m"
    if cpu_val=$(cpu_for "$svc"); then
        set_env_var "${prefix}_CPU_LIMIT" "$cpu_val"
    fi
done

# Dodatkowo: wewnetrzny limit Redisa - ~80% Docker limit, zostawia pole
# dla bufora sieciowego i metadanych.
redis_mem_mb=$(mem_for redis || true)
if [ -n "$redis_mem_mb" ]; then
    redis_maxmem=$(( redis_mem_mb * 80 / 100 ))
    set_env_var "REDIS_MAXMEMORY" "${redis_maxmem}mb"
fi

echo ""
echo "Gotowe. Podsumowanie:"
printf "  %-25s %-10s %s\n" "serwis" "RAM" "CPU"
for i in "${!RESULT_NAMES[@]}"; do
    svc="${RESULT_NAMES[$i]}"
    printf "  %-25s %-10s %s\n" \
        "$svc" \
        "$(fmt_mb "${RESULT_MEM_MB[$i]}")" \
        "$(cpu_for "$svc" || echo "—")"
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
