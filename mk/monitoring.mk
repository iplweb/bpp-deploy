# Monitoring helpers (Netdata + ntfy).

.PHONY: test-ntfy ntfy-test logs-netdata netdata-shell

NTFY_TOPIC ?= $(shell grep '^NTFY_TOPIC=' $(BPP_CONFIGS_DIR)/.env 2>/dev/null | cut -d= -f2-)
# $(or ...) bo `grep | cut || echo` nie dziala: cut konczy sie exit 0 nawet na
# pustym wejsciu, wiec `|| echo` nigdy nie odpalalo i NTFY_SERVER bywal pusty
# (stary .env bez DJANGO_BPP_NTFY_SERVER -> `make ntfy-test` curlowal do `/topic`).
NTFY_SERVER ?= $(or $(strip $(shell grep '^DJANGO_BPP_NTFY_SERVER=' $(BPP_CONFIGS_DIR)/.env 2>/dev/null | cut -d= -f2-)),https://ntfy.sh)

# Wyslij testowe powiadomienie na ntfy - potwierdzenie ze appka na
# telefonie subskrybuje wlasciwy topic i konfiguracja dziala.
test-ntfy:
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
		-d "To jest test z make test-ntfy. Jesli to widzisz, alerty dzialaja." \
		"$(NTFY_SERVER)/$(NTFY_TOPIC)" >/dev/null
	@echo "Wyslane. Sprawdz appke ntfy na telefonie."

# DEPRECATED alias -> test-ntfy (zachowane dla kompatybilnosci: stare skrypty
# i pamiec miesniowa operatora). Backwards-compat contract.
ntfy-test: test-ntfy

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
