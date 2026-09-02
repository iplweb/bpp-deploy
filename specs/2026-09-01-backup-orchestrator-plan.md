# Orkiestrator backupu — plan wdrożenia

> **Dla agentów wykonawczych:** WYMAGANY SUB-SKILL: `superpowers:subagent-driven-development`
> (zalecany) albo `superpowers:executing-plans`. Kroki mają checkboxy (`- [ ]`).

**Cel:** Zamienić `backup-runner` z kontenera doinstalowującego narzędzia przez
`apt-get` w orkiestrator na `docker:cli`, który sekwencjonuje cykl, a ciężkie kroki
wykonuje przez `docker exec` w kontenerach mających właściwe narzędzia.

**Architektura:** Dwa serwisy — `backup-runner` (`docker:cli`, ma `docker.sock`,
`/backup`, media `:ro`, config rclone `:ro`) i `rclone` (`rclone/rclone`, bezczynny,
ma config RW i `/backup` `:ro`). `backup-cycle.sh` zostaje jednym skryptem z jedną
sekwencją i jednym raportem; woła `docker exec` do `dbservera` (pg_dump), do `rclone`
(wysyłka i retencja) i do `appservera` (notyfikacja Rollbar).

**Stack:** Docker Compose, POSIX sh / busybox ash, Ofelia, rclone, PostgreSQL.

**Spec:** `specs/2026-09-01-backup-orchestrator-design.md` — czytaj razem z tym planem.

> Plan leży w `specs/`, a nie w `docs/superpowers/plans/`, bo `docs/` w tym repo to
> publikowany serwis MkDocs z jawną nawigacją.

## Globalne ograniczenia

- **Kompatybilność wsteczna jest kontraktem.** Nowa wersja repo musi działać na
  **starym** `$BPP_CONFIGS_DIR/.env` bez ręcznej edycji. Każda nowa zmienna ma default
  w compose. Szczegóły: `docs/rozwoj/backwards-compatibility.md`.
- **Każdy `$` przeznaczony dla powłoki w compose (`command:`, `entrypoint:`,
  `healthcheck:`, labele Ofelii) musi być `$$`.** Weryfikuje to
  `test_compose_shell_vars_escaped` na wyrenderowanym `docker compose config`,
  nie na źródle YAML.
- **Każdy nowy serwis dostaje `logging: *default-logging`** — anchor nie przekracza
  granicy `include:`, `docker-compose.backup.yml` ma własny.
- **Nigdy `rclone sync` do katalogu miesięcznego — wyłącznie `copy`.**
- **Nigdy `head -1` w potoku pod `pipefail`** — producent dostaje SIGPIPE i wywraca
  cykl. Zamiast tego `sed -n '1p'`.
- **`DJANGO_BPP_RCLONE_KEEP_MONTHS` czytamy przez `${VAR-12}`, nie `${VAR:-12}`** —
  pusta wartość musi wyłączać retencję.
- Komentarze w kodzie po polsku, bez polskich znaków diakrytycznych (konwencja repo).
- Po każdym zadaniu: `pre-commit run --files <zmienione>` musi przejść.

---

### Zadanie 1: Skrypty zgodne z busybox ash (compose nietknięty)

Najpierw, bo jako jedyne da się zweryfikować **bez** ruszania produkcyjnej ścieżki
backupu. Po tym zadaniu skrypty działają identycznie jak dziś na dzisiejszym
`backup-runnerze` (obraz `postgres`, Debian) **i** są gotowe na busyboksa.

**Pliki:**
- Modify: `scripts/backup-cycle.sh`
- Modify: `scripts/rclone-sync.sh`
- Modify: `scripts/rclone-config.sh`
- Modify: `scripts/lib-rclone.sh:55-58` (`_ym_index`)
- Test: `scripts/test-rclone.sh`

**Interfejsy:**
- Produces: skrypty uruchamialne pod busybox ash; funkcja `on_exit` i zmienna
  `BPP_INTENDED_EXIT` w `backup-cycle.sh`; niezmieniona sygnatura `_ym_index <YYYY-MM>`.
- Consumes: nic.

- [ ] **Krok 1: Test — cykl uruchamia się pod busybox ash**

Dopisz w `scripts/test-rclone.sh` nową sekcję (przed blokiem podsumowania):

```bash
# ==========================================================================
# 6. Skrypty uruchamiaja sie pod busybox ash (docelowe obrazy nie maja basha)
# ==========================================================================
echo
echo "6. Uruchomienie pod busybox ash"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "  SKIP: brak dzialajacego dockera"
else
    ASH_IMAGE="${BPP_ASH_TEST_IMAGE:-docker:cli}"
    ash_bin="$TEST_ROOT/ash-bin"
    mkdir -p "$ash_bin"
    # Atrapy: skrypt ma dojsc do konca bez prawdziwej bazy i bez sieci.
    for t in pg_dump rclone curl jq; do
        printf '#!/bin/sh\nexit 0\n' > "$ash_bin/$t"
        chmod +x "$ash_bin/$t"
    done
    ash_work="$TEST_ROOT/ash-work"
    mkdir -p "$ash_work/backup" "$ash_work/media" "$ash_work/config"
    printf '[backup_enc]\ntype = local\n' > "$ash_work/config/rclone.conf"

    ash_rc=0
    docker run --rm \
        -v "$REPO_DIR/scripts:/scripts:ro" \
        -v "$ash_bin:/stub:ro" \
        -v "$ash_work:/work" \
        -e "PATH=/stub:/usr/local/bin:/usr/bin:/bin" \
        -e BPP_BACKUP_DIR=/work/backup \
        -e BPP_MEDIA_DIR=/work/media \
        -e BPP_RCLONE_CONFIG=/work/config/rclone.conf \
        -e BPP_BACKUP_LOG=/work/backup-cycle.log \
        -e DJANGO_BPP_DB_HOST=db -e DJANGO_BPP_DB_PORT=5432 \
        -e DJANGO_BPP_DB_USER=u -e DJANGO_BPP_DB_NAME=n \
        -e DJANGO_BPP_RCLONE_KEEP_MONTHS=0 \
        "$ASH_IMAGE" /scripts/backup-cycle.sh >/dev/null 2>&1 || ash_rc=$?
    assert_eq "0" "$ash_rc" "backup-cycle.sh dochodzi do konca pod busybox ash"

    for s in rclone-sync.sh rclone-config.sh; do
        head_rc=0
        docker run --rm -v "$REPO_DIR/scripts:/scripts:ro" "$ASH_IMAGE" \
            sh -c "head -1 /scripts/$s | grep -q '^#!/bin/sh$'" || head_rc=$?
        assert_eq "0" "$head_rc" "$s ma shebang #!/bin/sh"
    done
fi
```

- [ ] **Krok 2: Uruchom test i potwierdź, że pada**

Run: `bash scripts/test-rclone.sh 2>&1 | tail -20`
Expected: FAIL — `backup-cycle.sh dochodzi do konca pod busybox ash` (rc=127,
`env: can't execute 'bash'`) oraz oba FAIL-e o shebangu.

- [ ] **Krok 3: Shebang i preflight we wszystkich trzech skryptach**

W `scripts/backup-cycle.sh`, `scripts/rclone-sync.sh`, `scripts/rclone-config.sh`
zamień pierwszą linię na `#!/bin/sh`, a **bezpośrednio przed** `set -Eeuo pipefail`
(albo `set -euo pipefail`) wstaw:

```sh
# Docelowe obrazy (docker:cli, rclone/rclone) nie maja basha, wiec shebang musi byc
# /bin/sh. Ale na Debianie /bin/sh to dash, ktory NIE zna `pipefail` - a na nim stoja
# kontrakty o SIGPIPE w tym repo. Wiec: jesli powloka nie ma pipefail, przeskakujemy
# na basha; jesli basha tez nie ma, gliniemy z czytelnym komunikatem zamiast dziwnie.
if ! (set -o pipefail) 2>/dev/null; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "BLAD: ten skrypt wymaga powloki z pipefail (busybox ash albo bash)." >&2
    echo "      dash jej nie ma - uruchom przez bash albo wewnatrz kontenera." >&2
    exit 1
fi
```

Następnie zamień `set -Eeuo pipefail` na:

```sh
set -eu
set -o pipefail
```

(`-E` służyło wyłącznie propagacji `trap ERR`, który znika w kroku 5.)

Na końcu nagłówka każdego z trzech plików dopisz dyrektywy shellchecka:

```sh
# shellcheck shell=sh
# shellcheck disable=SC3040  # `set -o pipefail`: swiadome odstepstwo od POSIX.
#   Busybox ash i bash je maja, dash nie - stad preflight wyzej. Kontrakty
#   o SIGPIPE (patrz lib-rclone.sh) bez pipefail przestaja obowiazywac.
```

- [ ] **Krok 4: Uruchom test — shebangi zielone, cykl nadal czerwony**

Run: `bash scripts/test-rclone.sh 2>&1 | tail -20`
Expected: oba asserty o shebangu PASS; `dochodzi do konca pod busybox ash` nadal FAIL
(zostały bashizmy w środku, patrz kroki 5-7).

- [ ] **Krok 5: `trap ERR` → `trap EXIT` z guardem**

W `scripts/backup-cycle.sh` usuń `trap 'fail "unexpected-error" 1' ERR` (linia ~113)
oraz `trap - ERR` z `fail()` (linia ~97). W to miejsce, **przed** pierwszym krokiem
cyklu, wstaw:

```sh
# Zamiennik `trap ERR` (bashizm). trap EXIT lapie takze abort z `set -e`, w tym
# w funkcjach - czyli pokrywa wiecej niz ERR bez `-E`.
#
# KRYTYCZNE: kazda komenda w tej sciezce ma `|| true`. Blad wewnatrz trapa urywa go
# w polowie, `exit "$rc"` nie zostaje osiagniety i kod wyjscia zostaje sklobrowany
# na 1 - a notyfikacja idzie przez `docker exec appserver`, ktory pada dokladnie
# wtedy, gdy appserver lezy, czyli w scenariuszu, o ktorym raportujemy.
BPP_INTENDED_EXIT=0

on_exit() {
    rc=$?
    if [ "$BPP_INTENDED_EXIT" = 1 ]; then exit "$rc"; fi
    BPP_INTENDED_EXIT=1
    log "FAIL: unexpected-error (exit=$rc)" || true
    notify_rollbar error "Backup FAIL on ${DJANGO_BPP_HOSTNAME:-unknown}: step=unexpected-error exit=$rc" || true
    exit "$rc"
}
trap on_exit EXIT

# Smierc `tee` z przekierowania logu dawalaby SIGPIPE, rc=141, BEZ trapa EXIT
# i bez notyfikacji. Zignorowanie sygnalu zamienia to w zwykly blad zapisu,
# ktory `set -e` skieruje do on_exit.
trap '' PIPE
```

W `fail()` zamień `trap - ERR` na `BPP_INTENDED_EXIT=1` (musi być **pierwszą**
instrukcją funkcji, przed `log` i `notify_rollbar` — inaczej błąd notyfikacji wpadnie
z powrotem w `on_exit`).

**W `$( )` wolno umieszczać tylko pojedynczą komendę albo potok**, którego status
jest statusem podstawienia. Błąd nie-ostatniej komendy ash połyka bezgłośnie, a
dzisiejszy bash z `trap ERR` go łapał — to jedyna realna regresja siatki
bezpieczeństwa przy tej zmianie. Podobnie **deklarację `local` trzymaj oddzielnie od
przypisania z `$( )`**: `local v="$(cmd)"` maskuje status także w busyboksie.
Obecny kod respektuje oba warunki; przepisanie nie może ich scalić.

**`fail` wolno wołać wyłącznie z top-levelu.** W podpowłoce `exit` kończy tylko
podpowłokę, a `BPP_INTENDED_EXIT=1` nie wraca do rodzica → podwójna notyfikacja.
Dziś żadne z pięciu wywołań (linie ~121, ~124, ~132, ~171, ~174) nie jest
w podpowłoce; tak musi zostać.

- [ ] **Krok 6: `$'\n'` i `numfmt`**

W `scripts/backup-cycle.sh` zamień (linia ~225):

```sh
    oldest="${to_purge%%$'\n'*}"
```

na:

```sh
    # `sed -n 1p`, a nie `head -1`: head zamyka wejscie po pierwszej linii, producent
    # dostaje SIGPIPE i pod `pipefail` wywraca caly backup.
    oldest="$(printf '%s\n' "$to_purge" | sed -n '1p')"
```

oraz `fmt_size()` (linia ~70) na:

```sh
fmt_size() {
    # numfmt nie istnieje ani w docker:cli, ani w rclone/rclone - bez tego kazdy
    # komunikat do Rollbara mialby surowe bajty.
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d%s\n" : "%.1f%s\n"), b, u[i]
    }'
}
```

- [ ] **Krok 7: `10#` w `_ym_index` bez octal-buga**

W `scripts/lib-rclone.sh` zamień `_ym_index` na:

```sh
_ym_index() {
    local y="${1%%-*}" m="${1##*-}"
    # `10#` to bashizm. Samo jego skasowanie wprowadza octal-bug: `$((08))` to
    # w busyboksie `arithmetic syntax error`, czyli wywrocenie retencji w sierpniu
    # i wrzesniu. Dlatego zdejmujemy wiodace zera jawnie.
    y="${y#0}"; y="${y#0}"; y="${y#0}"
    m="${m#0}"
    printf '%s' "$(( ${y:-0} * 12 + ${m:-0} - 1 ))"
}
```

- [ ] **Krok 8: Uruchom pełne testy**

Run: `bash scripts/test-rclone.sh`
Expected: wszystkie PASS, w tym nowa sekcja 6. Sekcja 4 (retencja) musi przejść bez
zmian — to ona pilnuje, że `_ym_index` nadal liczy poprawnie; jeśli miesiące 08/09
byłyby zepsute, testy retencji to złapią.

Run: `pre-commit run --files scripts/backup-cycle.sh scripts/lib-rclone.sh scripts/rclone-sync.sh scripts/rclone-config.sh scripts/test-rclone.sh`
Expected: shellcheck PASS (dyrektywy `shell=sh` aktywne).

Run: `./tests/test_makefile.sh 2>&1 | tail -6`
Expected: bez nowych FAIL-i (jedyny dopuszczalny to znany artefakt `invalid project
name` z lokalnego `.env`).

- [ ] **Krok 9: Commit**

```bash
git add scripts/ && git commit -m "refactor(backup): skrypty backupu zgodne z busybox ash

Shebang /bin/sh + preflight przeskakujacy na basha tam, gdzie /bin/sh to dash
(Debian). trap ERR -> trap EXIT z guardem, trap '' PIPE, sed -n 1p zamiast
\$'\\n', awk zamiast numfmt, zdjecie 10# bez octal-buga na miesiacach 08/09.

Compose nietkniety - dzisiejszy backup-runner (obraz postgres) uruchamia te
skrypty przez preflight -> bash, wiec zachowanie sie nie zmienia."
```

---

### Zadanie 2: Serwis `rclone` (zmiana addytywna)

Dodaje nowy serwis i przenosi na niego targety make. Nic nie zabiera — dzisiejszy
`backup-runner` dalej ma własnego rclone'a, a cykl dalej z niego korzysta. Dzięki temu
zadanie jest wdrażalne i odwracalne osobno.

**Pliki:**
- Modify: `docker-compose.backup.yml`
- Modify: `mk/rclone.mk`
- Test: `tests/test_makefile.sh`

**Interfejsy:**
- Produces: serwis compose o nazwie `rclone` z `/config/rclone` (RW), `/backup` (`:ro`)
  i `/scripts` (`:ro`).
- Consumes: nic z zadania 1.

- [ ] **Krok 1: Testy — serwis zadeklarowany i targety na niego wskazują**

Dopisz w `tests/test_makefile.sh` nową funkcję (obok `test_rclone_config_mount_writable`)
i dodaj jej wywołanie do listy na końcu pliku:

```bash
test_rclone_service_declared() {
    yellow "=== Test: rclone jako zadeklarowany serwis compose ==="

    # Obraz uzyty wylacznie w `docker run` bylby (a) sciagany dopiero o 2:30,
    # bo compose ciagnie tylko obrazy zadeklarowanych serwisow, i (b) kasowany
    # przez `docker system prune -af` na koncu `make up`, ktory usuwa obrazy
    # "without at least one container associated to them". Dzialajacy serwis
    # rozwiazuje oba problemy naraz.
    local yml="$REPO_DIR/docker-compose.backup.yml"

    assert_file_contains "serwis rclone zadeklarowany" '^  rclone:' "$yml"
    assert_file_contains "rclone: obraz z domyslna wartoscia" \
        'BPP_RCLONE_IMAGE:-' "$yml"
    assert_file_contains "rclone: restart always (Ofelia potrzebuje celu)" \
        'restart: always' "$yml"
    assert_file_contains "rclone: logging anchor" 'logging: \*default-logging' "$yml"
    assert_file_contains "rclone: montuje skrypty" './scripts:/scripts:ro' "$yml"
    # Sonda CA zostaje mimo ze upstreamowy obraz ja ma: BPP_RCLONE_IMAGE pozwala
    # podstawic dowolny obraz, a CLAUDE.md zakazuje usuwania tego sprawdzenia.
    assert_file_contains "rclone: healthcheck sprawdza bundle CA" \
        'ca-certificates.crt' "$yml"

    assert_file_contains "mk/rclone.mk celuje w serwis rclone" \
        'exec rclone' "$REPO_DIR/mk/rclone.mk"
    if grep -qE 'exec backup-runner' "$REPO_DIR/mk/rclone.mk"; then
        fail "mk/rclone.mk nadal woła rclone w backup-runnerze"
    else
        pass "mk/rclone.mk nie woła rclone w backup-runnerze"
    fi
}
```

- [ ] **Krok 2: Uruchom i potwierdź, że pada**

Run: `./tests/test_makefile.sh 2>&1 | grep -A20 "rclone jako zadeklarowany"`
Expected: FAIL na każdej asercji.

- [ ] **Krok 3: Dodaj serwis do `docker-compose.backup.yml`**

Za definicją `backup-runner`, w tym samym pliku (żeby korzystał z tamtejszego
`x-logging`):

```yaml
  # Rclone jako ZADEKLAROWANY serwis, a nie `docker run --rm` ze skryptu.
  # Powod nie jest estetyczny: (1) compose ciagnie obrazy tylko zadeklarowanych
  # serwisow, wiec obraz uzyty w `docker run` byl by pobierany dopiero o 2:30;
  # (2) `make up` konczy sie `docker system prune -af`, ktory usuwa obrazy bez
  # skojarzonego kontenera - a `--rm` zadnego nie zostawia, wiec obraz znikalby
  # przy KAZDYM `make up`; (3) mounty deklaruje compose, wiec w skryptach nie ma
  # ani jednej sciezki hosta (`docker run -v /backup:...` z wnetrza kontenera
  # zamontowalby pusta sciezke hosta - mount by sie udal, dane nie).
  rclone:
    image: ${BPP_RCLONE_IMAGE:-rclone/rclone:1.71.0}
    restart: always
    logging: *default-logging
    env_file: ${BPP_CONFIGS_DIR}/.env
    volumes:
      # RW, nigdy :ro - rclone zapisuje tu odswiezony token OAuth.
      - ${BPP_CONFIGS_DIR}/rclone:/config/rclone
      - ${DJANGO_BPP_HOST_BACKUP_DIR}:/backup:ro
      - ./scripts:/scripts:ro
    entrypoint: ["/bin/sh", "-c"]
    command: ["exec sleep infinity"]
    healthcheck:
      test: ["CMD-SHELL", "rclone version >/dev/null && [ -s /etc/ssl/certs/ca-certificates.crt ]"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
```

**Bez `deploy.resources.limits`** — świadomie, tak samo jak `backup-runner`. Rclone
w trakcie `copy` alokuje bufory transferu proporcjonalnie do liczby równoległych
strumieni; twardy limit RAM oznacza OOM-kill **w trakcie wysyłki**, czyli zamianę
wolnego backupu w brak backupu. To domyka kwestię otwartą §11 specu.

- [ ] **Krok 4: Przenieś targety w `mk/rclone.mk`**

Zamień `backup-runner` na `rclone` w `rclone-sync`, `rclone-config` i `rclone-check`.
Delegacja do skryptów **zostaje** (`/scripts/rclone-sync.sh`, `/scripts/rclone-config.sh`) —
pilnują tego asercje `test_rclone_single_source_of_truth`, a `rclone-config.sh` niesie
`rclone_fix_config_owner`. Zaktualizuj komentarz nagłówkowy pliku: nie ma już `apk add`
ani czekania na doinstalowanie narzędzi.

- [ ] **Krok 5: Uruchom testy**

Run: `./tests/test_makefile.sh 2>&1 | tail -8`
Expected: nowa sekcja PASS, brak nowych FAIL-i.

Run: `docker compose config >/dev/null && echo OK`
Expected: `OK` (na hoście z poprawnym `.env`; lokalny `.env` z wielkimi literami
w `COMPOSE_PROJECT_NAME` da znany błąd `invalid project name` — wtedy sprawdź
`COMPOSE_PROJECT_NAME=bpp docker compose config >/dev/null`).

- [ ] **Krok 6: Commit**

```bash
git add docker-compose.backup.yml mk/rclone.mk tests/test_makefile.sh
git commit -m "feat(backup): rclone jako zadeklarowany serwis compose

Obraz uzyty tylko w 'docker run --rm' bylby sciagany dopiero o 2:30 i kasowany
przez 'docker system prune -af' na koncu kazdego 'make up'. Jako serwis jest
ciagniety przez 'make up'/'make pull' i chroniony przed prune.

Targety rclone-* celuja w nowy serwis; delegacja do skryptow bez zmian."
```

---

### Zadanie 3: Orkiestrator — flip `backup-runnera` na `docker:cli`

Zadanie atomowe i największe. Nie da się go podzielić: w momencie, w którym
`backup-runner` traci `pg_dump`, `rclone`, `curl` i `jq`, cykl **musi** już
wykonywać te kroki przez `docker exec`.

**Pliki:**
- Create: `scripts/lib-container.sh`
- Modify: `scripts/backup-cycle.sh`
- Modify: `docker-compose.backup.yml`
- Test: `scripts/test-rclone.sh`, `tests/test_makefile.sh`

**Interfejsy:**
- Consumes: z zadania 1 — `on_exit`, `BPP_INTENDED_EXIT`, preflight; z zadania 2 —
  serwis compose o nazwie `rclone`.
- Produces: `bpp_container <nazwa-serwisu>` w `scripts/lib-container.sh`, wypisujące
  ID działającego kontenera danego serwisu albo pusty string i status 1.

- [ ] **Krok 1: Test — `bpp_container` rozwiązuje serwis po labelach**

Dopisz w `scripts/test-rclone.sh` (sekcja 7, przed podsumowaniem):

```bash
# ==========================================================================
# 7. bpp_container - adresowanie kontenerow po labelach compose
# ==========================================================================
echo
echo "7. bpp_container"

# Kontenery adresujemy po labelach, NIE po nazwie: compose generuje nazwy
# (`<projekt>-<usluga>-1`), a `container_name:` w tym repo nie jest ustawiany,
# wiec `docker exec dbserver` po prostu nie zadziala.
. "$REPO_DIR/scripts/lib-container.sh"

cont_bin="$TEST_ROOT/cont-bin"
mkdir -p "$cont_bin"
export DOCKER_LOG="$TEST_ROOT/docker-calls.log"
cat > "$cont_bin/docker" <<'SH'
#!/bin/sh
echo "docker $*" >> "$DOCKER_LOG"
case "$1" in
    ps) [ "${MOCK_NO_CONTAINER:-0}" = "1" ] || printf 'abc123\n' ;;
esac
exit 0
SH
chmod +x "$cont_bin/docker"

OLD_PATH="$PATH"; PATH="$cont_bin:$PATH"
export COMPOSE_PROJECT_NAME=testproj

: > "$DOCKER_LOG"
got="$(bpp_container dbserver)"
assert_eq "abc123" "$got" "bpp_container zwraca ID kontenera"
assert_contains "$(cat "$DOCKER_LOG")" \
    "label=com.docker.compose.project=testproj" "filtruje po projekcie"
assert_contains "$(cat "$DOCKER_LOG")" \
    "label=com.docker.compose.service=dbserver" "filtruje po usludze"
assert_not_contains "$(cat "$DOCKER_LOG")" "head -1" "nie uzywa head (SIGPIPE)"

: > "$DOCKER_LOG"
rc=0; MOCK_NO_CONTAINER=1 bpp_container dbserver >/dev/null || rc=$?
assert_eq "1" "$rc" "brak kontenera -> status 1, nie cichy sukces"

PATH="$OLD_PATH"; unset MOCK_NO_CONTAINER COMPOSE_PROJECT_NAME
```

- [ ] **Krok 2: Uruchom test i potwierdź, że pada**

Run: `bash scripts/test-rclone.sh 2>&1 | tail -12`
Expected: błąd o braku `scripts/lib-container.sh`.

- [ ] **Krok 3: Napisz `scripts/lib-container.sh`**

```sh
#!/bin/sh
# shellcheck shell=sh
#
# Adresowanie kontenerow Compose z wnetrza orkiestratora.
# Biblioteka do sourcowania - nie uruchamiac bezposrednio.
#
# Po nazwie sie nie da: compose generuje `<projekt>-<usluga>-<n>`, a to repo nie
# ustawia `container_name:`. Po labelach jest stabilnie i odporne na zmiane
# numeru repliki.

# bpp_container <nazwa-serwisu>
#   Wypisuje ID pierwszego DZIALAJACEGO kontenera danego serwisu.
#   Status 1, gdy nie ma zadnego - caller ma o czym raportowac, zamiast wolac
#   `docker exec ""` i dostac mylacy komunikat dockera.
bpp_container() {
    _svc="$1"
    _id="$(docker ps --quiet --no-trunc \
        --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-}" \
        --filter "label=com.docker.compose.service=${_svc}" \
        --filter "status=running" | sed -n '1p')"
    # `sed -n 1p`, nie `head -1`: head zamyka wejscie i producent dostaje SIGPIPE,
    # co pod `pipefail` wywraca caly cykl.
    [ -n "$_id" ] || return 1
    printf '%s' "$_id"
}
```

- [ ] **Krok 4: Uruchom test — sekcja 7 zielona**

Run: `bash scripts/test-rclone.sh 2>&1 | grep -A8 "7. bpp_container"`
Expected: wszystkie PASS.

- [ ] **Krok 5: Test — cykl woła `docker exec`, nie narzędzia lokalnie**

W `scripts/test-rclone.sh` rozszerz istniejący e2e (sekcja 3) o asercje na atrapie
`docker`. Kluczowe: atrapa `docker` musi obsłużyć `ps` (zwraca ID) i `exec`
(zapisuje wywołanie i, dla `rclone`, deleguje do istniejącej atrapy `rclone`,
żeby dotychczasowe asercje „copy, nie sync" nadal działały na tej samej ścieżce).

```bash
cat > "$MOCK_BIN/docker" <<'SH'
#!/bin/sh
echo "docker $*" >> "$RECORD"
case "$1" in
    ps) printf 'cid-%s\n' "$(echo "$*" | sed -n 's/.*service=\([a-z-]*\).*/\1/p')" ;;
    exec)
        # zdejmij "exec", flagi -e/-i oraz ID kontenera, wykonaj reszte lokalnie
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                -e) shift 2 ;;
                -i|-t|-it) shift ;;
                cid-*) shift; break ;;
                *) shift ;;
            esac
        done
        [ $# -gt 0 ] && exec "$@"
        ;;
esac
exit 0
SH
chmod +x "$MOCK_BIN/docker"
```

Dodaj asercje:

```bash
assert_contains "$(cat "$RECORD")" "docker exec" "krok pg_dump idzie przez docker exec"
assert_not_contains "$(cat "$RECORD")" "docker run" "cykl nie uzywa docker run (sciezki hosta!)"
assert_contains "$(cat "$RECORD")" "service=rclone" "wysylka celuje w serwis rclone"
```

- [ ] **Krok 6: Uruchom test i potwierdź, że pada**

Run: `bash scripts/test-rclone.sh 2>&1 | tail -12`
Expected: FAIL — `krok pg_dump idzie przez docker exec` (cykl nadal woła `pg_dump`
bezpośrednio).

- [ ] **Krok 7: Przełącz kroki cyklu na `docker exec`**

W `scripts/backup-cycle.sh`, po sourcowaniu `lib-rclone.sh`, dodaj:

```sh
# shellcheck source=scripts/lib-container.sh
. "$SCRIPT_DIR/lib-container.sh"

# Shim: lib-rclone.sh woła `rclone` z PATH i jest sourcowana TAKZE przez
# rclone-sync.sh dzialajacy WEWNATRZ kontenera rclone (gdzie nie ma dockera).
# Dlatego biblioteka zostaje czysta, a przekierowanie robimy tutaj.
rclone() {
    _rc_cid="$(bpp_container rclone)" || fail "rclone-container-missing" 3
    docker exec "$_rc_cid" rclone "$@"
}
```

Krok 1 (pg_dump) — hasło czytamy **wewnątrz** kontenera, bo lokalny `dbserver` ma tylko
`POSTGRES_PASSWORD`, a `PGPASSWORD` wyłącznie sentinel w trybie external; dzięki temu
sekret nie przechodzi też przez `-e`:

```sh
DB_CID="$(bpp_container dbserver)" || fail "dbserver-container-missing" 1
if ! docker exec "$DB_CID" sh -c '
        PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" exec pg_dump -Fd -j "$1" \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME" -f "$2"
    ' _ "$PARALLEL_JOBS" "$DB_DIR"; then
    fail "pg_dump" 1
fi
```

Kroki 2 i 3 (`tar` dumpu i mediów) **zostają lokalnie** — `docker:cli` ma busybox
`tar`, a orkiestrator ma `/backup` i `media:/mediaroot:ro`. Krok 4 (rotacja) bez zmian.
Kroki 5 i 6 (`rclone copy`, `lsf`, `purge`) idą przez shim automatycznie.

- [ ] **Krok 8: Przełącz `backup-runner` na `docker:cli`**

W `docker-compose.backup.yml` zamień definicję `backup-runner`: obraz na
`${BPP_ORCHESTRATOR_IMAGE:-docker:28-cli}`, usuń `apt-get`/`apk` z `command:`
(zostaje `exec sleep infinity`), usuń `environment: PGPASSWORD`, dodaj
`environment: COMPOSE_PROJECT_NAME: ${COMPOSE_PROJECT_NAME}`, **zostaw
`env_file: ${BPP_CONFIGS_DIR}/.env`** (bez niego `DJANGO_BPP_RCLONE_KEEP_MONTHS=`
przestaje wyłączać retencję zdalną) oraz mounty:
`/var/run/docker.sock:/var/run/docker.sock`, `media:/mediaroot:ro`,
`${BPP_CONFIGS_DIR}/rclone:/config/rclone:ro`. Healthcheck:

```yaml
    healthcheck:
      # Sonduje to, co realnie moze paść: dostep do socketu i powloke z pipefail
      # (niekompatybilny BPP_ORCHESTRATOR_IMAGE ma byc unhealthy przy `make up`,
      # a nie odkryty o 2:30). Binarek nie sprawdzamy - nie instalujemy zadnych.
      test: ["CMD-SHELL", "docker version --format '{{.Server.Version}}' >/dev/null && (set -o pipefail)"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 15s
```

Zaktualizuj komentarz nagłówkowy serwisu: cała sekcja o `ca-certificates`
i współdzieleniu warstw z `dbserverem` przestaje obowiązywać — zastąp ją opisem
orkiestratora i **wyjaśnieniem, dlaczego mount configu rclone jest `:ro`** (cykl robi
`[ ! -f "$RCLONE_CONFIG" ]` przed wysyłką; bez mountu padałby co noc na
`fail rclone-config-missing 3`).

- [ ] **Krok 9: Test — compose bez `apt-get`, z socketem, z mountem configu**

Zastąp `test_backup_runner_ca_certificates` w `tests/test_makefile.sh` funkcją
`test_backup_runner_is_orchestrator` (podmień też wywołanie na końcu pliku):

```bash
test_backup_runner_is_orchestrator() {
    yellow "=== Test: backup-runner jest orkiestratorem, nie kombajnem ==="

    local yml="$REPO_DIR/docker-compose.backup.yml"

    if grep -qE 'apt-get|apk add' "$yml"; then
        fail "backup-runner nadal doinstalowuje pakiety w runtime"
    else
        pass "backup-runner nie instaluje niczego w runtime"
    fi
    assert_file_contains "orkiestrator ma docker.sock" \
        '/var/run/docker.sock' "$yml"
    assert_file_contains "orkiestrator ma media do tarowania" \
        'media:/mediaroot:ro' "$yml"
    # Bez tego mountu `[ ! -f "$RCLONE_CONFIG" ]` w kroku 4 cyklu jest prawdziwe
    # ZAWSZE i cykl pada co noc na fail rclone-config-missing 3.
    assert_file_contains "orkiestrator widzi config rclone (:ro)" \
        '/config/rclone:ro' "$yml"
    assert_file_contains "orkiestrator dostaje COMPOSE_PROJECT_NAME" \
        'COMPOSE_PROJECT_NAME' "$yml"
    # Bez env_file cykl czyta same defaulty. Najgrozniejsze: operator
    # z DJANGO_BPP_RCLONE_KEEP_MONTHS= (udokumentowany wylacznik) dostaje
    # WLACZONE kasowanie zdalnych kopii.
    assert_file_contains "orkiestrator ma env_file" \
        'env_file: ${BPP_CONFIGS_DIR}/.env' "$yml"
    assert_file_contains "healthcheck sonduje socket" 'docker version' "$yml"
    assert_file_contains "healthcheck sonduje pipefail" 'pipefail' "$yml"
}
```

- [ ] **Krok 10: Uruchom komplet testów**

Run: `bash scripts/test-rclone.sh`
Expected: wszystkie PASS (sekcje 1-7).

Run: `./tests/test_makefile.sh 2>&1 | tail -8`
Expected: brak nowych FAIL-i.

Run: `pre-commit run --files scripts/lib-container.sh scripts/backup-cycle.sh docker-compose.backup.yml tests/test_makefile.sh scripts/test-rclone.sh`
Expected: wszystko PASS.

- [ ] **Krok 11: Commit**

```bash
git add scripts/lib-container.sh scripts/backup-cycle.sh docker-compose.backup.yml \
        tests/test_makefile.sh scripts/test-rclone.sh
git commit -m "feat(backup): backup-runner jako orkiestrator na docker:cli

Koniec z apt-get przy kazdym starcie kontenera. Cykl woła pg_dump w dbserverze
i rclone w serwisie rclone przez 'docker exec'; tar dumpu i mediow robi lokalnie
(busybox tar). Kontenery adresowane po labelach compose, bo nazwy sa generowane.

Haslo do pg_dump czytane WEWNATRZ dbservera z DJANGO_BPP_DB_PASSWORD - lokalny
dbserver nie ma PGPASSWORD (ma je tylko sentinel w trybie external), a sekret
nie przechodzi przez -e.

Orkiestrator montuje config rclone :ro, bo cykl sprawdza jego obecnosc przed
wysylka - bez tego padalby co noc."
```

---

### Zadanie 4: Notyfikacja Rollbar przez appservera

Po zadaniu 3 orkiestrator nie ma `curl` ani `jq`. Do tej pory `notify_rollbar`
działał na atrapach w testach — teraz dostaje realną implementację.

**Pliki:**
- Modify: `scripts/backup-cycle.sh` (`notify_rollbar`)
- Test: `scripts/test-rclone.sh`

**Interfejsy:**
- Consumes: `bpp_container` z zadania 3.
- Produces: `notify_rollbar <level> <message>` — zawsze status 0.

- [ ] **Krok 1: Test — notyfikacja idzie do appservera i nigdy nie wywraca cyklu**

```bash
echo
echo "8. notify_rollbar przez appservera"

: > "$RECORD"
MOCK_YM=2026-08 ROLLBAR_TOKEN_ENV=1 run_cycle
assert_contains "$(cat "$RECORD")" "service=appserver" \
    "notyfikacja celuje w appservera"

# Martwy appserver nie moze sklobrowac kodu wyjscia ani urwac trapa.
: > "$RECORD"
MOCK_YM=2026-08 MOCK_FAIL_ON=exec-appserver MOCK_FAIL_ON_STEP=pg_dump run_cycle
assert_eq "1" "$CYCLE_RC" "padly appserver NIE zmienia kodu wyjscia (1, nie sklobrowane)"
```

- [ ] **Krok 2: Uruchom i potwierdź, że pada**

Run: `bash scripts/test-rclone.sh 2>&1 | tail -10`
Expected: FAIL — `notyfikacja celuje w appservera`.

- [ ] **Krok 3: Przepisz `notify_rollbar`**

```sh
notify_rollbar() {
    _level="$1"; _message="$2"
    if [ -z "${ROLLBAR_ACCESS_TOKEN:-}" ]; then
        log "rollbar: skip (ROLLBAR_ACCESS_TOKEN not set)"
        return 0
    fi
    # Orkiestrator nie ma curl ani jq. Python w appserverze escapuje JSON sam
    # i czyta token z wlasnego env_file, wiec sekret nie przechodzi przez -e.
    #
    # KRYTYCZNE: cala funkcja konczy sie sukcesem ZAWSZE. Jest wolana z on_exit,
    # a blad w trapie urywa go przed `exit "$rc"` i klobruje kod wyjscia na 1 -
    # i to dokladnie wtedy, gdy appserver lezy, czyli w scenariuszu, o ktorym
    # raportujemy.
    _app="$(bpp_container appserver)" || {
        log "rollbar: brak dzialajacego appservera - notyfikacja pominieta"
        return 0
    }
    docker exec \
        -e "BPP_RB_LEVEL=$_level" \
        -e "BPP_RB_MSG=$_message" \
        -e "BPP_RB_TS=$TIMESTAMP" \
        -e "BPP_RB_ENV=${DJANGO_BPP_HOSTNAME:-unknown}" \
        "$_app" python -c '
import json, os, urllib.request
payload = {
    "access_token": os.environ["ROLLBAR_ACCESS_TOKEN"],
    "data": {
        "environment": os.environ["BPP_RB_ENV"],
        "level": os.environ["BPP_RB_LEVEL"],
        "body": {"message": {"body": os.environ["BPP_RB_MSG"]}},
        "custom": {"component": "backup-cycle", "timestamp": os.environ["BPP_RB_TS"]},
    },
}
req = urllib.request.Request(
    "https://api.rollbar.com/api/1/item/",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=10) as r:
    print("rollbar http=%s" % r.status)
' 2>&1 | while IFS= read -r _line; do log "rollbar: $_line"; done || true
    return 0
}
```

- [ ] **Krok 4: Uruchom testy**

Run: `bash scripts/test-rclone.sh`
Expected: wszystkie PASS, w tym sekcja 8.

- [ ] **Krok 5: Commit**

```bash
git add scripts/backup-cycle.sh scripts/test-rclone.sh
git commit -m "feat(backup): notyfikacja Rollbar przez appservera zamiast curl+jq

Orkiestrator nie ma curl ani jq. Python w appserverze escapuje JSON sam i czyta
token z wlasnego env_file. Funkcja zwraca sukces ZAWSZE - jest wolana z trapa
EXIT, gdzie blad urwalby trap przed exit i sklobrowal kod wyjscia."
```

---

### Zadanie 5: Wygaszenie `BPP_BACKUP_PG_IMAGE` + dokumentacja

**Pliki:**
- Modify: `scripts/init-configs.sh` (okolice linii 415-418)
- Modify: `scripts/ensure-config-files.sh` (okolice linii 264-265)
- Modify: `docs/eksploatacja/backup-i-rclone.md`, `docs/architektura/uslugi.md`,
  `docs/architektura/zadania-ofelia.md`, `docs/eksploatacja/przenosiny-serwera.md`
- Modify: `CLAUDE.md`
- Test: `tests/test_makefile.sh`

- [ ] **Krok 1: Test — zmienna nie jest już zapisywana, ale stary `.env` przeżywa**

```bash
test_backup_pg_image_retired() {
    yellow "=== Test: BPP_BACKUP_PG_IMAGE wygaszona ==="

    # Wzorzec martwej flagi jak DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE: przestajemy
    # zapisywac, ale NIE usuwamy ze starych .env i nic sie na nia nie wywraca.
    for f in scripts/init-configs.sh scripts/ensure-config-files.sh; do
        if grep -qE '^[^#]*BPP_BACKUP_PG_IMAGE=' "$REPO_DIR/$f"; then
            fail "$f nadal zapisuje BPP_BACKUP_PG_IMAGE"
        else
            pass "$f nie zapisuje BPP_BACKUP_PG_IMAGE"
        fi
    done
    if grep -q 'BPP_BACKUP_PG_IMAGE' "$REPO_DIR/docker-compose.backup.yml"; then
        fail "compose nadal czyta BPP_BACKUP_PG_IMAGE"
    else
        pass "compose nie czyta BPP_BACKUP_PG_IMAGE"
    fi
}
```

- [ ] **Krok 2: Uruchom i potwierdź, że pada**

Run: `./tests/test_makefile.sh 2>&1 | grep -A6 "BPP_BACKUP_PG_IMAGE wygaszona"`
Expected: FAIL na `init-configs.sh` i `ensure-config-files.sh`.

- [ ] **Krok 3: Usuń zapisywanie zmiennej**

Usuń w obu skryptach fragmenty ustawiające `BPP_BACKUP_PG_IMAGE` (tryb external).
**Nie** dodawaj migracji usuwającej ją ze starego `.env` — nieużywana zmienna jest
nieszkodliwa, a kasowanie cudzych wpisów łamie kontrakt kompatybilności. Zostaw
komentarz w miejscu usunięcia, że zmienna jest martwa od tej wersji.

- [ ] **Krok 4: Uruchom testy**

Run: `./tests/test_makefile.sh 2>&1 | tail -8`
Expected: PASS.

- [ ] **Krok 5: Dokumentacja — użyj skilla `docs-sync`**

Uruchom skill `docs-sync` i przejdź jego checklistę. Minimalny zakres:

- `docs/eksploatacja/backup-i-rclone.md` — opis `backup-runnera` (nie instaluje już
  nic w runtime), nowy serwis `rclone`, sekcja *„Awaria TLS: certificate signed by
  unknown authority"* **przepisana**, nie skasowana: przyczyna zniknęła wraz
  z `apt-get`, ale sonda CA w healthchecku serwisu `rclone` została i trzeba wyjaśnić,
  po co. Dopisz też, że `make rclone-*` celuje teraz w serwis `rclone`.
- `docs/architektura/uslugi.md` — dwa serwisy zamiast jednego, przepływ danych.
- `docs/architektura/zadania-ofelia.md` — `job-exec` idzie teraz na orkiestrator.
- `docs/eksploatacja/przenosiny-serwera.md` — sprawdź wzmianki o `backup-runnerze`.
- `CLAUDE.md` — sekcja *„CRITICAL: `ca-certificates` musi zostać na liście pakietów"*
  przestaje opisywać rzeczywistość. **Przepisz ją** na regułę o sondzie CA
  w healthchecku serwisu `rclone` i o tym, że orkiestrator niczego nie instaluje;
  zostawienie starych anti-fixów będzie mylić agentów. Dopisz tripwire o adresowaniu
  po labelach i o `|| true` w trapie EXIT.

Run: `uv run --with 'mkdocs-material>=9.5' mkdocs build --strict`
Expected: build bez ostrzeżeń.

- [ ] **Krok 6: Commit — razem ze specem i planem**

```bash
git add scripts/init-configs.sh scripts/ensure-config-files.sh tests/test_makefile.sh \
        docs/ CLAUDE.md specs/
git commit -m "docs(backup): dokumentacja orkiestratora + wygaszenie BPP_BACKUP_PG_IMAGE

Zmienna byla potrzebna, gdy backup-runner wspoldzielil obraz z dbserverem.
Orkiestrator nie potrzebuje obrazu Postgresa - przestajemy ja zapisywac, ale
NIE usuwamy ze starych .env (wzorzec DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE).

Sekcja o ca-certificates w CLAUDE.md przepisana, nie skasowana: przyczyna
zniknela, ale sonda CA w healthchecku zostala i trzeba wiedziec po co.

Dolaczony spec i plan wdrozenia."
```

---

## Wdrożenie na produkcji

Cała migracja to zmiana obrazów i `command:`, więc **sam `git pull` nie wystarcza —
potrzebny `make up`**. To odwrotnie niż zwykłe zmiany w `scripts/`, które jadą na
bind-mouncie i docierają do działającego kontenera bez restartu.

Po wdrożeniu, przed pierwszą nocą:

```bash
make up
docker compose ps backup-runner rclone     # oba healthy
make backup-cycle                          # pelny cykl recznie
make rclone-check                          # spojnosc kopii zdalnej
```

## Wycofanie

Każde zadanie jest osobnym commitem i każde da się cofnąć niezależnie **poza
zadaniem 3**, które musi być cofnięte razem z 4 (po rewercie 3 orkiestrator znów ma
`curl`/`jq`, ale notyfikacja z zadania 4 woła `docker exec`, którego już nie ma).
Zadanie 1 jest bezpieczne w obie strony — skrypty działają i pod bashem, i pod ash.
