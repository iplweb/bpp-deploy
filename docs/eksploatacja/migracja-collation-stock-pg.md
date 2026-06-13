# Migracja bazy na stockowy postgres — pozbycie się kolacji libc `pl_PL`

Przy przejściu z obrazu `iplweb/bpp_dbserver` na **stockowy `postgres`** (np.
przy okazji upgrade'u majora do 18) istniejącego klastra **nie da się przełączyć
w miejscu**. Trzeba zrobić logical dump → usunąć kolację → załadować do świeżego
klastra. Ten dokument opisuje gotowy 3-krokowy zestaw skryptów.

## Dlaczego w ogóle

Stary obraz `iplweb/bpp_dbserver` dorzucał ponad stockowego postgresa **dwie**
rzeczy: autotune **oraz** wygenerowane locale libc `pl_PL.UTF-8`
(`RUN localedef … pl_PL.UTF-8` + `ENV LANG=pl_PL.utf-8`). Oficjalny obraz
`postgres` ma tylko `en_US.UTF-8` i `C.UTF-8`. Konsekwencje:

1. **Istniejący klaster nie wstanie** na stockowym obrazie — `postgresql.conf`
   ma `lc_messages/lc_monetary/lc_numeric/lc_time = pl_PL.utf-8`, a
   `pg_database.datcollate/datctype = pl_PL.utf-8`. Stock postgres rzuca
   `FATAL: … invalid value for parameter "lc_messages": "pl_PL.utf-8"`.
2. **Zrzut z `CREATE COLLATION … libc pl_PL.UTF-8`** (migracja bpp
   `0001_collation`) nie wczyta się na czystym obrazie.

Kolacja `pl_PL` była używana wyłącznie na **stałych literałach ASCII**
(`'bpp_patent'::text COLLATE "pl_PL"`) w 5 widokach `bpp_kronika_*_view` i
propagowała się do `bpp_kronika_all_unsorted_view` → `bpp_kronika_view`. Dla
sortowania to **no-op**, więc usuwamy ją bezpiecznie. W kodzie BPP robi to
migracja `0443_drop_pl_PL_collation`; tutaj usuwamy ją ze **zrzutu**.

## Wymagania wstępne

- **Wdrożona wersja aplikacji z migracją `0442_drop_plpython3u`** (i najlepiej
  `0443_drop_pl_PL_collation`). Bez 0442 zrzut nadal zawiera `plpython3u`,
  którego stock postgres nie ma — load padnie. Skrypt kroku 2 **ostrzeże**,
  jeśli wykryje plpython.
- Docelowa wersja Postgresa ustawiona w `$BPP_CONFIGS_DIR/.env`
  (`DJANGO_BPP_POSTGRESQL_VERSION=18.x`) i `docker-compose.database.yml`
  używający stockowego `postgres` z
  `POSTGRES_INITDB_ARGS=--locale-provider=icu --icu-locale=pl-PL`.
- Działający Docker + miejsce na zrzut.

## Procedura

> Kolejność jest istotna: **najpierw** zrzuć ze starego (działającego) klastra,
> **potem** wymień obraz na stock. Stary klaster ma locale libc, więc i dump, i
> ewentualna migracja 0443 wykonają się bez problemu.

### 0. Zatrzymaj zapisy

```bash
docker compose stop appserver workerserver celerybeat denorm-queue
```

(albo użyj `--stop-app` w kroku 1).

### 1. Zrzut bieżącego klastra (stary obraz)

```bash
make migrate-collation-dump
# lub:  bash scripts/pg-collation-migrate-1-dump.sh --stop-app
```

Wypisze ścieżkę do zrzutu, np.
`/…/backups/db-backup-20260613-190000.sql` (plain SQL `pg_dump -Fp`, **bez
gzipa** — sam w sobie ładowalny backup). Jeśli na hoście jest `pv`, leci pasek
postępu.

### 2. Usuń kolację `pl_PL` ze zrzutu

```bash
make migrate-collation-fix DUMPSQL=/…/backups/db-backup-20260613-190000.sql
# lub:  bash scripts/pg-collation-migrate-2-fix.sh <…sql>
```

Czysta transformacja tekstu na hoście — `sed` in → out, bez gzipa, bez
`pg_restore`, bez obrazu postgres, bez tar. Wycina
`CREATE/ALTER/COMMENT … COLLATION … pl_PL` oraz klauzule `COLLATE pl_PL`,
i zapisuje `…-nocollation.sql`. **Nazwa kolacji jest case-insensitive i może
być w cudzysłowie lub bez** — realne bazy mają `public.pl_pl` (małe litery,
`locale='pl_PL.utf8'`), nie `"pl_PL"`. Weryfikuje brak pozostałości i ostrzega
o plpython. Jest **idempotentny** — jeśli zrzut był już zrobiony po migracji
0443 (bez kolacji), po prostu nic nie znajdzie.

### 3. Załaduj do świeżego klastra psql 18

Najpierw postaw **świeży** klaster na nowym obrazie. Albo przez istniejący
`make upgrade-postgres`, albo pozwól zrobić to skryptowi (`--recreate-volume`):

```bash
make migrate-collation-load SQL=/…/backups/db-backup-20260613-190000-nocollation.sql RECREATE=1
# lub:  bash scripts/pg-collation-migrate-3-load.sh <…-nocollation.sql> --recreate-volume
```

`--recreate-volume` zatrzyma aplikację + dbserver, **usunie** volume
`${COMPOSE_PROJECT_NAME}_postgresql_data` (DESTRUKCYJNE — pyta o potwierdzenie!),
wstanie dbserver na nowym obrazie (initdb z ICU pl-PL), po czym `dropdb`+
`createdb`+`psql` (z paskiem `pv`, jeśli jest). Bez `--recreate-volume` zakłada,
że dbserver już chodzi na stockowym obrazie na pustym volume.

### 4. Domigruj i wstań

```bash
make migrate        # zastosuje 0443 (no-op, kolacji już nie ma) i resztę
make up
```

## Weryfikacja

```bash
# Brak kolacji w schemacie publicznym (oczekiwane: 0):
make dbshell-psql   # potem:
#   SELECT count(*) FROM pg_collation c JOIN pg_namespace n ON n.oid=c.collnamespace
#     WHERE c.collname='pl_PL' AND n.nspname='public';
# Widoki kroniki działają:
#   SELECT count(*) FROM bpp_kronika_view;
# Baza jest ICU:
#   SELECT datlocprovider FROM pg_database WHERE datname=current_database();  -- 'i'
```

## Uwagi i ograniczenia

- **Cały pipeline jest plain SQL, bez gzipa** (dump `-Fp` → `sed` → `psql`), bo
  kolację trzeba wyciąć z **tekstu** definicji widoków (`COLLATE pl_PL`), czego
  format katalogowy/custom (binarny `toc.dat`) nie pozwala zrobić bez konwersji
  `pg_restore -f -`. Load i tak jest jednowątkowy (`psql`), więc równoległość
  `pg_restore -Fd -j` nic by tu nie dała — dlatego żaden binarny pośrednik nie
  jest potrzebny. Brak (de)kompresji jest też trochę szybszy (kosztem miejsca na
  nieskompresowany `.sql`). Dla bardzo dużych baz dump/load jest sekwencyjny, ale
  to operacja jednorazowa.
- **Nazwa kolacji jest case-insensitive** (`[pP][lL]_[pP][lL]`), z opcjonalnym
  `public.` i cudzysłowem. Realne bazy mają `public.pl_pl` (małe litery,
  `locale='pl_PL.utf8'`), a nie `"pl_PL"` z `0001_collation` — wzorzec łapie oba.
  Migracja bpp `0443` dropuje tylko `"pl_PL"`, więc dla ścieżki dump→restore to
  `sed` (a nie migracja) gwarantuje usunięcie `pl_pl`.
- **`make backup` wciąż działa ze starym obrazem** — obrazy `iplweb/bpp_dbserver`
  są nadal na Docker Hubie, więc dump da się zrobić nawet po decyzji o migracji.
- Skrypt kroku 3 **odmówi** załadowania do kontenera nadal działającego na
  `iplweb/bpp_dbserver` (ładowałbyś do starego klastra, nie do psql 18).
- Pozostała po migracji systemowa kolacja `pg_catalog.pl_PL` (auto-import z
  `locale -a` przy initdb) jest nieszkodliwa — `pg_dump` jej nie zrzuca, a na
  stockowym obrazie i tak nie powstaje.
```
