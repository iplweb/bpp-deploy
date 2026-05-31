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
	@echo "Wysylam test na $(NTFY_SERVER)/$(NTFY_TOPIC)"
	@curl -fsSL \
		-H "Title: BPP test notification" \
		-H "Tags: white_check_mark,bpp" \
		-H "Priority: 3" \
		-d "To jest test z make ntfy-test. Jesli to widzisz, alerty dzialaja." \
		"$(NTFY_SERVER)/$(NTFY_TOPIC)" >/dev/null
	@echo "Wyslane. Sprawdz appke ntfy na telefonie."

# Healthcheck endpoint Netdaty (z hosta, przez nginx) - oczekuj 200.
health-netdata:
	@curl -sf -o /dev/null -w "Netdata UI (nginx): HTTP %{http_code}\n" \
		http://localhost/netdata/api/v1/info || echo "Netdata nieosiagalna przez nginx"
	@docker compose exec -T netdata wget -qO- http://localhost:19999/api/v1/info \
		2>/dev/null | head -c 200 && echo "" || echo "Netdata kontener nie odpowiada"

# Live logi netdata.
logs-netdata:
	docker compose logs -f --tail=100 netdata

# Shell w kontenerze netdata (debugging).
netdata-shell:
	docker compose exec netdata bash
