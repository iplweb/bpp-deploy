#!/usr/bin/env bash
# Normalizacja i walidacja sciezki katalogu konfiguracyjnego BPP
# (BPP_CONFIGS_DIR). Source'owana przez scripts/init-configs.sh — bez
# side-effectow przy source.
#
# Testy: scripts/test-config-path.sh (make test-config-path), plus
# test_init_configs_windows_path w tests/test_makefile.sh, ktory na
# runnerze Windows przepuszcza PRAWDZIWA sciezke C:\... przez init-configs.
#
# DLACZEGO to istnieje: pod Git Bash / MSYS2 sciezka w postaci natywnej
# (C:\dane\bpp, C:/dane/bpp, "C:\dane\bpp" wklejone przez "Kopiuj jako
# sciezke" w Eksploratorze) NIE pasuje do wzorca /* — bash nie uwaza jej za
# absolutna. init-configs doklejal ja wiec do $(pwd), czyli do katalogu
# repozytorium, i walidacja "nie wewnatrz repozytorium" odrzucala KAZDA taka
# sciezke, mimo ze uzytkownik podal katalog zupelnie gdzie indziej.
# Przechodzilo tylko "..", bo ten katalog istnieje i obsluguje go galaz
# `cd && pwd`.

# is_windows_shell — status 0 pod Git Bash / MSYS2 / Cygwin.
# cygpath to narzedzie wystepujace wylacznie tam, wiec jest zarazem
# detektorem srodowiska i konwerterem sciezek.
is_windows_shell() {
    if command -v cygpath >/dev/null 2>&1; then
        return 0
    fi
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

# normalize_config_path <sciezka>
# stdout: sciezka po: obcieciu bialych znakow (w tym CR z Windows),
# zdjeciu otaczajacych cudzyslowow, konwersji z postaci natywnej Windows
# na POSIX-owa (/c/...) oraz rozwinieciu tyldy.
# shellcheck disable=SC1003  # '\\' oraz tr '\\' to LITERALNY backslash ze sciezki
# Windows (C:\dane\bpp), a nie proba ucieczki apostrofu.
normalize_config_path() {
    local path="$1" converted drive

    # Biale znaki na brzegach; [:space:] obejmuje takze CR, ktory pod
    # Windows potrafi zostac doklejony przez terminal/`make`.
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    # Otaczajace cudzyslowy — Eksplorator Windows kopiuje sciezke wlasnie
    # jako "C:\dane\bpp", razem z cudzyslowami.
    case "$path" in
        '"'*'"') path="${path#\"}"; path="${path%\"}" ;;
        "'"*"'") path="${path#\'}"; path="${path%\'}" ;;
    esac

    # Postac natywna Windows -> POSIX. Konwertujemy TYLKO pod Windows: na
    # Linuksie katalog o nazwie "C:" jest legalna sciezka wzgledna i nie
    # wolno jej tlumaczyc na /c.
    case "$path" in
        [A-Za-z]:[\\/]* | [A-Za-z]: | '\\'*)
            if command -v cygpath >/dev/null 2>&1; then
                converted="$(cygpath -u "$path" 2>/dev/null || true)"
                if [ -n "$converted" ]; then
                    path="$converted"
                fi
            elif is_windows_shell; then
                # MSYS/MinGW bez cygpath — konwersja recznie.
                path="$(printf '%s' "$path" | tr '\\' '/')"
                case "$path" in
                    [A-Za-z]:*)
                        drive="$(printf '%s' "$path" | cut -c1 | tr '[:upper:]' '[:lower:]')"
                        path="/${drive}${path#?:}"
                        ;;
                esac
            fi
            ;;
    esac

    # Tylda (bez eval — wklejona sciezka z backtickami/`$()` nie moze sie
    # wykonac jako kod).
    # shellcheck disable=SC2088  # wzorce case dopasowuja LITERALNA tylde z inputu usera
    case "$path" in
        "~")   path="$HOME" ;;
        "~/"*) path="$HOME/${path#\~/}" ;;
    esac

    printf '%s\n' "$path"
}

# absolutize_config_path <sciezka> [katalog_bazowy]
# stdout: sciezka absolutna, bez koncowych ukosnikow.
# Jesli katalog istnieje — `cd && pwd` (najbardziej niezawodne, rozwija
# takze symlinki i ".."). Jesli nie — absolutyzacja recznie, bo dirname na
# sciezce wzglednej (np. "./foo") daje "." i psuje wyliczenie
# DEFAULT_BACKUP_DIR w init-configs.
absolutize_config_path() {
    local path="$1" base="${2:-$PWD}" abs

    if [ -d "$path" ]; then
        abs="$(cd "$path" && pwd)"
    else
        case "$path" in
            /*) abs="$path" ;;
            *)  abs="$base/$path" ;;
        esac
    fi

    # Koncowe ukosniki — inaczej basename/dirname (COMPOSE_PROJECT_NAME,
    # katalog backupow) i porownanie z REPO_DIR pracowalyby na roznych
    # postaciach tej samej sciezki.
    while [ "$abs" != "/" ] && [ "$abs" != "${abs%/}" ]; do
        abs="${abs%/}"
    done

    printf '%s\n' "$abs"
}

# config_path_inside_repo <sciezka_abs> <katalog_repo>
# status 0 gdy sciezka JEST katalogiem repozytorium lub lezy w srodku.
#
# Wzorzec MUSI konczyc sie ukosnikiem ("$repo"/*) — samo "$repo"* odrzucalo
# rowniez katalogi-rodzenstwo o wspolnym prefiksie (bpp-deploy-config obok
# bpp-deploy).
#
# Cialo w nawiasach () = subshell, wiec shopt nie wycieka do wolajacego.
config_path_inside_repo() (
    local abs="$1" repo="$2"

    [ -n "$repo" ] || return 1
    while [ "$repo" != "/" ] && [ "$repo" != "${repo%/}" ]; do
        repo="${repo%/}"
    done

    # Pod Windows system plikow nie rozroznia wielkosci liter, wiec
    # C:\Users\x\bpp-deploy\cfg i /c/users/X/BPP-Deploy/cfg to ten sam
    # katalog — porownanie z rozroznianiem przepusciloby go do srodka repo.
    if is_windows_shell; then
        shopt -s nocasematch
    fi

    case "$abs" in
        "$repo"|"$repo"/*) return 0 ;;
    esac
    return 1
)
