.PHONY: celery-inspect-report celery-purge celery-inspect-tasks \
       celery-stats celery-status \
       denorm-rebuild-command denorm-count-forever denorm-rebuild \
       denorm-flush denorm-purge-queues

celery-inspect-report:
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect report

celery-purge:
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks purge -f
	docker compose exec workerserver-denorm celery -A django_bpp.celery_tasks purge -f

celery-inspect-tasks:
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect scheduled
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect active
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect reserved
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect revoked
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect registered
	docker compose exec workerserver-general celery -A django_bpp.celery_tasks inspect stats

celery-stats:
	docker compose exec appserver celery -A django_bpp.celery_tasks inspect active
	docker compose exec appserver celery -A django_bpp.celery_tasks inspect active_queues

celery-status:
	docker compose run --rm workerserver-status

denorm-rebuild-command:
	docker compose exec appserver python src/manage.py denorm_rebuild --no-flush

denorm-count-forever:
	@while true; do \
		docker compose exec -e PGPASSWORD=$(DJANGO_BPP_DB_PASSWORD) dbserver \
			psql -h $(DJANGO_BPP_DB_HOST) -p $(DJANGO_BPP_DB_PORT) \
			     -U $(DJANGO_BPP_DB_USER) $(DJANGO_BPP_DB_NAME) \
			     -c "select count(*) from denorm_dirtyinstance;"; \
		sleep 5; \
	done

denorm-rebuild: denorm-rebuild-command denorm-count-forever

denorm-flush:
	docker compose exec appserver python src/manage.py denorm_flush_via_queue

denorm-purge-queues:
	docker compose exec appserver celery -A django_bpp.celery_tasks purge -f -Q denorm
