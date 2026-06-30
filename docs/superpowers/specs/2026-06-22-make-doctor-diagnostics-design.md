# Spec: rozłączenie deployu od testów + `make doctor`

Data: 2026-06-22

## Problem

Po **każdym** deployu (`make run`) wysyłane są testowe e-maile i odpalany jest
test Rollbara. To uciążliwe — zalewa skrzynkę i Rollbar przy każdej aktualizacji
(`git pull && make up`/`make run`). Operator chce **wybierać**, co i kiedy
przetestować, zamiast dostawać to automatycznie.

Dodatkowo `test-email` jest sztywno spięty z `test-rollbar` (wywołuje go na
końcu), więc nie da się przetestować samego maila.

## Cel

1. `make run` **nie** wysyła już automatycznie maili ani nie testuje Rollbara.
2. Każdy test robi **dokładnie jedną rzecz** (rozłączenie mail↔rollbar).
3. Istnieje tryb diagnostyczny `make doctor` — interaktywne menu, z którego
   operator wybiera, co przetestować.

## Stan obecny (przed zmianą)

- `mk/deployment.mk:90` — `run: pull build update-configs up test-email`
  (deploy kończy się testem maila + Rollbara).
- `mk/django.mk:23` — `test-email` wysyła 2 maile **i** woła `$(MAKE) test-rollbar`
  (linia 30) — sprzężenie.
- `mk/django.mk:32` — `test-rollbar` (samodzielny).
- `mk/monitoring.mk:13` — `ntfy-test` (już istnieje; nazwa niesymetryczna do
  `test-email`/`test-rollbar`).
- `mk/deployment.mk:80` — `health` (status usług + ostatnie błędy).
- `mk/rclone.mk:25` — `backup-cycle` (pełny cykl: pg_dump + tar media + rotacja +
  rclone sync + Rollbar notify).

## Zmiany

### 1. `make run` przestaje auto-testować

`mk/deployment.mk`:

```make
run: pull build update-configs up
	@echo "Deploy zakończony. Diagnostyka powiadomień/usług: make doctor"
```

Hint zastępuje cicho znikające stare zachowanie — kierując operatora na ścieżkę
on-demand.

### 2. Rozłączenie trzech testów

`mk/django.mk`:

- `test-email` traci ogon `$(MAKE) test-rollbar` (linia 30) — wysyła tylko dwa
  testowe maile. Strażnik `DJANGO_BPP_ADMIN_EMAIL` zostaje.
- `test-rollbar` bez zmian.

### 3. `test-ntfy` (kanoniczny) + `ntfy-test` jako deprecated alias

Symetria nazw (`test-email`/`test-rollbar`/`test-ntfy`). Bo `ntfy-test` już
istnieje i jest w `make help` (i potencjalnie w skryptach/pamięci operatora),
**kontrakt backwards-compat** wymaga zachowania starej nazwy:

`mk/monitoring.mk`:

- przemianować ciało `ntfy-test` na `test-ntfy` (kanoniczny target),
- dodać `ntfy-test: test-ntfy` jako cienki, deprecated alias.
- `.PHONY` zaktualizować o `test-ntfy`.

### 4. `make doctor` — interaktywne menu

Nowy `scripts/doctor.sh` (zgodny z konwencją repo `scripts/*.sh` + testy w
`tests/`). Pętla `select`:

```
=== BPP doctor — diagnostyka ===
  1) mail     — wyślij testowe e-maile (test-email)
  2) ntfy     — wyślij testowy push  (test-ntfy)
  3) rollbar  — wyślij testowe zdarzenie (test-rollbar)
  4) health   — status usług + ostatnie błędy (health)
  5) backup   — pełny cykl backupu: pg_dump+media+rclone+rollbar (backup-cycle)
  6) wszystko — odpal mail+ntfy+rollbar po kolei
  q) wyjście
Wybierz:
```

Zasady:

- Każdy wybór woła z powrotem do `make` (`make test-email`, `make test-ntfy`,
  `make test-rollbar`, `make health`, `make backup-cycle`). **Single source of
  truth** — strażniki env (`DJANGO_BPP_ADMIN_EMAIL`, `ROLLBAR_ACCESS_TOKEN`,
  `NTFY_TOPIC`) i komendy docker żyją w jednym miejscu (w celach make), nie są
  duplikowane w skrypcie.
- "wszystko" (6) = **mail + ntfy + rollbar** (trio powiadomień; dawne
  post-deploy zachowanie, ale na żądanie). **Nie** obejmuje health/backup —
  health jest read-only podglądem, a backup-cycle jest ciężki (rotacja + sync),
  więc świadomie poza zbiorczym "wszystko".
- Jeśli pojedynczy test zawiedzie (np. brak env), menu wraca do listy i działa
  dalej; nie przerywa pętli (poza `q`).
- `q` / Ctrl-D kończy.

Cel w Makefile — nowy plik `mk/doctor.mk` (łączy domeny
django+monitoring+rclone, dedykowany plik jest czystszy):

```make
.PHONY: doctor test-doctor
doctor:
	@bash scripts/doctor.sh
test-doctor:
	@bash scripts/test-doctor.sh
```

**KRYTYCZNE — brak glob-include.** Główny `Makefile` dołącza każdy `mk/*.mk`
ręcznie wypisaną linią `include`, w dwóch blokach: normalny tryb (Makefile:63-74:
deployment, database, shell, logs, celery, configs, docker, django, rclone, ssl,
misc, version) oraz „oba tryby" po `endif` (Makefile:177-179: init, remote,
monitoring). Nowy `mk/doctor.mk` **musi** dostać jawną linię `include
mk/doctor.mk` — dodać do bloku normalnego trybu (63-74), bo `doctor` zależy od
celów env-driven i nie powinien działać w first-run.

#### Tryb nieinteraktywny (testowalność)

`scripts/doctor.sh` przyjmuje opcjonalny argument:
`doctor.sh mail|ntfy|rollbar|health|backup|all` → uruchamia daną pozycję
nieinteraktywnie i kończy (exit code z podrzędnego `make`). Bez argumentu →
menu interaktywne. Dzięki temu da się napisać unit-test w `tests/`
(mockując `make`) i power-userzy mogą pominąć menu.

Walidacja argumentu: nieznany argument → komunikat błędu + lista dozwolonych +
`exit 2`.

### 5. Synchronizacja docs/help (skill `docs-sync`)

- `make help` (Makefile:128,166-167): wylistować `test-email`, `test-rollbar`,
  `test-ntfy`, `doctor`; usunąć dopisek „(also runs test-rollbar)" przy
  `test-email`; `ntfy-test` oznaczyć jako deprecated alias albo usunąć z help
  (zostawić tylko `test-ntfy`).
- `docs/` (monitoring + komendy): odnotować, że deploy **nie** wysyła już
  automatycznie powiadomień, a `make doctor` jest punktem wejścia do
  diagnostyki. Po edycji `mkdocs build --strict`.

## Poza zakresem (YAGNI)

- Brak nowych testów merytorycznych (samo menu + rozłączenie istniejących).
- Brak zmian w logice `backup-cycle`/`health`/`test_rollbar`/`sendtestemail`.

## Testowanie / weryfikacja

- `scripts/test-doctor.sh` (NIE `tests/` — per-script testy żyją w `scripts/`
  jako `scripts/test-*.sh` z własnym celem make, wzorzec mock-PATH jak
  `scripts/test-letsencrypt.sh`: `mktemp -d` root, `mock-bin/` ze stubem `make`
  logującym argumenty, prepend do PATH, `set -euo pipefail`, liczniki
  `pass/fail`, `trap cleanup EXIT`). Test sprawdza: dla każdego argumentu
  (`mail|ntfy|rollbar|health|backup|all`) `scripts/doctor.sh <arg>` woła właściwy
  cel make; nieznany argument → exit 2. Cel `make test-doctor` w `mk/doctor.mk`.
  Uwaga: CI (`.github/workflows/ci.yml`) uruchamia tylko `tests/test_makefile.sh`,
  NIE `scripts/test-*.sh` — `test-doctor` zostaje spójny z resztą (uruchamiany
  ręcznie/lokalnie, jak `test-letsencrypt`, `test-docker-versions`).
- `make doctor` ręcznie: menu się wyświetla, wybór odpala właściwy cel, `q` kończy.
- `grep` że `test-email` nie zawiera już `$(MAKE) test-rollbar`.
- `grep` że `run:` nie zawiera `test-email`.
- `make ntfy-test` nadal działa (alias).
- `mkdocs build --strict` przechodzi.

## Kontrakt backwards-compat

- `ntfy-test` zachowane jako deprecated alias → stare skrypty/pamięć działają.
- Brak zmian w nazwach zmiennych `.env`.
- `make run` ma węższy zakres, ale to zamierzone i pożądane przez operatora;
  hint kieruje na `make doctor`.
