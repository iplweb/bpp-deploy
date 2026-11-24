# Zgłaszanie błędów: Rollbar i GlitchTip

BPP zgłasza błędy aplikacji (wyjątki w widokach, zadaniach Celery, importach)
do zewnętrznego systemu. Obsługiwane są dwa, **niezależnie od siebie**:

| System | Zmienna w `$BPP_CONFIGS_DIR/.env` | Uwagi |
|---|---|---|
| [Rollbar](https://rollbar.com) | `ROLLBAR_ACCESS_TOKEN` | usługa płatna (SaaS) |
| [GlitchTip](https://glitchtip.com) / Sentry | `SENTRY_DSN` | GlitchTip to lekki odpowiednik Sentry, do postawienia na własnym serwerze; przyjmuje protokół Sentry |

Każdy kanał działa, gdy jego zmienna jest ustawiona. Można włączyć oba naraz:
każdy błąd trafia wtedy do obu systemów. Służy to do okresu przejściowego.
Żeby wyłączyć któryś system, **usuń jego zmienną** z `.env` i zrób `make up`.

!!! note "Wymagana wersja obrazu"
    Błędy aplikacji do GlitchTipa wysyła obraz BPP z wbudowaną biblioteką
    zgłaszania błędów (Rollbar + `sentry-sdk`). Starsze obrazy ignorują
    `SENTRY_DSN` i zgłaszają wyłącznie do Rollbara.
    Notyfikacje **nocnego backupu** do GlitchTipa działają na każdym obrazie
    (patrz niżej).

## Konfiguracja GlitchTip

1. W GlitchTipie utwórz projekt (platforma *Django*) i skopiuj jego DSN
   (*Settings → Client Keys*).
2. Dopisz do `$BPP_CONFIGS_DIR/.env`:

    ```bash
    SENTRY_DSN=https://<klucz>@glitchtip.example.pl/1
    # opcjonalnie:
    # SENTRY_ENVIRONMENT=production       # domyślnie jak w Rollbarze (production/staging)
    # SENTRY_TRACES_SAMPLE_RATE=0         # śledzenie wydajności, domyślnie wyłączone
    ```

3. `make up` (zmienna trafia do kontenerów przy ich tworzeniu).
4. `make test-sentry` wysyła testowe zdarzenie. W GlitchTipie powinno się pojawić
   zgłoszenie „make test-sentry: test notyfikacji z …”. To samo robi pozycja **sentry** w `make doctor`.

`SENTRY_DSN` jest w [rejestrze zmiennych operatora](../konfiguracja/zmienne.md)
(grupa *Powiadomienia*). `make up` o nią nie pyta, ustawiasz ją przez
`make configure` albo ręcznie w `.env`.

## Notyfikacje nocnego backupu

Cykl backupu (`scripts/backup-cycle.sh`) wysyła wynik (sukces albo błąd z końcówką
logu) do **każdego** skonfigurowanego kanału: Rollbara i GlitchTipa. Zdarzenie
GlitchTipa ma `logger`/tag `component` = `backup-cycle`, a jako environment
identyfikator hosta.

Wysyłka idzie, tak jak w przypadku Rollbara, przez `docker exec appserver python`
(orkiestrator nie ma `curl`). Program (`scripts/sentry-store.py`) korzysta tylko
z biblioteki standardowej Pythona, więc działa na każdym obrazie appservera.
Ten sam program obsługuje `make test-sentry`.
Nieudana notyfikacja **nigdy** nie zmienia wyniku backupu.

DSN appserver czyta ze swojego `env_file`. Po dopisaniu `SENTRY_DSN` do `.env`
potrzebny jest `make up`. Bez niego log cyklu pokaże
`sentry: skip (brak SENTRY_DSN w appserverze …)`.

## Przejście z Rollbara na GlitchTip

1. Ustaw `SENTRY_DSN` obok istniejącego `ROLLBAR_ACCESS_TOKEN`, potem `make up`.
2. Przez kilka tygodni porównuj, czy oba systemy dostają te same błędy.
3. Usuń `ROLLBAR_ACCESS_TOKEN` z `.env` i zrób `make up`. Od tej chwili
   zgłoszenia trafiają wyłącznie do GlitchTipa.
