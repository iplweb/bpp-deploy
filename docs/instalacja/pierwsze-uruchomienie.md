# Pierwsze uruchomienie (wspólne kroki konfiguracji)

Poniższe kroki wykonujesz po zakończeniu instrukcji właściwych dla Twojego systemu
operacyjnego ([Linux](linux.md) / [macOS](macos.md) / [Windows](windows.md)).
Są identyczne dla wszystkich platform.

## 1. Pierwsze uruchomienie `make`

```bash
make
```

Przy pierwszym uruchomieniu `make` zapyta o ścieżkę do **katalogu konfiguracyjnego** —
musi znajdować się poza repozytorium. Jego nazwa stanie się nazwą projektu Docker Compose.

```
=== BPP Deploy - pierwsze uruchomienie ===

Podaj sciezke do katalogu konfiguracyjnego instancji BPP.
Katalog musi znajdowac sie POZA repozytorium.

Przyklad: /home/deploy/publikacje-uczelnia

Sciezka: /home/deploy/moja-instancja
```

`make` automatycznie:

- utworzy strukturę katalogów konfiguracyjnych,
- skopiuje szablonowe pliki z `defaults/`,
- wygeneruje losowe hasła do bazy danych,
- utworzy plik `.env` z konfiguracją,
- uruchomi [`configure-resources`](../konfiguracja/limity-zasobow.md) (limity RAM/CPU),
- wybierze [wersję PostgreSQL](../konfiguracja/postgresql.md).

## 2. Sprawdź i dostosuj konfigurację

Otwórz plik `.env` z katalogu konfiguracyjnego w dowolnym edytorze tekstu (np. Notepad,
VS Code, nano, vim). Ścieżka wyświetli się po pierwszym uruchomieniu `make`, np.
`/home/deploy/moja-instancja/.env`.

Co warto zmienić w `.env`:

- `DJANGO_BPP_HOSTNAME` — właściwa nazwa hosta (np. `publikacje.uczelnia.pl`).
  Dla wielu domen patrz [Multi-host](../konfiguracja/multi-host.md).
- `DJANGO_BPP_CSRF_EXTRA_ORIGINS` — dozwolone originy CSRF.
- Sprawdź wygenerowane hasła (opcjonalnie).

### Certyfikaty SSL

```bash
# Opcja A: własne certyfikaty — skopiuj cert.pem i key.pem
#          do podkatalogu ssl/ w katalogu konfiguracyjnym

# Opcja B: samopodpisane certyfikaty (snakeoil) do testów
make generate-snakeoil-certs

# Opcja C: Let's Encrypt (wymaga DNS wskazującego na ten serwer + port 80
#          osiągalny z internetu). Zacznij OD STAGINGA, potem PROD=1:
make ssl-letsencrypt-issue           # staging - test pipeline'u
make ssl-letsencrypt-issue PROD=1    # prawdziwy cert + flip mode na 'letsencrypt'
```

Szczegóły i codzienne odnawianie: [SSL (manual / Let's Encrypt)](../konfiguracja/ssl.md).

## 3. Uruchom usługi

```bash
make run
```

## 4. Otwórz aplikację w przeglądarce

Po uruchomieniu `make run` główny serwis jest dostępny przez `webserver` (Nginx),
który wystawia standardowe porty HTTP i HTTPS:

- `80:80`
- `443:443`

Na Docker Desktop pod macOS oznacza to, że porty są mapowane na hosta macOS. Aplikację
otwierasz więc w przeglądarce przez adres hosta, a nie przez wewnętrzne porty kontenerów.

Zalecane warianty konfiguracji lokalnej:

- ustaw `DJANGO_BPP_HOSTNAME=localhost` i otwórz `https://localhost/`
- albo ustaw własną nazwę, np. `bpp.local`, dodaj ją do `/etc/hosts`, a następnie otwórz
  `https://bpp.local/`

!!! note
    Nginx akceptuje tylko hostname zgodny z `DJANGO_BPP_HOSTNAME`. Jeśli w konfiguracji
    ustawisz inną nazwę hosta, wejście przez `localhost` może nie działać poprawnie mimo
    poprawnego mapowania portów.

Przy pierwszym uruchomieniu, jeśli baza danych jest pusta, aplikacja automatycznie
przekieruje do `/setup/`. Jest to oczekiwane zachowanie kreatora konfiguracji
początkowej, w którym tworzysz pierwsze konto administratora.

### Narzędzia administracyjne i monitoring

Nie są wystawiane jako osobne porty hosta — dostępne przez Nginx pod ścieżkami:

- `https://<hostname>/grafana/`
- `https://<hostname>/netdata/`
- `https://<hostname>/flower/`
- `https://<hostname>/dozzle/`

Wszystkie są chronione [uwierzytelnianiem](../monitoring/przeglad.md#dostep-i-uwierzytelnianie)
przez nginx + authserver.
