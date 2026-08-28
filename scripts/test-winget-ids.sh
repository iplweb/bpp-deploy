#!/usr/bin/env bash
#
# Sprawdza, czy identyfikatory pakietow winget uzyte w dokumentacji instalacji
# dla Windows nadal istnieja w repozytorium microsoft/winget-pkgs.
#
# Po co: instrukcja dla Windows kaze uzytkownikowi wkleic `winget install --id
# <ID>`. Gdy pakiet zostanie przemianowany albo usuniety, instrukcja zaczyna
# cicho klamac — u nas nic sie nie psuje, a user dostaje "No package found
# matching input criteria". Runnery GitHuba nie maja wirtualizacji zagniezdzonej
# (brak WSL2 i Docker Desktopa) ani uzywalnego wingeta, wiec PRAWDZIWEJ
# instalacji w CI przetestowac sie nie da. To jest tanie przyblizenie: nie
# sprawdza, czy instalacja przejdzie, tylko czy identyfikatory sa aktualne.
#
# Identyfikatory czytamy Z DOKUMENTACJI, nie z listy zaszytej tutaj — dzieki
# temu dopisanie nowego pakietu do instrukcji automatycznie wchodzi pod test.
#
# Wymaga sieci (api.github.com). Ustaw GITHUB_TOKEN, zeby nie wpasc w limit
# zapytan dla anonimowych klientow (60/h na adres IP).
#
# Uruchomienie: `make test-winget-ids` lub `bash scripts/test-winget-ids.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Pliki z instrukcja instalacji dla Windows. Dopisujac kolejny, pamietaj ze
# skrypt szuka w nim linii z `winget install`.
DOC_FILES=(
    "$REPO_DIR/README.md"
    "$REPO_DIR/docs/instalacja/windows.md"
)

API_REPO="https://api.github.com/repos/microsoft/winget-pkgs/contents"
WEB_REPO="https://github.com/microsoft/winget-pkgs/tree/master"

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
PASS=0; FAIL=0
pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Wyciaga identyfikator pakietu z pojedynczej komendy `winget install ...`.
# Obsluguje obie formy uzywane w dokumentacji:
#   winget install -e --id Git.Git --source winget
#   winget install ezwinports.make --source winget
id_from_command() {
    # shellcheck disable=SC2048,SC2086  # celowe dzielenie na slowa
    set -- $1
    shift 2  # "winget" "install"
    while [ $# -gt 0 ]; do
        case "$1" in
            --id)          printf '%s\n' "$2"; return 0 ;;
            --source|-s)   shift 2 ;;
            -*)            shift ;;
            *)             printf '%s\n' "$1"; return 0 ;;
        esac
    done
}

# Zbiera unikalne identyfikatory ze wszystkich plikow dokumentacji. Wzorzec ucina
# sie na backticku i cudzyslowie, zeby zlapac takze komendy wtracone w zdanie.
extract_ids() {
    local file cmd
    for file in "${DOC_FILES[@]}"; do
        [ -f "$file" ] || { red "Brak pliku dokumentacji: $file"; exit 1; }
        while IFS= read -r cmd; do
            id_from_command "$cmd"
        done < <(grep -o 'winget install[^`"]*' "$file" || true)
    done | sort -u
}

# Identyfikator -> sciezka manifestu w winget-pkgs:
#   Git.Git              -> manifests/g/Git/Git
#   Docker.DockerDesktop -> manifests/d/Docker/DockerDesktop
#   ezwinports.make      -> manifests/e/ezwinports/make
manifest_path() {
    local id="$1" first
    first="$(printf '%s' "${id:0:1}" | tr '[:upper:]' '[:lower:]')"
    printf 'manifests/%s/%s\n' "$first" "${id//.//}"
}

http_code_for() {
    local url="$1"
    local -a curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time 20)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    # Brak sieci/timeout to u curla blad, nie kod HTTP — zamieniamy na 000,
    # zeby wywolujacy mogl odroznic awarie transportu od odpowiedzi serwera.
    curl "${curl_args[@]}" "$url" 2>/dev/null || printf '000'
}

# Sprawdza jeden identyfikator. Bledy sieci i limitu zapytan sa PONAWIANE, a gdy
# nie ustapia — raportowane jawnie jako awaria srodowiska, nie jako brak pakietu.
# Cichy skip byłby tu najgorszy: test swieciłby na zielono, nie sprawdzajac nic.
check_id() {
    local id="$1"
    local path url code attempt
    path="$(manifest_path "$id")"
    url="$API_REPO/$path"

    for attempt in 1 2 3; do
        code="$(http_code_for "$url")"
        case "$code" in
            200)
                pass "$id — manifest istnieje ($WEB_REPO/$path)"
                return 0
                ;;
            404)
                fail "$id — BRAK manifestu w microsoft/winget-pkgs ($path).
        Pakiet zostal przemianowany albo usuniety. Znajdz nowy identyfikator
        (https://winget.run lub 'winget search') i popraw instrukcje w:
        README.md oraz docs/instalacja/windows.md."
                return 1
                ;;
            403|429)
                red "  ... limit zapytan API GitHuba (HTTP $code), proba $attempt/3"
                sleep 5
                ;;
            000|5??)
                red "  ... blad sieci/API (HTTP $code), proba $attempt/3"
                sleep 5
                ;;
            *)
                fail "$id — nieoczekiwana odpowiedz API GitHuba: HTTP $code ($url)"
                return 1
                ;;
        esac
    done

    fail "$id — nie udalo sie odpytac API GitHuba po 3 probach (ostatni kod: $code).
        To awaria sieci lub limitu zapytan, a NIE dowod, ze pakiet zniknal.
        Ustaw GITHUB_TOKEN albo powtorz uruchomienie."
    return 1
}

echo "Identyfikatory winget z dokumentacji vs. microsoft/winget-pkgs"
echo

IDS=()
while IFS= read -r id; do
    [ -n "$id" ] && IDS+=("$id")
done < <(extract_ids)

# Zero znalezionych identyfikatorow = test przestal cokolwiek sprawdzac. To blad
# samego testu (zmienil sie zapis komend w dokumentacji), a nie sukces.
if [ ${#IDS[@]} -eq 0 ]; then
    red "Nie znaleziono ani jednej komendy 'winget install' w dokumentacji."
    red "Sprawdz DOC_FILES i wzorzec w extract_ids() — test nie pokrywa juz niczego."
    exit 1
fi

for id in "${IDS[@]}"; do
    check_id "$id" || true
done

echo
echo "Sprawdzono: ${#IDS[@]}, PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
