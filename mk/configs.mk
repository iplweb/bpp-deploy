.PHONY: update-ssl-certs generate-grafana-datasources update-configs configure-resources configure-rate-limits configure ask-missing-config config-check docs-config-table ensure-config-files zaspawaj-wersje

# Non-interactive guard przed `make up`: dokopiowuje brakujace pliki z defaults/
# do $BPP_CONFIGS_DIR (np. gdy nowy release dodaje kolejny bind-mount, a user
# nie uruchomil `make init-configs` po git pullu).
ensure-config-files:
	@bash scripts/ensure-config-files.sh

update-ssl-certs:
	@if docker compose ps webserver 2>/dev/null | grep -q "Up"; then \
		echo "Webserver is running, regenerating vhosts and reloading nginx..."; \
		docker compose exec webserver /docker-entrypoint.d/30-render-bpp-vhosts.sh && \
		docker compose exec webserver nginx -t && \
		docker compose exec webserver nginx -s reload; \
	else \
		echo "Webserver not running. Certificates will be loaded on next startup."; \
	fi

generate-grafana-datasources:
	@bash scripts/generate-grafana-datasources.sh

update-configs: generate-grafana-datasources
	@echo "Configs are bind-mounted from $(BPP_CONFIGS_DIR), no copy needed."

configure-resources:
	@./scripts/configure-resources.sh

# Interaktywnie: stan (CPU, ruch, odmowy 429 / spowolnieni z doby), szacunek
# BPP_NGINX_GLOBAL_RATE z CPU albo z czasu obslugi zadan, pytania o
# BPP_NGINX_GLOBAL_* / BPP_NGINX_IP_*, zapis zmienionych do .env, make up-webserver.
configure-rate-limits:
	@bash scripts/configure-rate-limits.sh

# Zmienne operatora z rejestru scripts/config-registry.tsv (e-mail admina, SSL,
# Slack/Rollbar, Google, backupy, Freshdesk). Menu grup, zapis na koncu.
configure:
	@bash scripts/configure.sh

# Prerequisit make up/up-quick/refresh: pyta TYLKO o zmienne z rejestru
# (PYTAJ=tak), ktorych w .env nie ma wcale. Pusta odpowiedz zapisuje `VAR=`
# = decyzja "nie mamy", wiec pytanie pada raz. Bez terminala / pod
# BPP_SKIP_HEALTH_GATE / BPP_NO_CONFIG_PROMPT nie pyta (autoupdate pod
# screenem ma pseudo-TTY).
ask-missing-config:
	@bash scripts/configure.sh --missing

# Walidacja wartosci z rejestru w .env (tez z make doctor). Exit 1 = bledy.
config-check:
	@bash scripts/configure.sh --check

# Przegenerowuje tabele zmiennych w docs/konfiguracja/zmienne.md z rejestru
# (miedzy znacznikami rejestr:start / rejestr:end). Test pilnuje aktualnosci.
docs-config-table:
	@bash scripts/render-config-docs.sh

# Przypina DOCKER_VERSION w $(BPP_CONFIGS_DIR)/.env do wersji CalVer, na
# ktorej faktycznie chodzi appserver (lub jawnej: TAG=202606.1386).
# Szczegoly i kontrakt: docs/eksploatacja/komendy.md, CLAUDE.md.
zaspawaj-wersje:
	@TAG="$(TAG)" bash scripts/zaspawaj-wersje.sh
