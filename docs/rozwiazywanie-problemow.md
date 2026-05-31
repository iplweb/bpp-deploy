# Rozwiązywanie problemów

## Porty 80/443 są zajęte

**Symptom**: `make up` kończy się błędem `bind: address already in use` na `webserver`.
Lokalna instalacja nginx, Apache lub innego serwera zajmuje porty.

```bash
# Sprawdź, kto trzyma port:
sudo lsof -iTCP:80 -sTCP:LISTEN
sudo lsof -iTCP:443 -sTCP:LISTEN
```

Zatrzymaj kolidującą usługę (`sudo systemctl stop nginx`) albo zmień mapowanie portów w
`docker-compose.infrastructure.yml` (np. `8080:80`, `8443:443`) — pamiętaj o
zaktualizowaniu URL-i, którymi otwierasz aplikację.

## Przeglądarka pokazuje ostrzeżenie o niezaufanym certyfikacie

**Symptom**: po `make generate-snakeoil-certs` przeglądarka blokuje stronę z komunikatem
`NET::ERR_CERT_AUTHORITY_INVALID` lub podobnym.

To certyfikat **samopodpisany** — przewidziany do testów lokalnych. Opcje:

- **Lokalnie**: kliknij „Zaawansowane" → „Mimo to przejdź do strony" (Chrome/Edge) lub
  „Zaakceptuj ryzyko" (Firefox).
- **Produkcyjnie**: wystaw prawdziwy certyfikat przez [Let's Encrypt](konfiguracja/ssl.md)
  / komercyjne CA i podmień `cert.pem`/`key.pem` w `ssl/`. Następnie `make update-ssl-certs`.

## `permission denied` przy `docker compose` (Linux)

**Symptom**: `Got permission denied while trying to connect to the Docker daemon socket`.

Twój użytkownik nie należy do grupy `docker`:

```bash
sudo usermod -aG docker $USER
# Wyloguj się i zaloguj ponownie, albo:
newgrp docker
```

## Setup wizard `/setup/` się nie pokazuje

**Symptom**: aplikacja zamiast `/setup/` rzuca błąd 500 lub przekierowuje na login.
Najczęstsza przyczyna: migracje nie zostały uruchomione na pustej bazie.

```bash
make migrate
make logs-appserver  # Sprawdź, czy migracje przeszły bez błędu
```

## Worker / appserver się restartuje w kółko

**Symptom**: `make ps` pokazuje status `restarting` albo `unhealthy`.

```bash
make health                    # Globalny przegląd
make logs-<service>            # Zastąp <service> nazwą z make ps
docker compose logs --tail=200 <service>
```

Najczęstsze przyczyny: brak migracji bazy (uruchom `make migrate`), brak połączenia z
Redis (sprawdź czy `redis` jest healthy), niepoprawne wartości w `.env`. O reaktywnym
restarcie niezdrowych kontenerów: [Healthchecks i autoheal](architektura/healthchecks-autoheal.md).

## Po `git pull` coś się rozjechało

**Symptom**: nowe usługi się nie pojawiają, obrazy są stare, `.env` nie ma nowych zmiennych.

```bash
make init-configs   # Uzupełnia brakujące zmienne w .env (idempotentne)
make refresh        # prune + pull + recreate całego stacku
```

Backwards compatibility jest gwarantowana — `bpp-deploy` zawsze startuje na starym `.env`
(patrz [Backwards compatibility](rozwoj/backwards-compatibility.md)). Jeśli mimo to coś
nie działa, zgłoś issue.
