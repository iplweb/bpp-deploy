#!/usr/bin/env bash
#
# check-quic-port.sh - Sprawdza dostepnosc HTTP/3 (QUIC) na porcie UDP 443
#
# Uzycie:
#   ./check-quic-port.sh              # tylko testy lokalne
#   ./check-quic-port.sh example.com  # testy lokalne + test zewnetrzny hosta
#
set -euo pipefail

OK="\033[0;32mOK\033[0m"
FAIL="\033[0;31mFAIL\033[0m"
WARN="\033[0;33mWARN\033[0m"

HOSTNAME="${1:-}"
errors=0

echo ""
echo "=== Sprawdzanie HTTP/3 (QUIC) ==="
echo ""

# 1. Sprawdz czy Docker Compose ma skonfigurowany port UDP 443
echo -n "  Port UDP 443 w konfiguracji Docker Compose... "
if docker compose port webserver 443/udp >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$FAIL"
    echo "    Port UDP 443 nie jest zmapowany w Docker Compose."
    echo "    Sprawdz docker-compose.infrastructure.yml: ports: 443:443/udp"
    errors=$((errors + 1))
fi

# 2. Sprawdz czy port UDP 443 nasluchuje na hoscie
echo -n "  Port UDP 443 nasluchuje na hoscie...          "
if command -v ss >/dev/null 2>&1; then
    udp_listen=$(ss -ulnp 2>/dev/null | grep ':443 ' || true)
elif command -v netstat >/dev/null 2>&1; then
    udp_listen=$(netstat -ulnp 2>/dev/null | grep ':443 ' || true)
elif command -v lsof >/dev/null 2>&1; then
    udp_listen=$(lsof -iUDP:443 -P -n 2>/dev/null || true)
else
    udp_listen=""
    echo -e "$WARN"
    echo "    Brak ss/netstat/lsof - nie mozna sprawdzic portu UDP na hoscie."
fi
if [ -n "$udp_listen" ]; then
    echo -e "$OK"
elif command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
    echo -e "$FAIL"
    echo "    Port UDP 443 nie nasluchuje. Kontener webserver moze nie dzialac"
    echo "    lub port UDP nie jest zmapowany."
    errors=$((errors + 1))
fi

# 3. Sprawdz naglowek Alt-Svc odpytujac z hosta
echo -n "  Naglowek Alt-Svc w odpowiedzi HTTPS...       "
alt_svc=$(curl -sk -o /dev/null -D - https://127.0.0.1:443/healthz 2>/dev/null | grep -i 'alt-svc' || true)
if [ -n "$alt_svc" ]; then
    echo -e "$OK"
    echo "    $alt_svc"
else
    echo -e "$FAIL"
    echo "    Brak naglowka Alt-Svc. Przegladarki nie beda wiedziec o HTTP/3."
    errors=$((errors + 1))
fi

# 4. Test zewnetrzny (opcjonalny, wymaga nazwy hosta)
if [ -n "$HOSTNAME" ]; then
    echo ""
    echo "  --- Test zewnetrzny: $HOSTNAME ---"
    echo ""

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "  ${WARN} curl nie jest zainstalowany, pomijam test zewnetrzny."
    elif ! curl --http3-only --version >/dev/null 2>&1; then
        echo -e "  ${WARN} Zainstalowany curl nie obsluguje --http3-only."
        echo "    Wymagany curl >= 7.88 skompilowany z HTTP/3 (np. z nghttp3)."
    else
        echo -n "  HTTP/3 na https://$HOSTNAME/...              "
        if curl --http3-only -sk -o /dev/null -m 10 "https://$HOSTNAME/" 2>/dev/null; then
            echo -e "$OK"
        else
            echo -e "$FAIL"
            echo "    Nie udalo sie polaczyc przez HTTP/3."
            echo "    Mozliwe przyczyny: firewall blokuje UDP 443, DNS nie rozwiazuje"
            echo "    hosta, lub certyfikat SSL nie pasuje do nazwy hosta."
            errors=$((errors + 1))
        fi
    fi
fi

echo ""

if [ "$errors" -eq 0 ]; then
    echo -e "  Wynik: ${OK} - HTTP/3 (QUIC) jest skonfigurowane poprawnie."
    if [ -z "$HOSTNAME" ]; then
        echo ""
        echo -e "  ${WARN} Dostepnosc zewnetrzna portu UDP 443 zalezy od firewalla"
        echo "  hosta i sieci. Aby sprawdzic z zewnatrz, uzyj:"
        echo "    make check-quic HOST=example.com"
        echo "    lub: https://http3check.net/"
    fi
else
    echo -e "  Wynik: ${FAIL} - Wykryto $errors problem(y/ow)."
fi

echo ""
exit "$errors"
