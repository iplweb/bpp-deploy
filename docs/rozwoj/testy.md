# Testy

!!! info "Zakres"
    Ta sekcja dotyczy wyłącznie rozwoju **`bpp-deploy`** — orkiestracji Docker Compose,
    Makefile, skryptów konfiguracyjnych i monitoringu.

    Rozwój **samej aplikacji BPP** (kod Django w `/src/`, modele, widoki, importery,
    integracje z PBN, ORCID itd.) odbywa się w osobnym repozytorium
    [github.com/iplweb/bpp](https://github.com/iplweb/bpp).

## Uruchamianie

```bash
./tests/test_makefile.sh
```

Testy weryfikują orkiestrację `bpp-deploy`:

- first-run setup (tworzenie konfiguracji, generowanie haseł)
- idempotentność `init-configs`
- losowość haseł między instancjami
- dostępność targetów Make w trybie normalnym
- poprawność bind mountów w docker-compose
- brak mechanizmów SCP w konfiguracji

## CI

`.github/workflows/ci.yml` uruchamia testy na **Ubuntu, Windows i macOS** (`make` działa
na wszystkich trzech), plus pre-commit i walidację składni `docker-compose*.yml`.

Dokumentacja (ta strona) jest budowana i publikowana osobnym workflow
`.github/workflows/docs.yml` (build `--strict` + `mkdocs gh-deploy` na push do `main`).
