# Pre-commit hooks

Repozytorium używa [pre-commit](https://pre-commit.com/) z następującymi hookami:

- **trailing-whitespace**, **end-of-file-fixer** — formatowanie
- **check-yaml** — walidacja YAML
- **check-merge-conflict** — wykrywanie konfliktów merge
- **detect-private-key** — blokada kluczy prywatnych
- **shellcheck** — linter bash
- **TruffleHog** — wykrywanie sekretów i haseł

## Instalacja

```bash
pip install pre-commit
pre-commit install
```

Od tej chwili hooki uruchamiają się automatycznie przy każdym `git commit`. Ręcznie na
całym repo:

```bash
pre-commit run --all-files
```

CI uruchamia te same hooki (`.github/workflows/ci.yml`, job `pre-commit`).

## Dokumentacja MkDocs

Jeśli edytujesz dokumentację, zweryfikuj ją lokalnie przed commitem:

```bash
pip install -r docs/requirements.txt
mkdocs build --strict   # wykrywa zepsute linki i braki w nav
mkdocs serve            # podgląd na http://127.0.0.1:8000
```

Zasady, gdzie umieszczać treść (README vs `docs/` vs `CLAUDE.md`), opisuje skill
`docs-sync` w `.claude/skills/docs-sync/`.
