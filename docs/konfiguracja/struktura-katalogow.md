# Struktura katalogów

```
~/
├── bpp-deploy/                     # To repozytorium
│   ├── .env                        # Wskazuje katalog konfiguracyjny (BPP_CONFIGS_DIR)
│   ├── Makefile
│   ├── docker-compose.*.yml
│   ├── mk/                         # Moduły Makefile
│   ├── defaults/                   # Szablonowe pliki konfiguracyjne
│   └── tests/
│
├── moja-instancja/                 # Katalog konfiguracyjny (BPP_CONFIGS_DIR)
│   ├── .env                        # Zmienne aplikacyjne (hasła, hostname)
│   ├── ssl/                        # Certyfikaty SSL (tryb manual)
│   ├── letsencrypt/                # Certyfikaty Let's Encrypt (tryb letsencrypt)
│   ├── alloy/                      # Konfiguracja Grafana Alloy
│   ├── loki/                       # Konfiguracja Loki (retencja logów)
│   ├── netdata/                    # Konfiguracja Netdata (go.d/, health.d/, alerty ntfy)
│   ├── grafana/provisioning/       # Dashboardy i datasources Grafana
│   ├── rclone/                     # Konfiguracja backupów
│   └── dozzle/                     # Użytkownicy Dozzle
│
└── backups/                        # Backupy baz danych (DJANGO_BPP_HOST_BACKUP_DIR)
```

## Trzy katalogi, które trzeba znać

| Katalog | Zmienna | Rola |
|---|---|---|
| `~/bpp-deploy/` | — | Repozytorium: Compose, Makefile, skrypty, `defaults/`. Aktualizowane przez `git pull`. |
| `moja-instancja/` | `BPP_CONFIGS_DIR` | Konfiguracja instancji: `.env`, certy, configi monitoringu. **Poza repo.** |
| `backups/` | `DJANGO_BPP_HOST_BACKUP_DIR` | Archiwa `pg_dump` i mediów. |

Te same trzy katalogi przenosisz przy [migracji na inną maszynę](../eksploatacja/przenosiny-serwera.md).

Mechanikę kopiowania `defaults/` → katalog konfiguracyjny (`copy_if_missing` vs
force-sync) opisuje [Architektura konfiguracji](architektura.md).
