# Instalacja — Windows

## 1. Komplet narzędzi jedną komendą (winget)

Otwórz **PowerShell** (zwykły — instalator Dockera sam poprosi o uprawnienia
administratora) i wklej:

```powershell
winget install -e --id Git.Git --source winget
winget install -e --id Docker.DockerDesktop --source winget
winget install -e --id ezwinports.make --source winget
```

To komplet wymaganych narzędzi:

- **Git for Windows** — dostarcza **Git Bash**, czyli terminal z narzędziami Unix
  (`bash`, `grep`, `sed`, `openssl` — `make` korzysta z nich wszystkich)
- **Docker Desktop for Windows** — Docker Engine razem z Docker Compose
- **GNU Make 4.4** (pakiet `ezwinports.make`) — instalacja *portable*, winget sam
  dopisuje `make` do PATH

!!! warning "Po co `--source winget`"
    Bez tego przełącznika winget przeszukuje również Sklep Microsoft (źródło
    `msstore`) i zamiast instalować, przerywa pytaniem o wybór źródła albo
    o akceptację regulaminu Sklepu.

!!! info "Skąd wziąć winget"
    `winget` jest wbudowany w Windows 11 oraz w Windows 10 od wersji 1809
    (build 17763), gdzie dostarcza go „Instalator aplikacji”. Sprawdź go komendą
    `winget --version`. Jeśli nie zadziała — zainstaluj lub zaktualizuj
    [Instalator aplikacji](https://apps.microsoft.com/detail/9nblggh4nns1)
    ze Sklepu Microsoft albo rozwiń sekcję poniżej.

??? note "Nie masz wingeta? (Windows 10 starszy niż 1809, zablokowany Sklep)"
    Pobierz i zainstaluj ręcznie [Git for Windows](https://gitforwindows.org/) oraz
    [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).

    GNU Make nie wymaga menedżera pakietów — to pojedynczy, samowystarczalny plik:

    1. Pobierz [make-4.4.1-without-guile-w32-bin.zip](https://downloads.sourceforge.net/project/ezwinports/make-4.4.1-without-guile-w32-bin.zip)
       (392 KB, projekt [ezwinports](https://sourceforge.net/projects/ezwinports/files/)
       — dokładnie ten sam plik, który instaluje `winget install ezwinports.make --source winget`).
    2. Rozpakuj archiwum (w Eksploratorze: prawy przycisk > „Wyodrębnij wszystkie…").
    3. Skopiuj `bin\make.exe` do `C:\Program Files\Git\usr\bin\` — Windows poprosi
       o potwierdzenie administratora.

    Katalog `usr\bin` z instalacji Gita jest już w PATH Git Basha, więc nic więcej nie
    trzeba ustawiać, a `make.exe` importuje wyłącznie systemowe biblioteki Windows, więc
    wystarczy ten jeden plik. Ponowna instalacja Git for Windows może go usunąć — wtedy
    powtórz krok 3.

    Jeśli i tak masz już [Chocolatey](https://chocolatey.org/install) albo
    [Scoop](https://scoop.sh/), szybciej będzie `choco install make` (PowerShell jako
    Administrator) lub `scoop install make`.

## 2. Uruchom Docker Desktop

Uruchom Docker Desktop z menu Start i poczekaj, aż ikona wieloryba w zasobniku
systemowym przestanie się animować. Pierwsze uruchomienie może włączyć WSL2
i poprosić o restart komputera.

## 3. Sklonuj repozytorium (w Git Bash)

Otwórz **Git Bash** (znajdziesz go w menu Start po wpisaniu „Git Bash") i sklonuj
repozytorium:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

!!! warning "Ważne"
    Od tego momentu wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD
    ani PowerShell. Otwórz **świeże** okno terminala — dopiero nowo uruchomiony
    terminal widzi `make` dopisany do PATH przez winget.

!!! tip "Ścieżka katalogu konfiguracyjnego"
    Przy [pierwszym uruchomieniu](pierwsze-uruchomienie.md) `make` zapyta o katalog
    konfiguracyjny. Możesz podać ścieżkę po windowsowemu — `C:\dane\bpp`,
    `C:/dane/bpp`, a także wklejoną razem z cudzysłowami przez „Kopiuj jako ścieżkę"
    z Eksploratora (`"C:\dane\bpp"`). Każda z tych postaci jest przeliczana na
    `/c/dane/bpp`, czyli zapis używany przez Git Bash.

➡️ Przejdź do **[Pierwszego uruchomienia](pierwsze-uruchomienie.md)**.
