# Instalacja — Windows

!!! tip "Najprościej: przez WSL2"
    WSL2 to wbudowany w Windows podsystem Linuksa. Aby uruchomić BPP na Windows,
    potrzebujesz zainstalować Docker Desktop, który i tak z niego korzysta.

    Wolisz zostać po stronie Windows? Instrukcja dla Git Basha jest
    [na dole strony](#instalacja-przez-git-bash).

## 1. Włącz WSL2 (Windows Subsystem for Linux)

Kliknij prawym przyciskiem na przycisk Start, wybierz **Terminal (Administrator)**
(na Windows 10: **Windows PowerShell (Administrator)**) i wpisz:

```powershell
wsl --install
```

Komenda włącza [WSL2](https://learn.microsoft.com/pl-pl/windows/wsl/install)
i instaluje dystrybucję Ubuntu, po czym prosi o restart komputera. Jeśli WSL jest już
włączony, nic nie zepsuje — po prostu to zgłosi. Stan sprawdzisz też komendą
`wsl --status`.

!!! info "Wymagania WSL2"
    Windows 11 albo Windows 10 w wersji 2004 (build 19041) lub nowszej, z włączoną
    wirtualizacją w BIOS/UEFI — dokładnie te same wymagania, co Docker Desktop.
    Na starszych wydaniach WSL2 trzeba doinstalować
    [ręcznie](https://learn.microsoft.com/pl-pl/windows/wsl/install-manual).

## 2. Zainstaluj Docker Desktop i połącz go z Ubuntu

Otwórz **PowerShell** — naciśnij klawisz Windows, zacznij pisać **powershell**
i kliknij aplikację **Windows PowerShell**:

![Ikona Windows PowerShell](../assets/powershell-icon.png){ width="48" }

W otwartym oknie wklej:

```powershell
winget install -e --id Docker.DockerDesktop --source winget
```

Uruchom Docker Desktop z menu Start i poczekaj, aż ikona wieloryba w zasobniku
systemowym przestanie się animować. Następnie wejdź w
**Settings → Resources → WSL Integration** i włącz suwak przy dystrybucji **Ubuntu**
— dzięki temu komendy `docker` i `docker compose` zadziałają wprost w Ubuntu,
korzystając z tego samego silnika.

!!! info "Skąd wziąć winget"
    `winget` jest wbudowany w Windows 11 oraz w Windows 10 od wersji 1809
    (build 17763). Jeśli komenda nie zadziała, pobierz
    [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/)
    ręcznie ze strony producenta albo doinstaluj
    [Instalator aplikacji](https://apps.microsoft.com/detail/9nblggh4nns1)
    ze Sklepu Microsoft.

## 3. Otwórz Ubuntu

Kliknij w pasek wyszukiwania obok przycisku Start (albo naciśnij klawisz Windows),
wpisz **ubuntu** i kliknij aplikację:

![Ikona Ubuntu](../assets/ubuntu-icon.svg){ width="48" }

Przy pierwszym uruchomieniu Ubuntu poprosi o nazwę użytkownika i hasło — to konto
wewnątrz Linuksa, niezależne od konta Windows. Hasło zapamiętaj, będzie potrzebne
przy `sudo`.

## 4. Zainstaluj narzędzia systemowe

W oknie Ubuntu wpisz:

```bash
sudo apt update && sudo apt install -y git make openssl
```

Od tego momentu instalacja przebiega dokładnie tak, jak na Linuksie — bo to jest Linux.

## 5. Sklonuj repozytorium

Trzymaj repozytorium w systemie plików Linuksa — katalog domowy Ubuntu jest do tego
najlepszym miejscem:

```bash
cd ~
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

!!! warning "Nie klonuj na dysk C:"
    Nie umieszczaj repozytorium w `/mnt/c/…`, czyli na dysku C:, pulpicie ani
    w Dokumentach. Na granicy systemów plików Windows i Linuksa kontenery działają
    bardzo wolno, a uprawnienia plików nie przenoszą się poprawnie.

!!! tip "Podgląd plików z Eksploratora"
    Wpisz w Ubuntu `explorer.exe .` albo otwórz w Eksploratorze ścieżkę
    `\\wsl$\Ubuntu\home`.

## Instalacja przez Git Bash

Ta ścieżka **też wymaga WSL2** — Docker Desktop bez niego nie działa, więc krok 1
powyżej wykonaj również tutaj. Różnica polega na tym, że `make` uruchamiasz w Git Bashu
po stronie Windows, a nie w Ubuntu.

### 1. Komplet narzędzi jedną komendą (winget)

Otwórz **PowerShell** — naciśnij klawisz Windows, zacznij pisać **powershell**
i kliknij aplikację **Windows PowerShell**:

![Ikona Windows PowerShell](../assets/powershell-icon.png){ width="48" }

W otwartym oknie wklej poniższe komendy:

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

!!! tip "Brakuje tylko Dockera?"
    Jeśli Git i `make` już masz, Dockera możesz doinstalować z poziomu repozytorium:
    `make install-docker` w Git Bash uruchamia
    `winget install -e --id Docker.DockerDesktop --source winget`. Gdy wingeta nie ma,
    komenda odsyła do [Instalatora aplikacji](https://apps.microsoft.com/detail/9nblggh4nns1?hl=pl-PL&gl=PL)
    ze Sklepu Microsoft.

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

### 2. Uruchom Docker Desktop

Uruchom Docker Desktop z menu Start i poczekaj, aż ikona wieloryba w zasobniku
systemowym przestanie się animować. Przy pierwszym uruchomieniu Docker sam sprawdzi
WSL2 i — jeśli nie był jeszcze włączony — dokończy jego konfigurację, prosząc o restart
komputera.

### 3. Otwórz nowe okno Git Bash

Kliknij w pasek wyszukiwania obok przycisku Start (albo naciśnij klawisz Windows),
wpisz **git bash**, a następnie kliknij aplikację **Git Bash** — poznasz ją po
kolorowym rombie:

![Ikona Git Bash](../assets/git-bash-icon.png){ width="48" }

!!! warning "Ważne"
    Wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD ani PowerShell.
    Otwórz **świeże** okno terminala — dopiero nowo uruchomiony terminal widzi `make`
    dopisany do PATH przez winget.

### 4. Sklonuj repozytorium na pulpit

Git Bash startuje w katalogu domowym użytkownika, więc najpierw przejdź na pulpit —
dzięki temu katalog `bpp-deploy` będziesz mieć zawsze pod ręką:

```bash
cd Desktop
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

!!! note "Pulpit w polskim Windows"
    Na dysku katalog pulpitu nazywa się `Desktop` także w polskiej wersji Windows.
    Jeśli `cd Desktop` zgłosi brak katalogu, pulpit przejął OneDrive — wpisz wtedy
    `cd OneDrive/Desktop` albo `cd OneDrive/Pulpit`.

!!! tip "Ścieżka katalogu konfiguracyjnego"
    Przy [pierwszym uruchomieniu](pierwsze-uruchomienie.md) `make` zapyta o katalog
    konfiguracyjny. W Git Bashu możesz podać ścieżkę po windowsowemu — `C:\dane\bpp`,
    `C:/dane/bpp`, a także wklejoną razem z cudzysłowami przez „Kopiuj jako ścieżkę"
    z Eksploratora (`"C:\dane\bpp"`). Każda z tych postaci jest przeliczana na
    `/c/dane/bpp`, czyli zapis używany przez Git Bash.

➡️ Przejdź do **[Pierwszego uruchomienia](pierwsze-uruchomienie.md)**.
