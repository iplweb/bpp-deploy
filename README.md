<a href="https://github.com/iplweb/bpp"><img src="https://github.com/iplweb/bpp/raw/dev/src/bpp/static/bpp/images/logo_bpp.png" align="right" width="120" alt="BPP Logo"></a>

# BPP Deploy

[![CI](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-2026.06.12-blue)

Konfiguracja wdrożeniowa systemu **[BPP (Bibliografia Publikacji Pracowników)](https://github.com/iplweb/bpp)** — orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

📖 **Pełna dokumentacja:** [iplweb.github.io/bpp-deploy](https://iplweb.github.io/bpp-deploy/)

<p align="center">
  <b>Wsparcie komercyjne zapewnia</b><br><br>
  <a href="https://bpp.iplweb.pl"><img src="https://www.iplweb.pl/images/ipl-logo-large.png" width="150" alt="IPL Web"></a>
</p>

---

To repozytorium zawiera **wyłącznie warstwę wdrożeniową** (Docker Compose, `Makefile`, skrypty, monitoring). Kod aplikacji Django żyje w osobnym repozytorium **[iplweb/bpp](https://github.com/iplweb/bpp)** i wewnątrz obrazów `iplweb/*`.

To README pokazuje **jak zainstalować i uruchomić system BPP**. Wszystkie pozostałe tematy — konfiguracja, monitoring, backupy, upgrade PostgreSQL, przenosiny serwera, rozwiązywanie problemów — opisuje [pełna dokumentacja](https://iplweb.github.io/bpp-deploy/).

## Wymagania sprzętowe

| Zasób | Minimum | Zalecane |
|-------|---------|----------|
| **RAM** | **12 GB** | **16 GB+** |
| **CPU** | 2 rdzenie | 4+ rdzeni |
| **Dysk** | 20 GB + miejsce na bazę i backupy | SSD |

Przy 12 GB cały stack się mieści, ale ciasno (baza danych na minimum). Dopiero od 16 GB nadwyżka RAM realnie zasila bazę, aplikację i workery. Podczas pierwszego uruchomienia `make configure-resources` dobiera limity RAM/CPU per usługa pod wykryty host i ostrzega, jeśli host ma poniżej 12 GB. Szczegóły modelu limitów: [Limity zasobów](https://iplweb.github.io/bpp-deploy/konfiguracja/limity-zasobow/).

## Jak zainstalować i uruchomić system BPP przy pomocy bpp-deploy

Wybierz swój system operacyjny. Po zakończeniu kroków właściwych dla Twojego systemu przejdź do **[wspólnych kroków konfiguracji](#wspólne-kroki-konfiguracji)**, identycznych dla wszystkich platform.

| System | Instrukcja |
|--------|------------|
| 🐧 **Linux** (Debian / Ubuntu / Fedora / Arch / openSUSE) | [→ przejdź do instrukcji dla Linuksa](#linux) |
| 🍎 **macOS** (Intel + Apple Silicon) | [→ przejdź do instrukcji dla macOS](#macos) |
| 🪟 **Windows** (10 / 11) | [→ przejdź do instrukcji dla Windows](#windows) |

### Linux

Otwórz **Terminal** (zazwyczaj skrót `Ctrl+Alt+T` lub znajdziesz go w menu aplikacji).

<details>
<summary><b>Debian / Ubuntu</b></summary>

```bash
sudo apt update
sudo apt install -y git make openssl gettext
```

Zainstaluj Docker Engine — oficjalna instrukcja dla [Debian](https://docs.docker.com/engine/install/debian/) lub [Ubuntu](https://docs.docker.com/engine/install/ubuntu/) (zawiera Docker Compose).

> **Podpowiedź:** Możesz też zainstalować Docker poleceniem `make install-docker` po sklonowaniu repo (Debian/Ubuntu — używa `apt` i oficjalnego repozytorium Dockera).

</details>

<details>
<summary><b>Fedora</b></summary>

```bash
sudo dnf install -y git make openssl gettext
```

Zainstaluj Docker Engine — [oficjalna instrukcja dla Fedory](https://docs.docker.com/engine/install/fedora/) (zawiera Docker Compose).

</details>

<details>
<summary><b>Arch Linux</b></summary>

```bash
sudo pacman -Sy --noconfirm git make openssl gettext
sudo pacman -Sy --noconfirm docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Wyloguj się i zaloguj ponownie, aby uprawnienia do Dockera zaczęły działać.

</details>

<details>
<summary><b>openSUSE</b></summary>

```bash
sudo zypper install -y git make openssl gettext-runtime
```

Zainstaluj Docker Engine — [oficjalna instrukcja dla SLES/openSUSE](https://docs.docker.com/engine/install/sles/) (zawiera Docker Compose).

</details>

Dodaj użytkownika do grupy `docker`, żeby `make` i `docker compose` działały **bez** `sudo`:

```bash
sudo usermod -aG docker $USER
```

**Wyloguj się i zaloguj ponownie**, aby zmiana zaczęła obowiązywać (lub `newgrp docker` w bieżącym terminalu). Sprawdź: `docker run --rm hello-world` powinno wykonać się bez `sudo`.

> **Uwaga bezpieczeństwa:** członkostwo w grupie `docker` jest równoważne uprawnieniom roota na hoście. Dodawaj do niej tylko zaufane konta administratorów.

Sklonuj repozytorium:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

Więcej: [dokumentacja → Instalacja → Linux](https://iplweb.github.io/bpp-deploy/instalacja/linux/).

### macOS

Otwórz **Terminal** (Spotlight: `Cmd+Spacja`, wpisz „Terminal").

```bash
xcode-select --install      # git + make (potwierdź w oknie dialogowym)
brew install gettext        # envsubst (wymaga Homebrew: https://brew.sh/)
```

Zainstaluj [Docker Desktop dla macOS](https://docs.docker.com/desktop/install/mac-install/) (wybierz **Apple Silicon** dla M1/M2/M3/M4 lub **Intel**), uruchom i poczekaj, aż ikona w pasku menu przestanie się animować.

Sklonuj repozytorium:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

Więcej: [dokumentacja → Instalacja → macOS](https://iplweb.github.io/bpp-deploy/instalacja/macos/).

### Windows

Pobierz i zainstaluj:

- [Git for Windows](https://gitforwindows.org/) — dostarcza **Git Bash**
- [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/) — uruchom i poczekaj, aż ikona w zasobniku przestanie się animować

W **PowerShell jako Administrator** zainstaluj GNU Make ([Chocolatey](https://chocolatey.org/install) lub [Scoop](https://scoop.sh/)):

```powershell
choco install make
```

Otwórz **Git Bash** i sklonuj repozytorium:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

> **Ważne:** Od tego momentu wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD ani PowerShell.

Więcej: [dokumentacja → Instalacja → Windows](https://iplweb.github.io/bpp-deploy/instalacja/windows/).

## Wspólne kroki konfiguracji

Poniższe kroki wykonujesz po zakończeniu instrukcji właściwych dla Twojego systemu operacyjnego. Są identyczne dla Linux, macOS i Windows.

### 1. Pierwsze uruchomienie

```bash
make
```

Przy pierwszym uruchomieniu `make` zapyta o ścieżkę do **katalogu konfiguracyjnego** (musi znajdować się poza repozytorium — jego nazwa stanie się nazwą projektu Docker Compose) i automatycznie: utworzy strukturę katalogów, skopiuje szablony z `defaults/`, wygeneruje losowe hasła i utworzy plik `.env`.

### 2. Sprawdź i dostosuj konfigurację

Otwórz `.env` z katalogu konfiguracyjnego (ścieżka wyświetli się po pierwszym `make`, np. `/home/deploy/moja-instancja/.env`) i ustaw:

- `DJANGO_BPP_HOSTNAME` — nazwę hosta (np. `publikacje.uczelnia.pl`)
- `DJANGO_BPP_CSRF_EXTRA_ORIGINS` — dozwolone originy CSRF

Dodaj certyfikaty SSL:

```bash
# Opcja A: własne certyfikaty — skopiuj cert.pem i key.pem do podkatalogu ssl/
# Opcja B: samopodpisane (snakeoil) do testów:
make generate-snakeoil-certs
# Opcja C: Let's Encrypt (DNS musi wskazywać na serwer, port 80 osiągalny):
make ssl-letsencrypt-issue           # staging - test pipeline'u
make ssl-letsencrypt-issue PROD=1    # prawdziwy cert + flip mode na 'letsencrypt'
```

Szczegóły SSL, multi-host i limitów zasobów: [dokumentacja → Konfiguracja](https://iplweb.github.io/bpp-deploy/konfiguracja/architektura/).

### 3. Uruchom usługi

```bash
make run
```

### 4. Otwórz aplikację w przeglądarce

Główny serwis jest dostępny przez `webserver` (Nginx) na portach `80` i `443`. Otwórz aplikację pod adresem hosta zgodnym z `DJANGO_BPP_HOSTNAME` (lokalnie najprościej `DJANGO_BPP_HOSTNAME=localhost` → `https://localhost/`).

Przy pustej bazie aplikacja przekieruje do `/setup/` — kreatora, w którym tworzysz pierwsze konto administratora.

Narzędzia administracyjne i monitoring są dostępne przez Nginx (chronione uwierzytelnianiem): `https://<hostname>/grafana/`, `/netdata/`, `/flower/`, `/dozzle/`.

## Dokumentacja

Pełna dokumentacja: **[iplweb.github.io/bpp-deploy](https://iplweb.github.io/bpp-deploy/)**

| Sekcja | Tematy |
|--------|--------|
| [Instalacja](https://iplweb.github.io/bpp-deploy/instalacja/) | Linux / macOS / Windows, pierwsze uruchomienie |
| [Konfiguracja](https://iplweb.github.io/bpp-deploy/konfiguracja/architektura/) | architektura, SSL, multi-host, limity zasobów, PostgreSQL |
| [Eksploatacja](https://iplweb.github.io/bpp-deploy/eksploatacja/komendy/) | komendy `make`, baza danych, backupy, przenosiny serwera, wydania |
| [Monitoring i logi](https://iplweb.github.io/bpp-deploy/monitoring/przeglad/) | Netdata, Loki, Grafana, alerty ntfy, wolne zapytania |
| [Architektura](https://iplweb.github.io/bpp-deploy/architektura/uslugi/) | usługi, przepływ danych, healthchecks, zadania Ofelii |
| [Rozwiązywanie problemów](https://iplweb.github.io/bpp-deploy/rozwiazywanie-problemow/) | najczęstsze problemy przy starcie |
| [Rozwój pakietu](https://iplweb.github.io/bpp-deploy/rozwoj/testy/) | testy, pre-commit, backwards compatibility |

Podgląd dokumentacji lokalnie:

```bash
pip install -r docs/requirements.txt
mkdocs serve   # http://127.0.0.1:8000
```

## Licencja

MIT
