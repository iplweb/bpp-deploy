.PHONY: update-ssl-certs generate-grafana-datasources update-configs

update-ssl-certs:
	@if docker compose ps webserver 2>/dev/null | grep -q "Up"; then \
		echo "Webserver is running, reloading nginx..."; \
		docker compose exec webserver nginx -t && docker compose exec webserver nginx -s reload; \
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
