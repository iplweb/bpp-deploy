.PHONY: changepassword invalidate schowaj-jezyki-dyscypliny pbn-first-import \
       createsuperuser test-email

changepassword:
	docker compose exec appserver uv run src/manage.py changepassword $(DJANGO_BPP_ADMIN_USERNAME)

invalidate:
	docker compose exec appserver uv run src/manage.py invalidate all

schowaj-jezyki-dyscypliny:
	docker compose exec appserver uv run src/manage.py ukryj_nieuzywane_dyscypliny
	docker compose exec appserver uv run src/manage.py ukryj_nieuzywane_jezyki

pbn-first-import:
	docker compose exec appserver uv run src/manage.py pbn_first_import

createsuperuser:
	docker compose exec appserver uv run src/manage.py createsuperuser \
		$(if $(DJANGO_BPP_ADMIN_USERNAME),--username $(DJANGO_BPP_ADMIN_USERNAME)) \
		$(if $(DJANGO_BPP_ADMIN_EMAIL),--email $(DJANGO_BPP_ADMIN_EMAIL))

test-email:
	@if [ -z "$(DJANGO_BPP_ADMIN_EMAIL)" ]; then \
		echo "DJANGO_BPP_ADMIN_EMAIL nie jest ustawiony. Ustaw go w $(BPP_CONFIGS_DIR)/.env"; \
		exit 1; \
	fi
	docker compose exec appserver uv run src/manage.py sendtestemail $(DJANGO_BPP_ADMIN_EMAIL)
	docker compose exec appserver uv run src/manage.py sendtesttemplatedemail $(DJANGO_BPP_ADMIN_EMAIL)
