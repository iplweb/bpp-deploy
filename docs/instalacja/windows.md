# Instalacja — Windows

## 1. Komplet narzędzi jedną komendą (winget)

Otwórz **PowerShell** (zwykły — instalator Dockera sam poprosi o uprawnienia
administratora) i wklej:

```powershell
winget install -e --id Git.Git
winget install -e --id Docker.DockerDesktop
winget install -e --id ezwinports.make
```

To komplet wymaganych narzędzi:

- **Git for Windows** — dostarcza **Git Bash**, czyli terminal z narzędziami Unix
  (`bash`, `grep`, `sed`, `openssl` — `make` korzysta z nich wszystkich)
- **Docker Desktop for Windows** — Docker Engine razem z Docker Compose
- **GNU Make 4.4** (pakiet `ezwinports.make`) — instalacja *portable*, winget sam
  dopisuje `make` do PATH

Nie musisz instalować Chocolatey ani Scoopa.

!!! info "Skąd wziąć winget"
    `winget` jest wbudowany w Windows 11 oraz w Windows 10 od wersji 1809
    (build 17763), gdzie dostarcza go „Instalator aplikacji”. Sprawdź go komendą
    `winget --version`. Jeśli nie zadziała — zainstaluj lub zaktualizuj
    [Instalator aplikacji](https://apps.microsoft.com/detail/9nblggh4nns1)
    ze Sklepu Microsoft albo skorzystaj z [instalacji ręcznej](#instalacja-bez-wingeta).

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

---

## Instalacja bez wingeta

Dotyczy Windows 10 starszego niż 1809 albo stacji z zablokowanym Sklepem Microsoft.
Pobierz i zainstaluj ręcznie (klikając „Dalej" w instalatorach):

- [Git for Windows](https://gitforwindows.org/)
- [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/)

GNU Make zainstaluj w **PowerShellu jako Administrator** (kliknij prawym przyciskiem
na menu Start > „Terminal (Administrator)" lub „Windows PowerShell (Administrator)")
przez [Chocolatey](https://chocolatey.org/install):

```powershell
choco install make
```

…albo przez [Scoop](https://scoop.sh/):

```powershell
scoop install make
```

Dalej wróć do [kroku 2](#2-uruchom-docker-desktop).
