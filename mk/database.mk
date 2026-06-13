.PHONY: do-migrate stop-denorm-celery start-denorm-celery migrate \
       backup db-backup media-backup restore dbshell dbshell-psql ps-dbserver \
       dump-local-postgresql-and-copy-to-remote \
       restore-db-stop-servers restore-db-remove-db-rebuild-db-rm-backup \
       restore-remote-db-from-dump restore-remote-db-from-dump-dont-backup \
       upgrade-postgres test-upgrade-postgres \
       push-local-bpp-db-to-remote \
       migrate-collation-dump migrate-collation-fix migrate-collation-load

# Katalog backupow na hoscie. Nowa nazwa: DJANGO_BPP_HOST_BACKUP_DIR
# (stara: DJANGO_BPP_BACKUP_DIR - fallback dla deploymentow ktore jeszcze
# nie przeszly migracji przez init-configs).
ifndef DJANGO_BPP_HOST_BACKUP_DIR
  ifdef DJANGO_BPP_BACKUP_DIR
    DJANGO_BPP_HOST_BACKUP_DIR := $(DJANGO_BPP_BACKUP_DIR)
  endif
endif
DJANGO_BPP_HOST_BACKUP_DIR ?= $(abspath $(BPP_CONFIGS_DIR)/..)/backups

# Wyeksportuj do srodowiska, zeby docker compose widzial te zmienna podczas
# interpolacji w docker-compose.database*.yml (volume mount /backup).
# Dotyczy zarowno deploymentow ktore maja stara nazwe w .env i korzystaja
# z fallbacku powyzej, jak i deploymentow uzywajacych computed default.
export DJANGO_BPP_HOST_BACKUP_DIR

BACKUP_TIMESTAMP := $(shell date +%Y%m%d-%H%M%S)
BACKUP_DIRNAME := db-backup-$(BACKUP_TIMESTAMP)
BACKUP_TAR := $(BACKUP_DIRNAME).tar.gz
BACKUP_FULL_PATH := $(DJANGO_BPP_HOST_BACKUP_DIR)/$(BACKUP_TAR)

MEDIA_BACKUP_TAR := media-backup-$(BACKUP_TIMESTAMP).tar.gz
MEDIA_BACKUP_FULL_PATH := $(DJANGO_BPP_HOST_BACKUP_DIR)/$(MEDIA_BACKUP_TAR)

PARALLEL_JOBS ?= 4

do-migrate:
	docker compose exec appserver python src/manage.py migrate

stop-denorm-celery:
	docker compose stop denorm-queue workerserver celerybeat

start-denorm-celery:
	docker compose up -d --wait denorm-queue workerserver celerybeat

migrate: stop-denorm-celery do-migrate start-denorm-celery

backup: db-backup media-backup

db-backup:
	@mkdir -p $(DJANGO_BPP_HOST_BACKUP_DIR)
	@echo "Creating parallel database backup ($(PARALLEL_JOBS) jobs)..."
	# pg_dump pisze bezposrednio do /backup w kontenerze, ktory jest
	# bind-mountem z hosta $(DJANGO_BPP_HOST_BACKUP_DIR). Nic nie laduje
	# w writable layer kontenera, wiec dbserver nie puchnie przy kolejnych
	# backupach (nawet jesli wywolanie bedzie przerwane).
	@docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver pg_dump \
		-Fd \
		-j $(PARALLEL_JOBS) \
		-h $(DJANGO_BPP_DB_HOST) \
		-p $(DJANGO_BPP_DB_PORT) \
		-U $(DJANGO_BPP_DB_USER) \
		$(DJANGO_BPP_DB_NAME) \
		-f /backup/$(BACKUP_DIRNAME)
	@echo "Archiving backup..."
	docker compose exec dbserver tar czf /backup/$(BACKUP_TAR) -C /backup $(BACKUP_DIRNAME)
	docker compose exec dbserver rm -rf /backup/$(BACKUP_DIRNAME)
	@echo "Backup saved to: $(BACKUP_FULL_PATH)"
	@echo "Restore: tar xzf $(BACKUP_TAR) && pg_restore -Fd -j $(PARALLEL_JOBS) -d $(DJANGO_BPP_DB_NAME) $(BACKUP_DIRNAME)"

media-backup:
	@mkdir -p $(DJANGO_BPP_HOST_BACKUP_DIR)
	@echo "Creating media files backup..."
	# docker run --rm tworzy efemeryczny kontener alpine ktory po tar czf
	# jest usuwany. Volumen media jest montowany read-only, katalog backupow
	# na hoscie - jako /backup. Dziala niezaleznie od tego czy appserver
	# /workery sa uruchomione.
	docker run --rm \
		-v $(COMPOSE_PROJECT_NAME)_media:/src:ro \
		-v $(DJANGO_BPP_HOST_BACKUP_DIR):/backup \
		alpine \
		tar czf /backup/$(MEDIA_BACKUP_TAR) -C /src .
	@echo "Media backup saved to: $(MEDIA_BACKUP_FULL_PATH)"
	@echo "Restore: tar xzf $(MEDIA_BACKUP_TAR) -C /mediaroot/"

# Restore z backupow zrobionych przez `make backup` (lub backup-cycle).
# Cala logika w scripts/restore.sh - target jest tylko thin wrapperem.
#
# Uzycie:
#   make restore                          # najnowsza para db+media, z safety-backup
#   make restore PICK=1                   # interaktywny wybor (fzf jesli jest)
#   make restore TIMESTAMP=20260428-140218 # konkretna para
#   make restore DB_ONLY=1                # tylko baza
#   make restore MEDIA_ONLY=1             # tylko media
#   make restore NO_SAFETY=1              # pomin safety-backup biezacego stanu
#   make restore YES=1                    # noninteractive (auto-yes na confirm)
RESTORE_FLAGS :=
ifdef TIMESTAMP
  RESTORE_FLAGS += --timestamp=$(TIMESTAMP)
endif
ifdef PICK
  RESTORE_FLAGS += --pick
endif
ifdef DB_ONLY
  RESTORE_FLAGS += --db-only
endif
ifdef MEDIA_ONLY
  RESTORE_FLAGS += --media-only
endif
ifdef NO_SAFETY
  RESTORE_FLAGS += --no-safety-backup
endif
ifdef YES
  RESTORE_FLAGS += --yes
endif

restore:
	@bash scripts/restore.sh $(RESTORE_FLAGS)

dbshell:
	docker compose exec appserver python src/manage.py dbshell

dbshell-psql:
	@docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		psql -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		     -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME)

ps-dbserver:
	@docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		psql -P pager=off -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		     -U $(DJANGO_BPP_DB_USER) template1 \
		     -c 'select pid as process_id, usename as username, datname as database_name, client_addr as client_address, application_name, backend_start, state, state_change, query from pg_stat_activity;'

dump-local-postgresql-and-copy-to-remote:
	pg_dump -Fp $(DJANGO_BPP_DB_NAME) | gzip > local.pgdump.gz
	docker compose cp local.pgdump.gz dbserver:/

restore-db-stop-servers:
	docker compose stop appserver workerserver denorm-queue celerybeat

restore-db-remove-db-rebuild-db-rm-backup:
	@if [ "$(YES)" != "1" ]; then \
		echo "!!! UWAGA: ta operacja BEZPOWROTNIE skasuje baze '$(DJANGO_BPP_DB_NAME)'"; \
		echo "    (dropdb --force) i odtworzy ja z /local.pgdump."; \
		echo "    Aby pominac to pytanie w skryptach/automatyzacji: make <target> YES=1"; \
		printf "    Wpisz 'yes' aby kontynuowac: "; \
		read ans; \
		[ "$$ans" = "yes" ] || { echo "Przerwano — baza nietknieta."; exit 1; }; \
	fi
	@docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		dropdb --force -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		       -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME)
	@docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		createdb -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		         -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME)
	docker compose exec dbserver gzip -d /local.pgdump.gz
	@docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		psql -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		     -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME) -f /local.pgdump
	docker compose exec dbserver rm /local.pgdump

restore-remote-db-from-dump: db-backup restore-db-stop-servers restore-db-remove-db-rebuild-db-rm-backup up logs

restore-remote-db-from-dump-dont-backup: restore-db-stop-servers restore-db-remove-db-rebuild-db-rm-backup up logs

push-local-bpp-db-to-remote: dump-local-postgresql-and-copy-to-remote restore-remote-db-from-dump

# Major version upgrade Postgresa (np. 15 -> 18). Cala logika w skrypcie -
# Makefile target jest tylko thin wrapperem.
upgrade-postgres:
	@bash scripts/upgrade-postgres.sh

# Integration test dla upgrade-postgres.sh (16.13 -> 18.3 na izolowanej piaskownicy).
# Tworzy wlasny COMPOSE_PROJECT_NAME, BPP_CONFIGS_DIR i docker-compose.test.yml.
# Podmienia tymczasowo repo .env (cleanup trap przywraca). Oba iplweb/bpp_dbserver
# obrazy (psql-16.13 i psql-18.3) sa pullowane przez test + skrypt.
test-upgrade-postgres:
	@bash scripts/test-upgrade-postgres.sh

# Migracja kolacji libc pl_PL -> stockowy postgres. Trzy kroki (thin wrappery
# na scripts/pg-collation-migrate-{1-dump,2-fix,3-load}.sh). Pelny opis:
# docs/eksploatacja/migracja-collation-stock-pg.md.
#   make migrate-collation-dump  [STOP_APP=1] [YES=1]
#   make migrate-collation-fix   DUMPSQL=/.../db-backup-*.sql
#   make migrate-collation-load  SQL=/.../*-nocollation.sql [RECREATE=1] [YES=1]
COLLATION_DUMP_FLAGS :=
ifdef STOP_APP
  COLLATION_DUMP_FLAGS += --stop-app
endif
ifdef YES
  COLLATION_DUMP_FLAGS += --yes
endif

migrate-collation-dump:
	@bash scripts/pg-collation-migrate-1-dump.sh $(COLLATION_DUMP_FLAGS)

migrate-collation-fix:
	@if [ -z "$(DUMPSQL)" ]; then \
		echo "Uzycie: make migrate-collation-fix DUMPSQL=/.../db-backup-YYYYMMDD-HHMMSS.sql" >&2; \
		exit 1; \
	fi
	@bash scripts/pg-collation-migrate-2-fix.sh "$(DUMPSQL)"

COLLATION_LOAD_FLAGS :=
ifdef RECREATE
  COLLATION_LOAD_FLAGS += --recreate-volume
endif
ifdef YES
  COLLATION_LOAD_FLAGS += --yes
endif

migrate-collation-load:
	@if [ -z "$(SQL)" ]; then \
		echo "Uzycie: make migrate-collation-load SQL=/.../db-backup-...-nocollation.sql [RECREATE=1]" >&2; \
		exit 1; \
	fi
	@bash scripts/pg-collation-migrate-3-load.sh "$(SQL)" $(COLLATION_LOAD_FLAGS)
