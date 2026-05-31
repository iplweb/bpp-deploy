# Instalacja — Windows

## 1. Git for Windows i Docker Desktop

Pobierz i zainstaluj (klikając „Dalej" w instalatorach):

- [Git for Windows](https://gitforwindows.org/) — dostarcza **Git Bash**, czyli terminal
  z narzędziami Unix
- [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/) —
  po instalacji uruchom Docker Desktop i poczekaj, aż ikona w zasobniku przestanie się animować

## 2. GNU Make

Otwórz **PowerShell jako Administrator** (kliknij prawym przyciskiem na menu Start >
„Terminal (Administrator)" lub „Windows PowerShell (Administrator)") i wpisz:

```powershell
choco install make
```

Jeśli nie masz [Chocolatey](https://chocolatey.org/install), możesz zamiast tego użyć
[Scoop](https://scoop.sh/):

```powershell
scoop install make
```

## 3. Sklonuj repozytorium (w Git Bash)

Otwórz **Git Bash** (znajdziesz go w menu Start po wpisaniu „Git Bash") i sklonuj repozytorium:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

!!! warning "Ważne"
    Od tego momentu wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD
    ani PowerShell.

➡️ Przejdź do **[Pierwszego uruchomienia](pierwsze-uruchomienie.md)**.
