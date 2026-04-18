.PHONY: do-migrate stop-denorm-celery start-denorm-celery migrate \
       backup db-backup media-backup dbshell dbshell-psql ps-dbserver \
       dump-local-postgresql-and-copy-to-remote \
       restore-db-stop-servers restore-db-remove-db-rebuild-db-rm-backup \
       restore-remote-db-from-dump restore-remote-db-from-dump-dont-backup \
       upgrade-postgres test-upgrade-postgres \
       push-local-bpp-db-to-remote

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
	docker compose exec appserver uv run src/manage.py migrate

stop-denorm-celery:
	docker compose stop denorm-queue workerserver-general workerserver-denorm celerybeat

start-denorm-celery:
	docker compose up -d --wait denorm-queue workerserver-general workerserver-denorm celerybeat

migrate: stop-denorm-celery do-migrate start-denorm-celery

backup: db-backup media-backup

db-backup:
	@mkdir -p $(DJANGO_BPP_HOST_BACKUP_DIR)
	@echo "Creating parallel database backup ($(PARALLEL_JOBS) jobs)..."
	# pg_dump pisze bezposrednio do /backup w kontenerze, ktory jest
	# bind-mountem z hosta $(DJANGO_BPP_HOST_BACKUP_DIR). Nic nie laduje
	# w writable layer kontenera, wiec dbserver nie puchnie przy kolejnych
	# backupach (nawet jesli wywolanie bedzie przerwane).
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver pg_dump \
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

dbshell:
	docker compose exec appserver uv run src/manage.py dbshell

dbshell-psql:
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		psql -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		     -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME)

ps-dbserver:
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		psql -P pager=off -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		     -U $(DJANGO_BPP_DB_USER) template1 \
		     -c 'select pid as process_id, usename as username, datname as database_name, client_addr as client_address, application_name, backend_start, state, state_change, query from pg_stat_activity;'

dump-local-postgresql-and-copy-to-remote:
	pg_dump -Fp $(DJANGO_BPP_DB_NAME) | gzip > local.pgdump.gz
	docker compose cp local.pgdump.gz dbserver:/

restore-db-stop-servers:
	docker compose stop appserver workerserver-general workerserver-denorm denorm-queue celerybeat

restore-db-remove-db-rebuild-db-rm-backup:
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		dropdb --force -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		       -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME)
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
		createdb -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
		         -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME)
	docker compose exec dbserver gzip -d /local.pgdump.gz
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
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
