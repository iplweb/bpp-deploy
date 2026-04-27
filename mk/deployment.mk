.PHONY: all run refresh up up-quick up-appserver up-webserver up-rclone stop rmrf restart restart-appserver health check-quic validate-env-quotes fix-env-quotes test-validate-env-quotes

all: run

validate-env-quotes:
	@bash scripts/validate-env-quotes.sh

fix-env-quotes:
	@bash scripts/validate-env-quotes.sh --fix

test-validate-env-quotes:
	@bash scripts/test-validate-env-quotes.sh

restart: validate-env-quotes update-configs
	docker compose down
	docker compose up -d

refresh: validate-env-quotes prune-orphan-volumes ensure-config-files update-configs
	docker system prune -f
	docker compose pull
	docker compose stop
	docker compose rm -f
	docker compose up -d --remove-orphans
	docker system prune -f
	$(MAKE) invalidate

DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE ?= false

pull: validate-env-quotes
	docker compose pull
	@if [ "$(DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE)" = "true" ]; then \
		echo "Pulling iplweb/html2docx:latest..."; \
		docker pull iplweb/html2docx:latest; \
	fi

build:
	docker compose build

up: validate-env-quotes ensure-config-files update-configs
	docker compose up -d --wait --force-recreate --remove-orphans
	@if [ "$(DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE)" = "true" ]; then \
		docker pull iplweb/html2docx:latest; \
	fi
	$(MAKE) invalidate

up-appserver: validate-env-quotes pull
	docker compose up --wait --force-recreate -d appserver

stop:
	docker compose stop

rmrf:
	@echo "WARNING: This will forcefully remove all stopped containers!"
	@echo "Target: $$(docker context show)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
	docker compose rm -f

up-quick: validate-env-quotes ensure-config-files pull
	docker compose up -d --wait
	$(MAKE) invalidate

up-webserver: validate-env-quotes
	docker compose up -d webserver

up-rclone: validate-env-quotes
	docker compose up -d --wait rclone

restart-appserver: validate-env-quotes
	docker compose restart appserver

health:
	@echo "=== Service Status ==="
	@docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Health}}"
	@echo ""
	@echo "=== Recent Errors (last 5 min) ==="
	@docker compose logs --since 5m 2>&1 | grep -i -E "(error|exception|critical|failed)" | tail -20 || echo "No recent errors found"

check-quic:
	@bash scripts/check-quic-port.sh $(HOST)

run: pull build update-configs up test-email
