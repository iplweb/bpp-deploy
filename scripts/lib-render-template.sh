#!/usr/bin/env bash
# Podstawianie zmiennych w szablonie — zamiennik `envsubst '<whitelista>'`.
# Source'owana przez scripts/generate-grafana-datasources.sh — bez
# side-effectow przy source. Testy: scripts/test-grafana-datasources.sh.
#
# DLACZEGO nie envsubst: to narzedzie z gettexta, ktorego Windows nie ma.
# Git Bash / MSYS2 nie dostarczaja envsubst.exe, a w wingecie nie ma sensownego
# pakietu gettext — pierwsze `make` konczylo sie wiec na Windows bledem
# "envsubst: command not found" (exit 127). I nie tylko pierwsze: render
# datasource'ow Grafany wisi pod `update-configs`, czyli prerequisite `make up`,
# a wiec i `make run` — bez envsubst padal KAZDY deploy.
#
# Reszta szablonow renderowanych po stronie hosta (netdata/go.d/postgres.conf,
# netdata.conf, loki/local-config.yaml) od zawsze idzie zwyklym `sed`-em
# w ensure-config-files.sh — to jest zgodnosc z tym, co repo juz robilo.

# render_template <plik_szablonu> <NAZWA_ZMIENNEJ> [NAZWA_ZMIENNEJ...]
# stdout: szablon z podstawionymi ${NAZWA} oraz $NAZWA — WYLACZNIE dla nazw
# podanych na liscie. Kazde inne ${...} zostaje nietkniete (tak samo jak przy
# envsubst z whitelista): szablon Grafany moze zawierac literalne $ w polach
# customowego datasource'a.
#
# Podstawiamy przez ${zmienna//wzorzec/zamiennik} basha, a nie sedem — wartosci
# to hasla, wiec moga zawierac &, \ i /, ktore w sedzie sa metaznakami
# (ensure-config-files musi je z tego powodu escape'owac funkcja _esc).
render_template() {
    local tpl="$1"; shift
    local -a vars=("$@")
    local i j tmp line var val needle

    # Dluzsze nazwy pierwsze: przy formie bez klamer "$FOO" podmienione wczesniej
    # zjadloby prefiks "$FOOBAR". Kilka elementow, wiec sortowanie w miejscu.
    for ((i = 0; i < ${#vars[@]}; i++)); do
        for ((j = i + 1; j < ${#vars[@]}; j++)); do
            if [ "${#vars[j]}" -gt "${#vars[i]}" ]; then
                tmp="${vars[i]}"; vars[i]="${vars[j]}"; vars[j]="$tmp"
            fi
        done
    done

    # `|| [ -n "$line" ]` — szablon bez koncowego newline'a tez ma byc wypisany.
    while IFS= read -r line || [ -n "$line" ]; do
        for var in "${vars[@]}"; do
            val="${!var-}"
            needle="\${$var}"
            line="${line//"$needle"/"$val"}"
            needle="\$$var"
            line="${line//"$needle"/"$val"}"
        done
        printf '%s\n' "$line"
    done < "$tpl"
}
