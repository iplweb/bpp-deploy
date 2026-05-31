# Multi-host (jeden Django, wiele domen)

Jedna instancja BPP może obsługiwać wiele różnych domen równocześnie — wszystkie żądania
trafiają do tego samego appservera i tej samej bazy. Typowe użycie: konsorcjum uczelni,
gdzie każda jednostka chce dostawać BPP pod własną nazwą (`bpp.uczelnia-a.pl`,
`bpp.uczelnia-b.pl`, `bpp.federacja.pl`).

## Włączenie

W `$BPP_CONFIGS_DIR/.env` ustaw `DJANGO_BPP_HOSTNAMES` jako listę CSV i **usuń**
`DJANGO_BPP_HOSTNAME` (Django w `bpp` czyta jedną z nich — oba ustawione naraz powodują
konflikt w `settings.py`):

```bash
DJANGO_BPP_HOSTNAMES=bpp.uczelnia-a.pl,bpp.uczelnia-b.pl,bpp.federacja.pl
# DJANGO_BPP_HOSTNAME=...  ← usuń tę linię
```

`make init-configs` w trybie multi-host:

- pomija prompt o `DJANGO_BPP_HOSTNAME`,
- auto-derive-uje `DJANGO_BPP_CSRF_EXTRA_ORIGINS=https://host1,https://host2,...` z całej
  listy (jeśli zmienna nie jest jeszcze ustawiona),
- ostrzega, gdy w `.env` znajdzie obie zmienne naraz.

Dotychczasowy single-host flow (`DJANGO_BPP_HOSTNAME` + `ssl/cert.pem`+`key.pem`) działa
bez zmian — gdy `DJANGO_BPP_HOSTNAMES` puste, nginx dostaje jeden vhost dokładnie jak wcześniej.

## Certyfikaty SSL — per-host

Różne organizacje zwykle mają własne CA, więc każdy host dostaje własną parę cert+key:

```
$BPP_CONFIGS_DIR/ssl/
├── cert.pem                          # legacy single-host (nadal działa)
├── key.pem
├── bpp.uczelnia-a.pl/cert.pem        # per-host
├── bpp.uczelnia-a.pl/key.pem
├── bpp.uczelnia-b.pl/cert.pem
├── bpp.uczelnia-b.pl/key.pem
└── bpp.federacja.pl/cert.pem
    bpp.federacja.pl/key.pem
```

Dla danego hosta wgraj certyfikat do podkatalogu `ssl/<nazwa-hosta>/`. Jeśli per-host
nie istnieje, nginx-entrypoint fallbackuje do `ssl/cert.pem`+`key.pem` — co jest sensowne
tylko gdy wszystkie hosty są aliasami w jednym certyfikacie SAN.

### Snakeoile (testy)

`make generate-snakeoil-certs` wykrywa tryb multi-host i generuje pary per-host:

```bash
make generate-snakeoil-certs        # tworzy ssl/<host>/cert.pem dla każdego hosta z CSV
make generate-snakeoil-certs-force  # nadpisuje istniejące
```

## Po zmianach (dodanie/usunięcie hosta lub podmiana certu)

```bash
make update-ssl-certs   # regeneruje vhost-*.conf w kontenerze i robi nginx -s reload
```

## Co dzieje się pod spodem

Entrypoint nginx-a (`30-render-bpp-vhosts.sh`) iteruje po liście, dla każdego hosta
wybiera certyfikat (per-host lub legacy fallback) i renderuje
`/etc/nginx/conf.d/vhost-<host>.conf` z `defaults/webserver/vhost.conf.template`.
Wspólne wnętrze (proxy do appservera, `/grafana/`, `/flower/`, `/static/`, `/media/`,
gzip, security blocks) trzymane jest w `defaults/webserver/_bpp-locations.conf` i
includowane przez każdy vhost — żeby zmiana reguły nie wymagała edytowania N plików.

Globalne catch-all bloki (HTTP 444 dla nieznanego hosta, HTTPS `ssl_reject_handshake`
dla nieznanego SNI) zostają w `default.conf.template`. Tylko nazwy z `DJANGO_BPP_HOSTNAMES`
są redirectowane na HTTPS — reszta dostaje 444.

!!! note "Po stronie Django"
    `ALLOWED_HOSTS` musi obejmować wszystkie nazwy z `DJANGO_BPP_HOSTNAMES`. Sposób
    konfiguracji jest po stronie obrazu `appservera` — sprawdź ustawienia w repo `bpp`.
    `DJANGO_BPP_CSRF_EXTRA_ORIGINS` (wystawiane przez `init-configs`) automatycznie
    pokrywa wszystkie hosty.
