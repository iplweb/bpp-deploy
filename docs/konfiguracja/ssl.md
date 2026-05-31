# SSL — manual vs Let's Encrypt

BPP ma natywne wsparcie dla Let's Encrypt obok tradycyjnych certów na dysku.
**Certy manualne i LE współistnieją** w osobnych katalogach (`ssl/` vs `letsencrypt/`) —
LE nigdy nie nadpisuje plików w `ssl/`. Wybór trybu steruje jedna zmienna
`DJANGO_BPP_SSL_MODE` w `$BPP_CONFIGS_DIR/.env`:

```bash
DJANGO_BPP_SSL_MODE=manual       # default — czyta ssl/<host>/cert.pem (snakeoil/ręczne)
DJANGO_BPP_SSL_MODE=letsencrypt  # czyta letsencrypt/live/<host>/fullchain.pem
```

Zmiana trybu: edycja `DJANGO_BPP_SSL_MODE` + `make refresh`.

## Gdzie nginx czyta certyfikaty

=== "manual (domyślny)"

    `$BPP_CONFIGS_DIR/ssl/<host>/{cert,key}.pem` (multi-host) z fallbackiem do
    `$BPP_CONFIGS_DIR/ssl/{cert,key}.pem` (legacy single-host). Tu trafiają snakeoil
    i certy wgrane ręcznie. **LE nigdy nie pisze do `ssl/`** — separacja katalogów
    chroni manualne certy.

=== "letsencrypt"

    `$BPP_CONFIGS_DIR/letsencrypt/live/<host>/{fullchain,privkey}.pem` (per-host) z
    fallbackiem do `live/<canonical>/...` (SAN, jeden cert pod nazwą pierwszego hosta
    z `HOSTNAMES`/`HOSTNAME`). Dalsze fallbacki do ścieżek manualnych — gdy LE jeszcze
    nie wystawił certu, nginx wstaje na snakeoil.

## Wystawienie certyfikatu LE (one-shot)

DNS musi już wskazywać na ten serwer, a port 80 musi być osiągalny z internetu.

```bash
make ssl-letsencrypt-issue           # staging (LE staging API, niezaufany w przeglądarce,
                                     #          test pipeline'u)
make ssl-letsencrypt-issue PROD=1    # prod (zużywa rate-limit LE!)
```

W trybie `PROD=1` skrypt wykrywa kolizję `mode=manual` i interaktywnie pyta o flip na
`letsencrypt`. Non-interactive: `ACTIVATE=1` (auto-flip + recreate webservera) lub
`ACTIVATE=0` (zostaw `mode=manual`). Cert wystawiany jako **SAN** — jedna `--cert-name`
pod `$CANONICAL_HOST` (= pierwszy z listy), wszystkie hosty jako `-d`.

## Codzienny renew

- **04:00** — Ofelia `job-run` spawnuje świeży kontener `certbot/certbot`, wywołuje
  `certbot renew` (idempotentny — pomija certy z >30 dni do wygaśnięcia, exit 0 gdy
  `letsencrypt/` puste). Po sukcesie deploy-hook tworzy sentinel `letsencrypt/.reload-needed`.
- **04:05** — drugi job (Ofelia `job-exec` na webserverze) podnosi sentinel, robi
  `nginx -s reload` i kasuje go.

Manualny renew: `make ssl-letsencrypt-renew` (tożsamy flow, od razu).

## Zero downtime — webroot challenge

Location `/.well-known/acme-challenge/` jest w port-80 server bloku
`vhost.conf.template` — zawsze aktywny, niezależnie od `SSL_MODE`. Webroot na shared
volume `acme-challenge` (RW dla certbota, RO dla nginx). W trybie manual zwraca 404 dla
zapytań ACME, co jest bezpieczne. Certbot używa webroot (nie standalone), więc nginx
cały czas pracuje.

## Powrót do certów manualnych

Np. uczelnia dała wildcard EV:

```bash
# wgraj nowy cert do $BPP_CONFIGS_DIR/ssl/cert.pem (lub ssl/<host>/cert.pem dla multi-host)
# edytuj $BPP_CONFIGS_DIR/.env: DJANGO_BPP_SSL_MODE=manual
make refresh
```

Katalog `letsencrypt/` zostaje na dysku — można w każdej chwili wrócić bez ponownego
wystawiania.

## Samopodpisane certyfikaty (testy)

```bash
make generate-snakeoil-certs        # generuje ssl/cert.pem (i ssl/<host>/ dla multi-host)
make generate-snakeoil-certs-force  # nadpisuje istniejące
```

Przeglądarka pokaże ostrzeżenie o niezaufanym certyfikacie — to oczekiwane, patrz
[Rozwiązywanie problemów](../rozwiazywanie-problemow.md#przegladarka-pokazuje-ostrzezenie-o-niezaufanym-certyfikacie).

## Pliki

- `scripts/letsencrypt.sh` — host-side orchestrator (issue/renew, auto-flip mode po prompcie)
- `scripts/letsencrypt-reload.sh` — exec-owany przez Ofelię w webserverze, sprawdza sentinel
- `defaults/webserver/30-render-bpp-vhosts.sh` — resolver ścieżek certów świadomy `SSL_MODE`
- `docker-compose.application.yml` — service `certbot` (`profiles: ['letsencrypt']`) + label renew
- `docker-compose.infrastructure.yml` — bind mount `letsencrypt/`, volume `acme-challenge`, label reload
