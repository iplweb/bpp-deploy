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
	@echo "    repull               - Remove local iplweb/* images and pull fresh"
	@echo "    refresh              - Full refresh (prune, pull, recreate)"
	@echo "    restart-appserver    - Restart application server only"
	@echo "    wait                 - Wait for Docker build, then repull and restart"
	@echo ""
	@echo "  Database:"
	@echo "    migrate              - Run Django migrations (stops workers safely)"
	@echo "    backup               - Run db-backup + media-backup"
	@echo "    backup-cycle         - Full cycle: backup + rclone sync + Rollbar notify"
	@echo "    db-backup            - Create parallel database backup (tar.gz)"
	@echo "    media-backup         - Create media files backup (tar.gz)"
	@echo "    dbshell              - Django database shell"
	@echo "    dbshell-psql         - Direct PostgreSQL shell"
	@echo ""
	@echo "  Shell access:"
	@echo "    shell                - Bash in application container"
	@echo "    shell-python         - Django Python shell"
	@echo "    shell-plus           - Django shell_plus (enhanced)"
	@echo "    shell-dbserver       - Bash in database container"
	@echo "    createsuperuser      - Create Django admin user"
	@echo "    changepassword       - Change admin password"
	@echo ""
	@echo "  Logs & monitoring:"
	@echo "    logs                 - View all service logs"
	@echo "    logs-appserver       - View application server logs"
	@echo "    logs-celery          - View Celery worker logs"
	@echo "    logs-dbserver        - View database logs"
	@echo "    logs-denorm          - View denorm-queue logs"
	@echo "    ps                   - Show running containers"
	@echo "    health               - Quick health check of all services"
	@echo "    check-quic           - Verify HTTP/3 (QUIC) UDP port availability"
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
	@echo "    generate-snakeoil-certs - Generate self-signed SSL certificates"
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
	@echo "    test-email           - Test email configuration"
	@echo ""
	@echo "  Versioning:"
	@echo "    version              - Show current version (from git tags)"
	@echo "    release              - Tag current commit with CalVer date"
	@echo ""

endif

# These targets are available in both first-run and normal modes
include mk/init.mk
include mk/remote.mk
