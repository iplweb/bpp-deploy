# Instalacja — macOS

Otwórz **Terminal** — znajdziesz go w Finderze pod ścieżką *Programy > Narzędzia > Terminal*
(albo wyszukaj „Terminal" przez Spotlight: `Cmd+Spacja`).

## 1. Xcode Command Line Tools

Zawiera `git` i `make`. Wpisz w Terminalu:

```bash
xcode-select --install
```

Pojawi się okno z prośbą o potwierdzenie — kliknij **Zainstaluj** i poczekaj na zakończenie.

## 2. Docker Desktop

Zainstaluj [Docker Desktop dla macOS](https://docs.docker.com/desktop/install/mac-install/) —
pobierz ze strony (wybierz wariant zgodny z Twoim Makiem: **Apple Silicon** dla M1/M2/M3/M4
lub **Intel** dla starszych modeli), otwórz plik `.dmg` i przeciągnij Docker do folderu
Programy. Uruchom Docker Desktop i poczekaj, aż ikona w pasku menu przestanie się animować.

## 3. `envsubst` (gettext)

Potrzebny do generowania konfiguracji. Jeśli nie masz jeszcze [Homebrew](https://brew.sh/),
najpierw go zainstaluj, a potem:

```bash
brew install gettext
```

## 4. Sklonuj repozytorium

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

➡️ Przejdź do **[Pierwszego uruchomienia](pierwsze-uruchomienie.md)**.
