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

## Wszystkie panele w Grafanie pokazują „No data"

**Symptom**: Grafana działa — strona się ładuje, dashboardy się otwierają, listy
w rozwijankach się wypełniają — ale **każdy** panel na **każdym** dashboardzie
jest pusty.

Najpierw ustal, czy żądania o dane w ogóle dochodzą do Grafany:

```bash
docker compose logs --tail=200 webserver | grep '/grafana/api/ds/query'
```

- **`403`** → blokuje je nasz własny WAF. Tak wyglądał błąd naprawiony regułą
  `10006` (2026-08-05): zapytanie LogQL zawiera ciąg `|debug` (rozwinięcie
  `Log Level = All`), a reguła CRS `932110` czyta to jako wstrzyknięcie
  polecenia. Pełny opis:
  [WAF → Dlaczego Grafana jest wyjęta w całości](architektura/waf.md#grafana-poza-waf).
  Naprawa to `git pull && make up` — reguła jedzie w wersjonowanym bind-moucie,
  bez migracji `.env`.
- **`502`** → Grafana nie stoi; `make ps`, `make logs-grafana`.
- **brak takich linii** → problem jest po stronie przeglądarki albo
  `auth_request` (patrz `401` w logu) — sprawdź, czy jesteś zalogowany w BPP
  jako superuser.

Jeśli żądania wracają z `200`, a panele i tak są puste, przyczyna leży w danych,
nie w brzegu — patrz [Logowanie](monitoring/logowanie.md) i uwaga o pułapce
filtrów ad-hoc w [dashboardach Grafany](monitoring/dashboardy-grafany.md).

## Redaktor nie może zapisać publikacji (403 w `/admin/`)

**Symptom**: zapis rekordu w panelu admina kończy się błędem, a w logach kontenerów
BPP **nie ma śladu tego żądania** — bo nigdy nie dotarło do Django.

To WAF. Formularze admina przyjmują dowolny tekst naukowy, a CRS na paranoi 1
czyta jego postacie jako atak — `p < (0,05)` i LaTeX `$(1-\alpha)$` jako wyrażenie
powłoki, `; type 1 diabetes` jako komendę Windows, `(PPEQ) (the Polish adaptation…)`
jako wywołanie funkcji PHP, niedokończoną datę `..` jako path traversal.

Naprawia to reguła `10009`, która od 2026-08-23 przełącza **całą** ścieżkę
`^/admin/<app>/<model>/` w `DetectionOnly`
([Formularze admina](architektura/waf.md#formularze-admina)). Jeśli instalacja
jej nie ma, wystarczy `git pull && make up` — wykluczenia jadą w wersjonowanym
bind-moucie, bez migracji `.env`.

!!! warning "Jeśli blokada dotyczy `/admin/login/`, to prawdopodobnie nie fałszywy alarm"
    Formularz logowania jest celowo **poza** wykluczeniem i to właśnie tam leci
    realny ruch atakujący (338 blokad na 7 dni w pomiarze z 2026-08-23, głównie
    SQLi). Zanim cokolwiek wyłączysz, sprawdź, czy zgłaszający na pewno próbował
    się zalogować, a nie zapisać rekord.

Jeśli objaw wraca na **innej** treści na formularzu modelu, sprawdź najpierw, czy
`10009` na pewno działa (`grep 10009` w pliku wykluczeń) — cała ścieżka powinna
być już przepuszczana. Jeśli blokada jest gdzie indziej, znajdź regułę, która
faktycznie strzeliła — wpis `949110` tylko sumuje i nie mówi nic o przyczynie:

```bash
docker compose logs webserver | grep '<unique_id z wpisu 949110>'
```

## Po `git pull` coś się rozjechało

**Symptom**: nowe usługi się nie pojawiają, obrazy są stare, `.env` nie ma nowych zmiennych.

```bash
make init-configs   # Uzupełnia brakujące zmienne w .env (idempotentne)
make refresh        # prune + pull + recreate całego stacku
```

Backwards compatibility jest gwarantowana — `bpp-deploy` zawsze startuje na starym `.env`
(patrz [Backwards compatibility](rozwoj/backwards-compatibility.md)). Jeśli mimo to coś
nie działa, zgłoś issue.
