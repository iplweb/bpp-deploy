# BPP Deploy

Konfiguracja wdrożeniowa systemu **[BPP (Bibliografia Publikacji Pracowników)](https://github.com/iplweb/bpp)** —
orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

To repozytorium zawiera **wyłącznie warstwę wdrożeniową**: pliki Docker Compose,
`Makefile`, skrypty konfiguracyjne i monitoring. Kod aplikacji Django żyje w osobnym
repozytorium [iplweb/bpp](https://github.com/iplweb/bpp) i wewnątrz obrazów `iplweb/*`.

!!! tip "Szybki start"
    Najkrótsza droga do działającej instancji jest opisana w
    [README repozytorium](https://github.com/iplweb/bpp-deploy#readme): zainstaluj
    zależności swojego systemu → `make` → uzupełnij `.env` → `make run`. Pełne,
    rozbite na kroki instrukcje znajdziesz w sekcji **[Instalacja](instalacja/index.md)**.

## Co znajdziesz w tej dokumentacji

<div class="grid cards" markdown>

-   :material-rocket-launch: **[Instalacja](instalacja/index.md)**

    Krok po kroku dla Linux, macOS i Windows oraz wspólne kroki pierwszego uruchomienia.

-   :material-cog: **[Konfiguracja](konfiguracja/architektura.md)**

    Architektura konfiguracji, SSL, multi-host, limity zasobów, wersje PostgreSQL.

-   :material-console: **[Eksploatacja](eksploatacja/komendy.md)**

    Komendy `make`, baza danych, backupy, przenosiny serwera na inną maszynę, wydania.

-   :material-chart-line: **[Monitoring i logi](monitoring/przeglad.md)**

    Netdata, Loki, Grafana, Alloy, Dozzle, alerty na telefon i monitoring wolnych zapytań.

-   :material-sitemap: **[Architektura](architektura/uslugi.md)**

    Usługi, przepływ danych, healthchecki, autoheal i zadania okresowe Ofelii.

-   :material-wrench: **[Rozwiązywanie problemów](rozwiazywanie-problemow.md)**

    Najczęstsze problemy przy starcie i ich rozwiązania.

</div>

## Stack

Django + PostgreSQL, Celery + Redis (broker i result backend), Nginx, Ofelia (cron),
Netdata (metryki i alerty → ntfy.sh) + Loki + Grafana + Alloy (logi), własne obrazy
`iplweb/*`.

---

!!! info "Wsparcie komercyjne"
    Wsparcie komercyjne zapewnia [IPL Web](https://bpp.iplweb.pl).
