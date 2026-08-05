# BPP Deploy - Makefile
# Wersja: patrz `make version`
#
# Przy pierwszym uruchomieniu `make` bez .env, zostaniesz poproszony o podanie
# ścieżki do katalogu konfiguracyjnego. Szczegóły w .env.sample.

# --- First-run detection ---
ifeq ($(wildcard .env),)
  FIRST_RUN := 1
else
  include .env
  ifeq ($(strip $(BPP_CONFIGS_DIR)),)
    FIRST_RUN := 1
  endif
endif

# --- Testy: dzialaja w OBU trybach ---
#
# Definiowane PRZED `ifdef FIRST_RUN` swiadomie. Swiezo sklonowane repo nie ma
# repo-lokalnego .env, a wtedy Makefile definiuje wylacznie `setup` — czyli
# `make test` nie istnialoby dokladnie tam, gdzie jest najbardziej potrzebny:
# na maszynie deweloperskiej, przed pushem.
#
# Skrypty wolane BEZPOSREDNIO, a nie przez `$(MAKE) test-waf`: tamte targety
# siedza w mk/misc.mk, includowanym dopiero w galezi normalnej.
#
# Zaden z trzech nie potrzebuje .env ani dzialajacej instalacji BPP — tylko
# dockera. Kolejnosc od najtanszego: alloy ~30 s, Makefile ~3 min (stawia
# nginksa), WAF ~3 min (stawia webserver + atrape backendu).
#
# CI (.github/workflows/ci.yml) wola te same trzy skrypty w OSOBNYCH jobach,
# dla rownoleglosci i czytelnych nazw. Ten target jest dla petli lokalnej.
# Dokladajac tu czwarty skrypt, dopisz go takze do CI — inaczej rozjada sie
# ciche pokrycie: lokalnie zielone, na PR-ze nieuruchamiane.
.PHONY: test
test:
	@./scripts/test-alloy.sh
	@bash tests/test_makefile.sh
	@./scripts/test-waf.sh

ifdef FIRST_RUN

.DEFAULT_GOAL := setup

.PHONY: setup

setup:
	@if ! command -v docker >/dev/null 2>&1; then \
	  echo ""; \
	  echo "=== Docker nie jest zainstalowany ==="; \
	  echo ""; \
	  echo "Docker jest wymagany do dzialania BPP Deploy."; \
	  echo "Zainstaluj go poleceniem:"; \
	  echo ""; \
	  echo "    make install-docker"; \
	  echo ""; \
	  exit 1; \
	fi
	@if ! docker compose version >/dev/null 2>&1; then \
	  echo ""; \
	  echo "=== Docker Compose nie jest zainstalowany ==="; \
	  echo ""; \
	  echo "Docker Compose (plugin) jest wymagany do dzialania BPP Deploy."; \
	  echo "Zainstaluj go poleceniem:"; \
	  echo ""; \
	  echo "    make install-docker"; \
	  echo ""; \
	  exit 1; \
	fi
	@echo ""
	@echo "=== BPP Deploy - pierwsze uruchomienie ==="
	$(MAKE) init-configs
	$(MAKE) generate-grafana-datasources
	$(MAKE) configure-resources

else
# === Normal operation (BPP_CONFIGS_DIR is set) ===

-include $(BPP_CONFIGS_DIR)/.env
ifneq ($(wildcard $(BPP_CONFIGS_DIR)/.env),)
  export $(shell sed 's/=.*//' $(BPP_CONFIGS_DIR)/.env)
endif
export BPP_CONFIGS_DIR

.DEFAULT_GOAL := help

include mk/deployment.mk
include mk/database.mk
include mk/shell.mk
include mk/logs.mk
include mk/celery.mk
include mk/configs.mk
include mk/docker.mk
include mk/django.mk
include mk/doctor.mk
include mk/rclone.mk
include mk/ssl.mk
include mk/misc.mk
include mk/version.mk

BPP_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "brak")

help:
	@echo ""
	@echo "BPP Docker Deployment $(BPP_VERSION)"
	@echo ""
	@echo "  =================================================="
	@echo "  Katalog konfiguracyjny: $(BPP_CONFIGS_DIR)"
	@echo "  =================================================="
	@echo ""
	@echo "  Deployment:"
	@echo "    run                  - Full deployment (pull, build, configs, up)"
	@echo "    up                   - Start all services (force recreate)"
	@echo "    up-quick             - Quick start without recreation"
	@echo "    stop                 - Stop all services"
	@echo "    pull                 - Pull latest Docker images"
	@echo "    refresh              - Full refresh (prune, pull, recreate)"
	@echo "    restart-appserver    - Restart application server only"
	@echo "    wait                 - Wait for Docker build, then pull and restart"
	@echo "    test-upgrade         - Proba generalna: migracje kandydata na kopii bazy (TAG=...)"
	@echo "    test-upgrade-clean   - Sprzatniecie shadow stacka po nieudanym test-upgrade"
	@echo ""
	@echo "  Auto-aktualizacja:"
	@echo "    autoupdate             - Petla: nowy obraz/commit -> make run (pierwszy plan)"
	@echo "    screen-with-autoupdate - Start petli w tle, w sesji screen"
	@echo "    setup-autoupdate-cron  - Wpis cron pilnujacy petli (przezywa reboot i crash)"
	@echo "    remove-autoupdate-cron - Usun wpis cron auto-aktualizacji"
	@echo "    test-autoupdate        - Unit-testy scripts/autoupdate.sh"
	@echo "    test-autoupdate-cron   - Unit-testy scripts/setup-autoupdate-cron.sh"
	@echo ""
	@echo "  Database:"
	@echo "    migrate              - Run Django migrations (stops workers safely)"
	@echo "    backup               - Run db-backup + media-backup"
	@echo "    backup-cycle         - Full cycle: backup + rclone sync + Rollbar notify"
	@echo "    db-backup            - Create parallel database backup (tar.gz)"
	@echo "    media-backup         - Create media files backup (tar.gz)"
	@echo "    restore              - Restore db+media from tar.gz pair (newest by default)"
	@echo "                           Flags: PICK=1 TIMESTAMP=... DB_ONLY=1 MEDIA_ONLY=1 NO_SAFETY=1 YES=1"
	@echo "    dbshell              - Django database shell"
	@echo "    dbshell-psql         - Direct PostgreSQL shell"
	@echo ""
	@echo "  Shell access:"
	@echo "    shell                - Bash in application container"
	@echo "    shell-python         - Django Python shell"
	@echo "    shell-plus           - Django shell_plus (enhanced)"
	@echo "    shell-dbserver       - Bash in database container"
	@echo "    netdata-shell        - Bash in netdata container"
	@echo "    createsuperuser      - Create Django admin user"
	@echo "    changepassword       - Change admin password"
	@echo ""
	@echo "  Logs & monitoring:"
	@echo "    logs                 - View all service logs"
	@echo "    logs-appserver       - View application server logs"
	@echo "    logs-celery          - View Celery worker logs"
	@echo "    logs-dbserver        - View database logs"
	@echo "    logs-denorm          - View denorm-queue logs"
	@echo "    logs-netdata         - Tail netdata logs"
	@echo "    ps                   - Show running containers"
	@echo "    request-stats        - Peak req/s per IP (admin/api/reszta) z access logow nginx"
	@echo "    health               - Quick health check of all services"
	@echo "    check-quic           - Verify HTTP/3 (QUIC) UDP port availability"
	@echo "    (powiadomienia ntfy/mail/rollbar: patrz sekcja Diagnostyka)"
	@echo ""
	@echo "  Celery/Background tasks:"
	@echo "    celery-stats         - View active tasks and queues"
	@echo "    celery-status        - Check Celery worker status"
	@echo "    denorm-rebuild       - Rebuild denormalization tables"
	@echo "    denorm-purge-queues  - Clear denormalization queue"
	@echo ""
	@echo "  Configuration:"
	@echo "    update-configs       - Regenerate templated configs (datasources.yaml)"
	@echo "    update-ssl-certs     - Reload nginx to pick up new SSL certs"
	@echo "    init-configs         - Re-initialize config directory structure"
	@echo "    configure-resources  - Tune Docker memory/CPU limits for this host"
	@echo "    create-monitoring-user - Create read-only bpp_monitor PG role (Grafana/Netdata)"
	@echo "    grant-pg-monitor     - (deprecated alias) -> create-monitoring-user"
	@echo "    pg-monitoring-setup  - slow-query log + pg_stat_statements + bpp_monitor"
	@echo "    generate-snakeoil-certs - Generate self-signed SSL certificates"
	@echo "    ssl-letsencrypt-issue   - Issue Let's Encrypt cert (staging; PROD=1 for real cert)"
	@echo "    ssl-letsencrypt-renew   - Renew Let's Encrypt certs (idempotent, daily Ofelia auto)"
	@echo "    test-letsencrypt        - Unit-tests dla scripts/letsencrypt.sh (mocked docker, no network)"
	@echo "    validate-env-quotes  - Sprawdz czy .env nie zawiera wartosci w cudzyslowach"
	@echo "    fix-env-quotes       - Auto-strip cudzyslowy z .env (z backupem .bak.<ts>)"
	@echo "    zaspawaj-wersje      - Przypnij DOCKER_VERSION do wersji dzialajacego appservera (lub TAG=...)"
	@echo "    test-docker-versions - Unit-testy logiki wersji obrazow (mock curl/docker, no network)"
	@echo ""
	@echo "  Host management:"
	@echo "    base-host-update-upgrade - Update system packages"
	@echo "    base-host-reboot    - Reboot host"
	@echo "    install-docker       - Install Docker on this host"
	@echo ""
	@echo "  Docker maintenance:"
	@echo "    docker-clean         - Clean unused Docker resources"
	@echo "    prune-orphan-volumes - Remove orphan volumes"
	@echo "    open-docker-volume   - Open Docker volume in shell"
	@echo "    rmrf                 - Remove all containers (dangerous!)"
	@echo ""
	@echo "  Django utilities:"
	@echo "    invalidate           - Invalidate Django cache"
	@echo ""
	@echo "  Diagnostyka (deploy NIE testuje juz nic automatycznie):"
	@echo "    doctor               - Interaktywne menu: mail/ntfy/rollbar/health/backup"
	@echo "    test-email           - Test email configuration"
	@echo "    test-rollbar         - Test Rollbar configuration"
	@echo "    test-ntfy            - Test ntfy push notification"
	@echo "    ntfy-test            - Deprecated alias for test-ntfy"
	@echo ""
	@echo "  Testy (nie wymagaja .env ani dzialajacej instalacji — tylko dockera):"
	@echo "    test                 - Wszystkie trzy zestawy, od najtanszego (~6-8 min)"
	@echo "    test-alloy           - Sam pipeline logow Alloy: detected_level + modsec_* (~30 s)"
	@echo "    test-waf             - Sam WAF: ModSecurity + OWASP CRS na realnych payloadach (~3 min)"
	@echo ""
	@echo "  Versioning:"
	@echo "    version              - Show current version (from git tags)"
	@echo "    release              - Tag current commit with CalVer date"
	@echo ""

endif

# These targets are available in both first-run and normal modes
include mk/init.mk
include mk/remote.mk
include mk/monitoring.mk
