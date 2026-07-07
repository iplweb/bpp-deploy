#!/usr/bin/env bash
#
# Czysci renderowany "page cache" BPP po deployu - NIE ruszajac sesji.
#
# BPP trzyma w cache 'default' (django-redis) trzy rozlaczne namespace'y kluczy:
#   views.decorators.cache.*        -> @cache_page (dashboardy admin_dashboard)
#   template.cache.*                -> fragmenty {% cache %} w szablonach
#   django.contrib.sessions.cache*  -> SESJE (SESSION_ENGINE=cache) -- ZOSTAWIAMY
#
# Dlaczego NIE 'redis-cli FLUSHDB': cache i sesje dziela te sama baze Redisa
# (numer bazy wynika z production.py; 'default' cache ma db w OPTIONS a nie w
# URL-u, wiec pod BlockingConnectionPool efektywnie ląduje w DB 0). Flush calej
# bazy = wylogowanie wszystkich. Zamiast tego kasujemy PO WZORCU KLUCZA przez
# Django (cache.delete_pattern -> SCAN): trafia dokladnie w to polaczenie, ktore
# realnie zestawil production.py, i pomija sesje -- bez zgadywania numeru bazy
# po stronie deploya. Wzorce 'views...'/'template...' z definicji NIE moga
# trafic w 'django.contrib.sessions.*', wiec sesje sa bezpieczne nawet przy
# nieidealnym wzorcu.
set -euo pipefail

read -r -d '' PY <<'PYCODE' || true
from django.core.cache import cache

total = 0
for pat in ("views.decorators.cache*", "template.cache*"):
    n = cache.delete_pattern(pat) or 0
    total += n
    print(f"  {pat} -> usunieto {n} kluczy")
print(f"Page cache wyczyszczony: {total} kluczy (sesje nietkniete).")
PYCODE

echo "Czyszczenie page cache (sesje pozostaja nietkniete)..."

# Best-effort: nieudane czyszczenie page cache NIE moze przerywac deployu
# (stack jest juz UP). Blad jest raportowany (nie polykany po cichu), a cache
# i tak wygasnie sam po TTL. -T: bez pseudo-TTY, zeby stdin (kod dla shella)
# przeszedl przez pipe i 'manage.py shell' wykonal go zamiast wejsc w tryb
# interaktywny.
if ! printf '%s\n' "$PY" | docker compose exec -T appserver python src/manage.py shell; then
    echo "OSTRZEZENIE: nie udalo sie wyczyscic page cache (blad wyzej)." >&2
    echo "             Deploy kontynuowany; page cache wygasnie sam po TTL" >&2
    echo "             (@cache_page 24h, fragmenty {% cache %} 3600s)." >&2
fi
