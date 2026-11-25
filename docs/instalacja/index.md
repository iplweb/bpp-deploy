# Instalacja

Instrukcje są podzielone na sekcje per system operacyjny. Po zakończeniu kroków
właściwych dla Twojego systemu przejdź do **[Pierwszego uruchomienia](pierwsze-uruchomienie.md)** —
te kroki są identyczne dla wszystkich platform.

!!! warning "Wymagania sprzętowe"
    **Minimum 12 GB RAM, zalecane 16 GB+.** Do tego ≥2 rdzenie CPU (zalecane 4+) i
    **minimum 40 GB dysku, zalecane 60 GB+**, plus miejsce na bazę i backupy (najlepiej
    SSD) — system i obrazy to ok. 20 GB, do tego 7 nocnych kopii, archiwum obrazów do
    odtworzenia bez Docker Huba (ok. 1,5 GB, tworzone tylko przy ≥ 10 GB wolnego i
    zajętości ≤ 80% — [szczegóły](../eksploatacja/backup-i-rclone.md#archiwum-obrazow))
    i zapas na `make test-upgrade` (2,5× rozmiar bazy). Przy 12 GB RAM stack się
    mieści, ale ciasno; dopiero od 16 GB nadwyżka RAM realnie zasila bazę, aplikację i
    workery. `make configure-resources` (odpalany przy pierwszym `make`) dobiera limity
    pod wykryty host i ostrzega poniżej 12 GB. Szczegóły:
    [Limity zasobów](../konfiguracja/limity-zasobow.md).

| System | Instrukcja |
|--------|------------|
| 🐧 **Linux** (Debian / Ubuntu / Fedora / Arch / openSUSE) | [→ instrukcja dla Linuksa](linux.md) |
| 🍎 **macOS** (Intel + Apple Silicon) | [→ instrukcja dla macOS](macos.md) |
| 🪟 **Windows** (10 / 11) | [→ instrukcja dla Windows](windows.md) |

Po instalacji zależności i sklonowaniu repozytorium wszystkie platformy łączą się
w jednym miejscu: **[Pierwsze uruchomienie](pierwsze-uruchomienie.md)**.
