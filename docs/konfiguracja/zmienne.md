# Zmienne operatora — `make configure`

Większość zmiennych w `${BPP_CONFIGS_DIR}/.env` jest generowana albo ma rozsądną wartość
domyślną. Kilkanaście zależy jednak wyłącznie od Ciebie: e-mail administratora, tryb SSL,
powiadomienia, katalog backupów, widgety Freshdesk. Zebrane są w jednym rejestrze
(`scripts/config-registry.tsv`), z którego korzystają:

- **`make init-configs`**: pyta o nie przy instalacji,
- **`make up`** (także `make run`, `up-quick`, `refresh`): pyta **raz** o te, których
  w `.env` jeszcze nie ma, np. po aktualizacji, która dodała nową zmienną,
- **`make configure`**: menu grup do przejrzenia i zmiany wartości,
- **`make config-check`** i **`make doctor`** (pozycja *config*): sprawdzają, czy wartości są
  poprawne (e-mail wygląda jak e-mail, ID widgetu jest liczbą itd.),
- tabela niżej na tej stronie, generowana z rejestru.

## Kreator: `make configure`

```bash
make configure
```

```
=== Konfiguracja BPP — /home/bpp/publikacje-uczelnia/.env ===
  1) Administrator   (1)
  2) SSL             (2)
  3) Powiadomienia   (2)
  4) Google          (2)
  5) Backup          (3)
  6) Freshdesk       (3)
  z) zapisz i wyjdz    q) wyjdz bez zapisu
Wybierz:
```

Po wyborze grupy kreator pyta po kolei o jej zmienne. **Enter** zostawia wartość
z nawiasu, **`-`** ustawia pustą (= funkcja wyłączona). Zmiany trafiają do `.env`
dopiero po **`z`**, a `q` je porzuca. Nowe wartości działają po `make up`.

Sekrety (np. sekret JWT Freshdeska, token Rollbara) nie pojawiają się na ekranie ani
przy wpisywaniu, ani w podsumowaniu. Kreator pokazuje tylko ich długość.

## Pytanie przy `make up` — „raz i już” {#pytanie-przy-make-up}

Jeśli nowa wersja bpp-deploy wprowadza zmienną, o której musisz zdecydować (np. ID
widgetów Freshdesk), `make up` zatrzyma się przed startem kontenerów i zapyta o nią.

**Pusta odpowiedź (Enter) też jest odpowiedzią.** Zapisuje się wtedy `ZMIENNA=` (pusta
wartość = funkcja wyłączona) i przy następnym `make up` kreator już o nią nie pyta.
O tym, że decyzja zapadła, świadczy **sama obecność zmiennej** w `.env`. Jeśli zmienisz
zdanie, uruchom `make configure`.

Kreator **nie pyta**, gdy nie ma kogo pytać. Wtedy niczego nie zapisuje i `make up`
idzie dalej:

- `make up` bez terminala (cron, CI, `| tee`): wypisuje tylko jedną linię z przypomnieniem,
- automatyczne aktualizacje i przerwa techniczna (`make autoupdate`,
  `make run-with-warning`), a także `restore` i `upgrade-postgres`. Wszystkie te ścieżki
  ustawiają `BPP_SKIP_HEALTH_GATE=1`. Pytania można też wyłączyć ręcznie przez
  `BPP_NO_CONFIG_PROMPT=1 make up`,
- nikt nie odpowiada przez 120 s (`BPP_CONFIG_PROMPT_TIMEOUT`), np. przy `ssh -t`
  bez człowieka po drugiej stronie.

Przerwanie w połowie (Ctrl-D, timeout) **nie zapisuje niczego**, także odpowiedzi już
udzielonych, bo brak odpowiedzi nie jest decyzją. Kreator zapyta znowu przy następnym
`make up`.

Zmienne z kolumną *Pytanie* = `nie` (np. tryb SSL, retencja backupów) mają wartość
domyślną, którą `init-configs` wpisuje bez pytania. `make up` o nie nie pyta, a zmienić je
można tylko w `make configure`.

## Dozwolone znaki

`.env` czytają trzy programy: Docker Compose (interpoluje `$`), `make` (dla niego `#`
to komentarz, a `$` to składnia) i skrypty. Dlatego kreator nie przyjmuje w wartościach
`$`, `#`, cudzysłowów, `\` ani `` ` ``. Sekrety mogą zawierać tylko litery, cyfry
i `. _ ~ + / = -`.

## Lista zmiennych

<!-- rejestr:start (generowane: make docs-config-table, nie edytuj recznie) -->

### Administrator

| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |
|---|---|---|---|---|---|
| `DJANGO_BPP_ADMIN_EMAIL` | email | `admin@example.com` | tak | nie | E-mail administratora BPP (konto admina, maile o bledach) |

### SSL

| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |
|---|---|---|---|---|---|
| `DJANGO_BPP_SSL_MODE` | jedno z: manual/letsencrypt | `manual` | nie | nie | Skad nginx bierze certyfikat: manual = ssl/, letsencrypt = letsencrypt/live/&lt;host&gt;/ |
| `DJANGO_BPP_LETSENCRYPT_EMAIL` | email | = `DJANGO_BPP_ADMIN_EMAIL` | nie | nie | E-mail dla Let's Encrypt (powiadomienia o wygasajacych certyfikatach) |

### Powiadomienia

| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |
|---|---|---|---|---|---|
| `DJANGO_BPP_SLACK_WEBHOOK` | url | *(pusta)* | tak | tak | Slack webhook URL (pusta = bez powiadomien na Slacka) |
| `ROLLBAR_ACCESS_TOKEN` | sekret | *(pusta)* | tak | tak | Rollbar access token typu post_server_item (pusta = backup-cycle bez powiadomien) |

### Google

| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |
|---|---|---|---|---|---|
| `DJANGO_BPP_GOOGLE_ANALYTICS_PROPERTY_ID` | tekst | *(pusta)* | tak | tak | Google Analytics Property ID (pusta = bez GA) |
| `DJANGO_BPP_GOOGLE_VERIFICATION_CODE` | tekst | *(pusta)* | tak | tak | Google Search Console verification code (pusta = brak) |

### Backup

| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |
|---|---|---|---|---|---|
| `DJANGO_BPP_HOST_BACKUP_DIR` | sciezka | `backups/` obok katalogu konfiguracyjnego | tak | nie | Katalog backupow na hoscie (sciezka bezwzgledna) |
| `DJANGO_BPP_BACKUP_KEEP_LAST` | liczba | `7` | nie | nie | Ile ostatnich kopii kazdego typu trzymac lokalnie |
| `DJANGO_BPP_RCLONE_REMOTE` | tekst | `backup_enc:` | nie | nie | Remote rclone dla kopii zdalnych (nazwa z rclone.conf zakonczona dwukropkiem) |

### Freshdesk

| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |
|---|---|---|---|---|---|
| `DJANGO_BPP_FRESHDESK_WIDGET_ID` | id | `205000000433` | tak | tak | ID widgetu Freshdesk dla ZALOGOWANYCH (pusta = brak zakladki Pomoc dla zalogowanych) |
| `DJANGO_BPP_FRESHDESK_WIDGET_ID_ANON` | id | *(pusta)* | tak | tak | ID widgetu Freshdesk dla ANONIMOW (pusta = anonimowi nie widza zakladki Pomoc) |
| `DJANGO_BPP_FRESHDESK_WIDGET_JWT_SECRET` | sekret | *(pusta)* | tak | tak | Sekret JWT widgetu (Freshdesk: Admin &gt; Account &gt; Security &gt; Widget settings; pusta = bez JWT) |

<!-- rejestr:end -->

Szczegóły poszczególnych funkcji: [SSL](ssl.md),
[backup i rclone](../eksploatacja/backup-i-rclone.md),
[widget Freshdesk](architektura.md#widget-wsparcia-freshdesk-django_bpp_freshdesk_widget_).

## Dla deweloperów: dodanie zmiennej

Nowa zmienna, o którą operator ma być zapytany, to **jeden wiersz** w
`scripts/config-registry.tsv` (format opisany w nagłówku pliku), a potem
`make docs-config-table`. Nie trzeba dopisywać `ensure_env_var` w `init-configs.sh`
ani migracji `.env`, bo brak zmiennej po prostu wywoła pytanie przy `make up`. Zmienna musi
mieć wartość domyślną w miejscu, które ją czyta (Compose `${VAR:-…}` albo ustawienia
Django), bo autoupdate i CI o nią nie zapytają.
