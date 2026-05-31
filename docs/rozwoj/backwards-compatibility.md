# Backwards compatibility i migracje `.env`

!!! danger "Zasada krytyczna"
    Nowa wersja `bpp-deploy` **musi** działać na **starym** `$BPP_CONFIGS_DIR/.env` bez
    ręcznej edycji. Produkcyjne wdrożenia aktualizują się przez `git pull && make up` —
    każdy wymagany krok ręczny to potencjalny outage.

Dotyczy to:

- **Zmiany nazw zmiennych** (np. `DJANGO_BPP_BACKUP_DIR` → `DJANGO_BPP_HOST_BACKUP_DIR`,
  `DJANGO_BPP_DBSERVER_PG_VERSION` → `DJANGO_BPP_POSTGRESQL_VERSION`)
- **Dodawania nowych zmiennych z defaultem Compose** — dwupoziomowy fallback typu
  `${DJANGO_BPP_POSTGRESQL_VERSION:-${DJANGO_BPP_DBSERVER_PG_VERSION:-16.13}}` utrzymuje
  stare `.env` przy życiu, nowe dostają wartość z `init-configs`, default jako ostatnia deska
- Zmiany semantyki istniejących zmiennych; nowych zmiennych wymaganych; restrukturyzacji
  katalogów konfiguracyjnych

## Obowiązkowa ochrona dwuwarstwowa

### 1. Fallback w czytniku

Makefile/skrypty muszą akceptować starą nazwę jako alternatywę. Działa od razu po
`git pull`, bez akcji użytkownika:

```makefile
ifdef OLD_VAR
NEW_VAR := $(OLD_VAR)
endif
```

### 2. Migracja w `scripts/init-configs.sh`

Gdy użytkownik uruchomi `make init-configs` (zalecane po każdym upgrade), wykryj starą
nazwę i zmień ją w `.env`, zachowując wartość:

```bash
if env_has_var "OLD_NAME" && ! env_has_var "NEW_NAME"; then
    _val="$(get_env_var OLD_NAME)"
    awk '!/^OLD_NAME=/ && !/^# Dopisano automatycznie.*OLD_NAME/' "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
        && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
    set_env_var "NEW_NAME" "$_val" "Komentarz (migracja z OLD_NAME)"
    echo "  ~ zmigrowalem OLD_NAME -> NEW_NAME"
fi
```

Helpery w `init-configs.sh`: `env_has_var`, `get_env_var` (zdejmuje cudzysłowy),
`set_env_var` (nadpisz lub dopisz). Stabilne sygnatury — używaj ich zamiast własnego
`grep`/`sed`.

## Czego NIE robić

- Dodawać nowej wymaganej zmiennej bez defaultu Compose (`${VAR:-default}`) i bez migracji
- Usuwać starej zmiennej bez migracji, nawet jeśli „nikt jej nie powinien używać"
- Zakładać, że użytkownik czyta release notes i ręcznie edytuje `.env`
- Łamać kompatybilność w pół wydania (zawsze najpierw: nowa nazwa + fallback + migracja;
  starą nazwę usuwaj dopiero po latach)
