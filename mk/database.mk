.PHONY: do-migrate stop-denorm-celery start-denorm-celery migrate \
       db-backup dbshell dbshell-psql ps-dbserver \
       dump-local-postgresql-and-copy-to-remote \
       restore-db-stop-servers restore-db-remove-db-rebuild-db-rm-backup \
       restore-remote-db-from-dump restore-remote-db-from-dump-dont-backup \
       push-local-bpp-db-to-remote

DJANGO_BPP_BACKUP_DIR ?= $(dir $(BPP_CONFIGS_DIR))backups
BACKUP_DIRNAME := db-backup-$(shell date +%Y%m%d-%H%M%S)
BACKUP_TAR := $(BACKUP_DIRNAME).tar.gz
BACKUP_FULL_PATH := $(DJANGO_BPP_BACKUP_DIR)/$(BACKUP_TAR)
PARALLEL_JOBS ?= 4

do-migrate:
	docker compose exec appserver uv run src/manage.py migrate

stop-denorm-celery:
	docker compose stop denorm-queue workerserver-general workerserver-denorm celerybeat

start-denorm-celery:
	docker compose up -d --wait denorm-queue workerserver-general workerserver-denorm celerybeat

migrate: stop-denorm-celery do-migrate start-denorm-celery

db-backup:
	@mkdir -p $(DJANGO_BPP_BACKUP_DIR)
	@echo "Creating parallel database backup ($(PARALLEL_JOBS) jobs)..."
	docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver pg_dump \
		-Fd \
		-j $(PARALLEL_JOBS) \
		-h $(DJANGO_BPP_DB_HOST) \
		-p $(DJANGO_BPP_DB_PORT) \
		-U $(DJANGO_BPP_DB_USER) \
		$(DJANGO_BPP_DB_NAME) \
		-f /tmp/$(BACKUP_DIRNAME)
	@echo "Archiving backup..."
	docker compose exec dbserver tar czf /tmp/$(BACKUP_TAR) -C /tmp $(BACKUP_DIRNAME)
	docker compose exec dbserver rm -rf /tmp/$(BACKUP_DIRNAME)
	@echo "Copying archive from container..."
	docker compose cp dbserver:/tmp/$(BACKUP_TAR) $(BACKUP_FULL_PATH)
	docker compose exec dbserver rm -f /tmp/$(BACKUP_TAR)
	@echo "Backup saved to: $(BACKUP_FULL_PATH)"
	@echo "Restore: tar xzf $(BACKUP_TAR) && pg_restore -Fd -j $(PARALLEL_JOBS) -d $(DJANGO_BPP_DB_NAME) $(BACKUP_DIRNAME)"

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
