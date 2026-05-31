# Instalacja — Linux

Otwórz **Terminal** (zazwyczaj skrót `Ctrl+Alt+T` lub znajdziesz go w menu aplikacji).

## 1. Narzędzia i Docker

Wybierz swoją dystrybucję:

=== "Debian / Ubuntu"

    ```bash
    sudo apt update
    sudo apt install -y git make openssl gettext
    ```

    Zainstaluj Docker Engine — oficjalna instrukcja dla
    [Debian](https://docs.docker.com/engine/install/debian/) lub
    [Ubuntu](https://docs.docker.com/engine/install/ubuntu/) (zawiera Docker Compose).

    !!! tip
        Możesz też zainstalować Docker poleceniem `make install-docker` po sklonowaniu
        repo (Debian/Ubuntu — używa `apt` i oficjalnego repozytorium Dockera).

=== "Fedora"

    ```bash
    sudo dnf install -y git make openssl gettext
    ```

    Zainstaluj Docker Engine —
    [oficjalna instrukcja dla Fedory](https://docs.docker.com/engine/install/fedora/)
    (zawiera Docker Compose).

=== "Arch Linux"

    ```bash
    sudo pacman -Sy --noconfirm git make openssl gettext
    ```

    Zainstaluj Docker Engine:

    ```bash
    sudo pacman -Sy --noconfirm docker docker-compose
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    ```

    Wyloguj się i zaloguj ponownie, aby uprawnienia do Dockera zaczęły działać.

=== "openSUSE"

    ```bash
    sudo zypper install -y git make openssl gettext-runtime
    ```

    Zainstaluj Docker Engine —
    [oficjalna instrukcja dla SLES/openSUSE](https://docs.docker.com/engine/install/sles/)
    (zawiera Docker Compose).

## 2. Uprawnienia do Dockera (grupa `docker`)

Dodaj swojego użytkownika do grupy `docker`, żeby `make` i `docker compose` działały
**bez** `sudo`:

```bash
sudo usermod -aG docker $USER
```

Aby zmiana zaczęła obowiązywać, **wyloguj się i zaloguj ponownie** (na sesji graficznej
najprościej całkowicie wylogować, a w SSH zakończyć sesję i wejść na nowo).
Alternatywnie odśwież grupy w bieżącej powłoce poleceniem `newgrp docker` — działa
tylko w tym jednym terminalu.

Sprawdź, czy działa:

```bash
docker run --rm hello-world
```

Polecenie powinno wykonać się bez `sudo`. Jeżeli zamiast tego widzisz
`permission denied while trying to connect to the Docker daemon socket` —
przelogowanie nie zostało wykonane.

!!! warning "Uwaga bezpieczeństwa"
    Członkostwo w grupie `docker` jest faktycznie równoważne uprawnieniom roota na
    hoście (przez Dockera można zamontować `/` i wyjść z kontenera). Dodawaj do tej
    grupy tylko zaufane konta administratorów.

## 3. Sklonuj repozytorium

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

➡️ Przejdź do **[Pierwszego uruchomienia](pierwsze-uruchomienie.md)**.
