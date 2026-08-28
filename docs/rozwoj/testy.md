# Testy

!!! info "Zakres"
    Ta sekcja dotyczy wyłącznie rozwoju **`bpp-deploy`** — orkiestracji Docker Compose,
    Makefile, skryptów konfiguracyjnych i monitoringu.

    Rozwój **samej aplikacji BPP** (kod Django w `/src/`, modele, widoki, importery,
    integracje z PBN, ORCID itd.) odbywa się w osobnym repozytorium
    [github.com/iplweb/bpp](https://github.com/iplweb/bpp).

## Uruchamianie

```bash
./tests/test_makefile.sh          # główny zestaw (orkiestracja, konfiguracja)
./scripts/test-config-path.sh     # ścieżka katalogu konfiguracyjnego (szybki, bez Dockera)
./scripts/test-grafana-datasources.sh  # render datasources.yaml bez gettexta
```

Testy weryfikują orkiestrację `bpp-deploy`:

- first-run setup (tworzenie konfiguracji, generowanie haseł)
- idempotentność `init-configs`
- losowość haseł między instancjami
- dostępność targetów Make w trybie normalnym
- poprawność bind mountów w docker-compose
- brak mechanizmów SCP w konfiguracji
- walidację ścieżki katalogu konfiguracyjnego (katalog obok repozytorium ma być
  przyjęty, katalog w środku — odrzucony, ścieżka windowsowa `C:\...` przyjęta)

`scripts/test-grafana-datasources.sh` uruchamia render datasource'ów Grafany z `PATH`
pozbawionym `envsubst`. Renderowanie szablonów po stronie hosta **nie może** zależeć od
gettexta — Windows go nie ma, a `update-configs` jest prerequisite `make up`, więc taka
zależność wywracała każdy deploy, nie tylko instalację.

`scripts/test-config-path.sh` to unit-testy samej normalizacji ścieżki
(`scripts/lib-config-path.sh`). Windows jest w nich symulowany atrapami `cygpath`
i `uname` w `PATH`, dzięki czemu regresja „każda ścieżka odrzucana pod Windows"
wychodzi na każdym systemie, a nie dopiero na runnerze Windows.

## CI

`.github/workflows/ci.yml` uruchamia testy na **Ubuntu, Windows i macOS** (`make` działa
na wszystkich trzech), plus pre-commit i walidację składni `docker-compose*.yml`.

Dokumentacja (ta strona) jest budowana i publikowana osobnym workflow
`.github/workflows/docs.yml` (build `--strict` + `mkdocs gh-deploy` na push do `main`).
