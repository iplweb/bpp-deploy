# Auto-update: nienadzorowana aktualizacja BPP (`make autoupdate`)

Data: 2026-07-08
Status: zatwierdzony do implementacji

## Problem

Operator chce, żeby host BPP sam co ~2h sprawdzał, czy jest nowa wersja do
wdrożenia, i — jeśli jest — wdrażał ją bez ręcznego logowania. Dziś aktualizacja
to ręczne `git pull && make run`.

## Cel

Jedno polecenie (`make autoupdate`) uruchamiane pod nazwaną sesją `screen`/`tmux`,
które w pętli co konfigurowalny interwał (domyślnie 2h) sprawdza, czy pojawił się
**nowszy obraz Docker** lub **nowszy commit na `origin/main`**, i jeśli tak —
wykonuje `git pull --ff-only` + `make run`.

## Decyzje projektowe (ustalone w brainstormingu)

- **Napęd:** `screen`/`tmux` (najprostsze, widoczne, bez roota). Logika napisana
  mechanizm-agnostycznie, więc `cron`/`systemd` to potem jedna linijka.
- **Wyzwalacz:** nowy obraz **LUB** nowy commit na `origin/main`.
- **Backup przed deployem:** konfigurowalny, **domyślnie WYŁĄCZONY**
  (`AUTOUPDATE_DB_BACKUP=1` włącza).
- **Logowanie:** tylko stdout z timestampem (łapie je `screen`/`systemd`). Bez
  ntfy i bez pliku logu w v1 (YAGNI).

## Architektura — rozdzielenie „jeden cykl" od „harmonogramu"

### `scripts/autoupdate.sh` — jeden cykl (bezstanowy, idempotentny)

1. **Lock** przez `mkdir` (atomowy, portowalny; `flock` nie ma na macOS gdzie
   biegną testy). Katalog locka: `${AUTOUPDATE_LOCK_DIR:-$REPO_DIR/.autoupdate.lock.d}`.
   Zajęty lock → log + `exit 0` (nie nakładamy cykli, nie kolidujemy z ręcznym
   `make run`).
2. **Git:** `git fetch origin`; jeśli `origin/main` wyprzedza HEAD **i** HEAD jest
   przodkiem `origin/main` (fast-forward możliwy) → `git_changed=1`. Jeśli
   rozjazd (nie-ff) → ostrzeżenie, **pomiń git** (nie psujemy drzewa).
3. **Obrazy:** zbierz ID obrazów (`docker compose config --images` →
   `docker image inspect`), `docker compose pull`, zbierz ID ponownie. Różnica →
   `image_changed=1`. Registry-agnostic, działa dla `:latest`.
4. **Decyzja:** brak zmian → log + `exit 0`. Są zmiany →
   - jeśli `AUTOUPDATE_DB_BACKUP=1`: `make db-backup`; niepowodzenie → **przerwij**
     (fail-safe), nie deployuj.
   - jeśli `git_changed`: `git pull --ff-only origin main`; niepowodzenie →
     przerwij.
   - `BPP_SKIP_HEALTH_GATE=1 make run`.
5. Log wyniku z timestampem.

### `make autoupdate` (w `mk/deployment.mk`) — harmonogram

Cienka pętla: `while true; do bash scripts/autoupdate.sh; sleep $AUTOUPDATE_INTERVAL; done`.
Skrypt wołany **świeżo co iterację**, więc po `git pull` następny cykl używa już
zaktualizowanej logiki. Błąd cyklu nie zabija pętli (loguje i czeka dalej).

## Konfiguracja (env; wszystko z domyślnymi — zero wymaganych zmian w `.env`)

- `AUTOUPDATE_INTERVAL` — sekundy między cyklami, domyślnie `7200`.
- `AUTOUPDATE_DB_BACKUP` — `1` = backup przed deployem, domyślnie `0`.
- `AUTOUPDATE_LOCK_DIR` — nadpisanie katalogu locka (głównie do testów).

## Kruche miejsca / kontrakty

- **`BPP_SKIP_HEALTH_GATE=1`** przy `make run` — inaczej prompt `[s]/[d]` bramki
  zdrowia zablokowałby pętlę pod pseudo-TTY screena (kontrakt z CLAUDE.md dla
  nie-interaktywnych wywołań `make up`). Autoupdate to nowy taki wywołujący.
- **`git pull --ff-only`** — brak merge/rebase; rozjazd = pomiń, nie psuj.
- **Fail-safe backupu** — gdy włączony i padnie, nie deployujemy.

## Uruchomienie

```bash
screen -dmS bpp-autoupdate make autoupdate   # start w tle
screen -r bpp-autoupdate                     # podgląd (Ctrl-A D = detach)
```

Przeżycie rebootu (opcjonalnie, w cronie hosta):
```
@reboot cd /sciezka/do/bpp-deploy && screen -dmS bpp-autoupdate make autoupdate
```

## Testy — `scripts/test-autoupdate.sh` + `make test-autoupdate`

Mockują `git`/`docker`/`make` (wzorzec z `test-post-deploy-check.sh`):
- brak zmian → **brak** `make run`,
- nowy obraz → `make run`,
- nowy commit (ff) → `git pull` + `make run`,
- rozjazd (nie-ff) bez zmian obrazu → ostrzeżenie, **brak** deployu,
- `AUTOUPDATE_DB_BACKUP=1` + backup pada → **brak** `make run`, exit ≠ 0,
- lock zajęty → `exit 0`, **brak** deployu.

## Świadomie pominięte (YAGNI)

Powiadomienia ntfy, plik logu, sidecar w compose, samodzielna demonizacja.
