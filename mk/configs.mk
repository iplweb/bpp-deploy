.PHONY: update-ssl-certs generate-grafana-datasources update-configs configure-resources ensure-config-files

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
	envsubst < $(BPP_CONFIGS_DIR)/grafana/provisioning/datasources/datasources.yaml.tpl \
		| sed 's/"\([^"]*\)"/\1/g' \
		> $(BPP_CONFIGS_DIR)/grafana/provisioning/datasources/datasources.yaml
	@echo "Generated $(BPP_CONFIGS_DIR)/grafana/provisioning/datasources/datasources.yaml"

update-configs: generate-grafana-datasources
	@echo "Configs are bind-mounted from $(BPP_CONFIGS_DIR), no copy needed."

configure-resources:
	@./scripts/configure-resources.sh
