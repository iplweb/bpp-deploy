#!/usr/bin/env bash
#
# check-quic-port.sh - Sprawdza dostepnosc HTTP/3 (QUIC) na porcie UDP 443
#
set -euo pipefail

OK="\033[0;32mOK\033[0m"
FAIL="\033[0;31mFAIL\033[0m"
WARN="\033[0;33mWARN\033[0m"

errors=0

echo ""
echo "=== Sprawdzanie HTTP/3 (QUIC) ==="
echo ""

# 1. Sprawdz czy nginx w kontenerze nasluchuje na UDP 443
echo -n "  Nginx nasluchuje na UDP 443 w kontenerze... "
if docker compose exec -T webserver sh -c 'ss -ulnp 2>/dev/null || netstat -ulnp 2>/dev/null' 2>/dev/null | grep -q ':443 '; then
    echo -e "$OK"
else
    echo -e "$FAIL"
    echo "    Nginx nie nasluchuje na porcie UDP 443."
    echo "    Sprawdz czy konfiguracja zawiera: listen 443 quic;"
    errors=$((errors + 1))
fi

# 2. Sprawdz czy Docker mapuje port UDP 443 na hosta
echo -n "  Docker mapuje port UDP 443 na hosta...       "
if docker compose port webserver 443/udp >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$FAIL"
    echo "    Port UDP 443 nie jest zmapowany w Docker Compose."
    echo "    Sprawdz docker-compose.infrastructure.yml: ports: 443:443/udp"
    errors=$((errors + 1))
fi

# 3. Sprawdz naglowek Alt-Svc
echo -n "  Naglowek Alt-Svc w odpowiedzi HTTPS...       "
alt_svc=$(docker compose exec -T webserver curl -sk -o /dev/null -D - https://127.0.0.1:443/healthz 2>/dev/null | grep -i 'alt-svc' || true)
if [ -n "$alt_svc" ]; then
    echo -e "$OK"
    echo "    $alt_svc"
else
    echo -e "$FAIL"
    echo "    Brak naglowka Alt-Svc. Przegladarki nie beda wiedziec o HTTP/3."
    errors=$((errors + 1))
fi

echo ""

if [ "$errors" -eq 0 ]; then
    echo -e "  Wynik: ${OK} - HTTP/3 (QUIC) jest skonfigurowane poprawnie."
    echo ""
    echo -e "  ${WARN} Dostepnosc zewnetrzna portu UDP 443 zalezy od firewalla"
    echo "  hosta i sieci. Tego nie da sie zweryfikowac z tej samej maszyny."
    echo "  Aby sprawdzic z zewnatrz, uzyj np.:"
    echo "    curl --http3-only https://<hostname>/"
    echo "    lub: https://http3check.net/"
else
    echo -e "  Wynik: ${FAIL} - Wykryto $errors problem(y/ow)."
fi

echo ""
exit "$errors"
