# Monitoring helpers (Netdata + ntfy).

.PHONY: ntfy-test health-netdata logs-netdata netdata-shell

NTFY_TOPIC ?= $(shell grep '^NTFY_TOPIC=' $(BPP_CONFIGS_DIR)/.env 2>/dev/null | cut -d= -f2-)
NTFY_SERVER ?= $(shell grep '^DJANGO_BPP_NTFY_SERVER=' $(BPP_CONFIGS_DIR)/.env 2>/dev/null | cut -d= -f2- || echo https://ntfy.sh)

# Wyslij testowe powiadomienie na ntfy - potwierdzenie ze appka na
# telefonie subskrybuje wlasciwy topic i konfiguracja dziala.
ntfy-test:
	@if [ -z "$(NTFY_TOPIC)" ]; then \
		echo "BLAD: NTFY_TOPIC nie ustawione w $(BPP_CONFIGS_DIR)/.env"; \
		echo "      Uruchom: make init-configs"; \
		exit 1; \
	fi
	@echo "Wysylam test na $(NTFY_SERVER)/<topic-ukryty>"
	@curl -fsSL \
		-H "Title: BPP test notification" \
		-H "Tags: white_check_mark,bpp" \
		-H "Priority: 3" \
		-d "To jest test z make ntfy-test. Jesli to widzisz, alerty dzialaja." \
		"$(NTFY_SERVER)/$(NTFY_TOPIC)" >/dev/null
	@echo "Wyslane. Sprawdz appke ntfy na telefonie."

# Healthcheck Netdaty bezposrednio przez kontener (nginx wymaga auth,
# wiec test przez localhost zwracal by 302 - mylace).
health-netdata:
	@docker compose exec -T netdata curl -fsS http://localhost:19999/api/v1/info \
		| head -c 200 && echo "" \
		|| echo "Netdata kontener nie odpowiada (sprawdz: make logs-netdata)"

# Live logi netdata.
logs-netdata:
	docker compose logs -f --tail=100 netdata

# Shell w kontenerze netdata (debugging).
netdata-shell:
	docker compose exec netdata bash

# Tworzy read-only uzytkownika `bpp_monitor` (Grafana datasource + Netdata
# kolektor postgres). Osobna rola bez DDL/DML - panel SQL w Grafanie nie moze
# nic zepsuc w bazie. Idempotentne. External: wypisuje SQL do recznego uruchomienia.
.PHONY: create-monitoring-user
create-monitoring-user:
	@bash scripts/create-monitoring-user.sh

# DEPRECATED alias -> create-monitoring-user (zachowane dla kompatybilnosci).
.PHONY: grant-pg-monitor
grant-pg-monitor:
	@bash scripts/grant-pg-monitor.sh

# Konfiguruje monitoring wolnych zapytan PostgreSQL:
# - log_min_duration_statement = 1000ms (slow queries do logu - Loki dashboard)
# - pg_stat_statements extension (agregowane stats - Grafana dashboard)
# Idempotentne. Wymaga restartu dbservera tylko pierwszy raz (shared_preload_libraries).
.PHONY: pg-monitoring-setup
pg-monitoring-setup:
	@bash scripts/pg-monitoring-setup.sh
