# BPP Deploy

[![CI](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml)

Konfiguracja wdrożeniowa systemu **BPP (Bibliografia Publikacji Pracowników)** — orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

## Wymagania

- Docker Engine 24+ z Docker Compose v2.20+
- GNU Make
- `openssl` (do generowania haseł)
- `envsubst` (zazwyczaj w pakiecie `gettext`)

## Szybki start

### 1. Sklonuj repozytorium

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

### 2. Pierwsze uruchomienie

```bash
make
```

Przy pierwszym uruchomieniu `make` zapyta o ścieżkę do **katalogu konfiguracyjnego** — musi znajdować się poza repozytorium. Jego nazwa stanie się nazwą projektu Docker Compose.

```
=== BPP Deploy - pierwsze uruchomienie ===

Podaj sciezke do katalogu konfiguracyjnego instancji BPP.
Katalog musi znajdowac sie POZA repozytorium.

Przyklad: /home/deploy/publikacje-uczelnia

Sciezka: /home/deploy/moja-instancja
```

`make` automatycznie:
- utworzy strukturę katalogów konfiguracyjnych,
- skopiuje szablonowe pliki z `defaults/`,
- wygeneruje losowe hasła do bazy danych i RabbitMQ,
- utworzy plik `.env` z konfiguracją.

### 3. Sprawdź i dostosuj konfigurację

```bash
# Edytuj zmienne aplikacyjne:
nano /home/deploy/moja-instancja/.env
```

Co trzeba zmienić w `.env`:
- `DJANGO_BPP_HOSTNAME` — właściwa nazwa hosta (np. `publikacje.uczelnia.pl`)
- `DJANGO_BPP_CSRF_EXTRA_ORIGINS` — dozwolone originy CSRF
- Sprawdź wygenerowane hasła (opcjonalnie)

Dodaj certyfikaty SSL (lub wygeneruj samopodpisane):
```bash
# Opcja A: wlasne certyfikaty
cp /sciezka/do/cert.pem /home/deploy/moja-instancja/ssl/cert.pem
cp /sciezka/do/key.pem /home/deploy/moja-instancja/ssl/key.pem

# Opcja B: samopodpisane certyfikaty (snakeoil) do testow
make generate-snakeoil-certs
```

### 4. Uruchom usługi

```bash
make run
```

## Struktura katalogów

```
~/
├── bpp-deploy/                     # To repozytorium
│   ├── .env                        # Wskazuje katalog konfiguracyjny
│   ├── Makefile
│   ├── docker-compose.*.yml
│   ├── mk/                         # Moduły Makefile
│   ├── defaults/             # Szablonowe pliki konfiguracyjne
│   └── tests/
│
├── moja-instancja/                 # Katalog konfiguracyjny (BPP_CONFIGS_DIR)
│   ├── .env                        # Zmienne aplikacyjne (hasła, hostname)
│   ├── ssl/                        # Certyfikaty SSL
│   ├── alloy/                      # Konfiguracja Grafana Alloy
│   ├── prometheus/                 # Konfiguracja Prometheus
│   ├── grafana/provisioning/       # Dashboardy i datasources Grafana
│   ├── rabbitmq/                   # Pluginy RabbitMQ
│   ├── rclone/                     # Konfiguracja backupów
│   └── dozzle/                     # Użytkownicy Dozzle
│
└── backups/                        # Backupy baz danych
```

## Najważniejsze komendy

### Wdrożenie

```bash
make run              # Pełne wdrożenie (pull, build, configs, up)
make up               # Start wszystkich usług (force recreate)
make up-quick         # Szybki start bez recreation
make stop             # Zatrzymaj usługi
make restart-appserver  # Restart serwera aplikacji
```

### Baza danych

```bash
make migrate          # Migracje Django (bezpiecznie zatrzymuje workery)
make db-backup        # Backup bazy (równoległy pg_dump, tar.gz)
make dbshell          # Django database shell
make dbshell-psql     # Bezpośredni psql
```

### Monitoring i logi

```bash
make health           # Szybki healthcheck wszystkich usług
make logs-appserver   # Logi serwera aplikacji
make logs-celery      # Logi workerów Celery
make ps               # Lista kontenerów
make celery-stats     # Statystyki zadań Celery
```

### Konfiguracja

```bash
make update-configs     # Regeneruj datasources.yaml (envsubst)
make update-ssl-certs   # Przeładuj nginx po zmianie certyfikatów
make init-configs       # Uzupełnij brakujące pliki w katalogu konfiguracyjnym
make generate-snakeoil-certs  # Wygeneruj samopodpisane certyfikaty SSL
```

### Serwer zdalny

```bash
make ssh                    # SSH do hosta
make apt-update-apt-upgrade # Aktualizacja systemu
make install-docker         # Instalacja Dockera na hoście
```

## Usługi

| Usługa | Opis |
|--------|------|
| **appserver** | Serwer aplikacji Django |
| **authserver** | Serwer uwierzytelniania dla nginx |
| **dbserver** | PostgreSQL |
| **webserver** | Nginx (reverse proxy + static files) |
| **redis** | Cache i broker Celery |
| **rabbitmq** | Broker wiadomości |
| **workerserver-general** | Ogólne zadania Celery |
| **workerserver-denorm** | Zadania denormalizacji |
| **denorm-queue** | Bridge PostgreSQL LISTEN → Celery (single instance!) |
| **celerybeat** | Harmonogram zadań okresowych |
| **flower** | UI monitorowania Celery (`/flower`) |
| **grafana** | Dashboardy i wizualizacje (`/grafana`) |
| **prometheus** | Metryki |
| **loki** | Agregacja logów |
| **alloy** | Kolektor logów z kontenerów Docker |
| **dozzle** | Przeglądarka logów w czasie rzeczywistym (`/dozzle`) |
| **rclone** | Backup do chmury |
| **ofelia** | Cron dla Dockera |

## Testy

```bash
./tests/test_makefile.sh
```

Testy weryfikują:
- first-run setup (tworzenie konfiguracji, generowanie haseł)
- idempotentność `init-configs`
- losowość haseł między instancjami
- dostępność targetów Make w trybie normalnym
- poprawność bind mountów w docker-compose
- brak mechanizmów SCP w konfiguracji

## Pre-commit hooks

Repozytorium używa [pre-commit](https://pre-commit.com/) z następującymi hookami:

- **trailing-whitespace**, **end-of-file-fixer** — formatowanie
- **check-yaml** — walidacja YAML
- **check-merge-conflict** — wykrywanie konfliktów merge
- **detect-private-key** — blokada kluczy prywatnych
- **shellcheck** — linter bash
- **TruffleHog** — wykrywanie sekretów i haseł

```bash
pip install pre-commit
pre-commit install
```

## Licencja

MIT
