.PHONY: shell shell-appserver shell-workerserver shell-dbserver shell-python shell-plus

shell:
	docker compose exec appserver /bin/bash

shell-workerserver:
	docker compose exec workerserver-general /bin/bash

shell-appserver: shell  ## Alias for 'shell'

shell-dbserver:
	docker compose exec dbserver /bin/bash

shell-python:
	docker compose exec appserver uv run src/manage.py shell

shell-plus:
	docker compose exec appserver uv run src/manage.py shell_plus
