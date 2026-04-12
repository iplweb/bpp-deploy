.PHONY: all run refresh up up-quick up-appserver up-webserver up-rclone stop rmrf restart-appserver health repull check-quic

all: run

restart: update-configs
	docker compose down
	docker compose up -d

refresh: prune-orphan-volumes update-configs
	docker system prune -f
	docker compose pull
	docker compose stop
	docker compose rm -f
	docker compose up -d --remove-orphans
	docker system prune -f

DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE ?= true

pull:
	docker compose pull
	@if [ "$(DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE)" = "true" ]; then \
		echo "Pulling iplweb/html2docx:latest..."; \
		docker pull iplweb/html2docx:latest; \
	fi

build:
	docker compose build

up: update-configs
	docker compose up -d --wait --force-recreate --remove-orphans
	@if [ "$(DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE)" = "true" ]; then \
		docker pull iplweb/html2docx:latest; \
	fi

up-appserver: pull
	docker compose up --wait --force-recreate -d appserver

stop:
	docker compose stop

rmrf:
	@echo "WARNING: This will forcefully remove all stopped containers!"
	@echo "Target: $$(docker context show)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
	docker compose rm -f

up-quick: pull
	docker compose up -d --wait

up-webserver:
	docker compose up -d webserver

up-rclone:
	docker compose up -d --wait rclone

restart-appserver:
	docker compose restart appserver

health:
	@echo "=== Service Status ==="
	@docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Health}}"
	@echo ""
	@echo "=== Recent Errors (last 5 min) ==="
	@docker compose logs --since 5m 2>&1 | grep -i -E "(error|exception|critical|failed)" | tail -20 || echo "No recent errors found"

repull:
	@echo "Removing iplweb/bpp_* images..."
	@docker compose config --images | grep '^iplweb/bpp_' | sort -u | xargs -r docker rmi -f || true
	@docker image prune -f > /dev/null
	@echo "Pulling fresh images..."
	$(MAKE) pull

check-quic:
	@bash scripts/check-quic-port.sh $(HOST)

run: pull build update-configs up test-email
