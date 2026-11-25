# shellcheck shell=bash
#
# Pilnowanie praw do .env z sekretami w katalogu konfiguracyjnym.
#
# $BPP_CONFIGS_DIR/.env trzyma haslo bazy, klucz szyfrowania pol
# (DJANGO_BPP_FIELD_ENCRYPTION_KEY), hasla SMTP i tokeny. Na instalacjach
# produkcyjnych zastawalismy go z trybem 0664 (czytelny dla kazdego konta na
# hoscie): init-configs tworzyl go bez jawnego trybu, a migracje przez
# `tmp + mv` dziedziczyly umask operatora. Kopie `.env.*` (`.env.przed-*`,
# `.env.bak.*` z validate-env-quotes) maja te same sekrety.
#
# Dlaczego 0600 niczego nie psuje (sprawdzone grepem po docker-compose*.yml):
#   - `env_file:` i interpolacje `${...}` czyta proces `docker compose`, czyli
#     operator - wlasciciel pliku. Do kontenerow trafiaja juz WARTOSCI, nie plik.
#   - Makefile `-include`-uje .env tez jako operator.
#   - Jedyny kontener montujacy katalog konfiguracyjny w calosci to
#     backup-runner (`${BPP_CONFIGS_DIR}:/configs:ro`), a ten dziala jako root
#     (docker:cli, celowo bez `user:`), wiec 0600 czyta bez problemu.
#   - Zaden inny kontener nie montuje .env jako pliku.
#
# Przenosnosc: bez `stat` (GNU `-c` vs BSD `-f`) i bez `find -perm /077`
# (GNU-only). Tryb czytamy z pierwszej kolumny `ls -ld`, chmod robimy
# symbolicznie (`go-rwx`). Na Windows/Git Bash chmod bywa no-opem - wtedy
# `ls` po zmianie pokazuje to samo, wiec nie wypisujemy komunikatu i nie
# zwracamy bledu. Fail-open: funkcja ZAWSZE zwraca 0 - prawa do pliku nie
# moga wywrocic deployu.

# Bez `--` w chmod/ls: BSD chmod na macOS bierze `--` za nazwe pliku (blad
# "No such file", exit 1 mimo ze plik zmienil). Sciezki zawsze zaczynaja sie
# od katalogu, wiec myslnik na poczatku nie grozi.
#
# Znaki 5-10 z `ls -ld` = prawa grupy i innych ("------" = nic).
_env_perms_go() {
    # shellcheck disable=SC2012  # ls celowo: stat nie jest przenosny
    # `|| true`: pod `set -euo pipefail` wolajacego blad ls nie moze ubic skryptu.
    { ls -ld "$1" 2>/dev/null | cut -c5-10; } || true
}

# env_perms_harden KATALOG - zdejmuje prawa grupy/innych z KATALOG/.env
# i KATALOG/.env.*; jedna linia informacji na kazdy faktycznie zmieniony plik.
env_perms_harden() {
    local dir="$1" f przed po
    [ -d "$dir" ] || return 0
    for f in "$dir/.env" "$dir"/.env.*; do
        # Tylko zwykle pliki (glob bez dopasowania zostaje doslowny).
        [ -f "$f" ] || continue
        przed="$(_env_perms_go "$f")"
        [ -n "$przed" ] || continue
        [ "$przed" = "------" ] && continue
        if ! chmod go-rwx "$f" 2>/dev/null; then
            echo "  ! OSTRZEZENIE: nie udalo sie ograniczyc praw do $f (tryb ...${przed}) - plik z sekretami czytelny dla innych kont; popraw recznie: chmod 600 \"$f\"" >&2
            continue
        fi
        po="$(_env_perms_go "$f")"
        if [ "$po" != "$przed" ]; then
            echo "  ~ ograniczono prawa do pliku z sekretami (teraz tylko wlasciciel): $f"
        fi
    done
    return 0
}
