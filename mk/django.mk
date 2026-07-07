.PHONY: changepassword invalidate schowaj-jezyki-dyscypliny pbn-first-import \
       createsuperuser test-email test-rollbar

changepassword:
	docker compose exec appserver python src/manage.py changepassword $(DJANGO_BPP_ADMIN_USERNAME)

invalidate:
	docker compose exec appserver python src/manage.py invalidate all
	@# Czyscimy renderowany page cache (@cache_page + fragmenty {% cache %}),
	@# ale NIE sesje. Dawniej stal tu 'redis-cli FLUSHDB', ktory flushowal cala
	@# baze Redisa (page cache i sesje dziela ta sama DB) => wylogowywal
	@# wszystkich przy KAZDYM 'make up' (potwierdzone empirycznie). Teraz
	@# kasujemy chirurgicznie po wzorcu klucza (Django cache.delete_pattern) -
	@# sesje zostaja. NIE przywracac tu FLUSHDB/FLUSHALL. Cache zapytan ORM
	@# (cacheops) czysci powyzsze 'invalidate all'.
	@bash scripts/clear-page-cache.sh

schowaj-jezyki-dyscypliny:
	docker compose exec appserver python src/manage.py ukryj_nieuzywane_dyscypliny
	docker compose exec appserver python src/manage.py ukryj_nieuzywane_jezyki

pbn-first-import:
	docker compose exec appserver python src/manage.py pbn_first_import

createsuperuser:
	docker compose exec appserver python src/manage.py createsuperuser \
		$(if $(DJANGO_BPP_ADMIN_USERNAME),--username $(DJANGO_BPP_ADMIN_USERNAME)) \
		$(if $(DJANGO_BPP_ADMIN_EMAIL),--email $(DJANGO_BPP_ADMIN_EMAIL))

test-email:
	@if [ -z "$(DJANGO_BPP_ADMIN_EMAIL)" ]; then \
		echo "DJANGO_BPP_ADMIN_EMAIL nie jest ustawiony. Ustaw go w $(BPP_CONFIGS_DIR)/.env"; \
		exit 1; \
	fi
	docker compose exec appserver python src/manage.py sendtestemail $(DJANGO_BPP_ADMIN_EMAIL)
	docker compose exec appserver python src/manage.py sendtesttemplatedemail $(DJANGO_BPP_ADMIN_EMAIL)

test-rollbar:
	@if [ -z "$(ROLLBAR_ACCESS_TOKEN)" ]; then \
		echo "ROLLBAR_ACCESS_TOKEN nie jest ustawiony. Ustaw go w $(BPP_CONFIGS_DIR)/.env"; \
		exit 1; \
	fi
	docker compose exec appserver python src/manage.py test_rollbar
