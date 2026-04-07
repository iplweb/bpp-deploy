# UWAGA: cele certbot w tym pliku nie są przetestowane w obecnej konfiguracji.
# Zostały zachowane jako referencyjna implementacja do przetestowania w przyszłości.

.PHONY: get-certificate-from-cerbot copy-certificates-from-certbot \
       end-get-certificate-from-cerbot update-letsencrypt-certificate \
       generate-snakeoil-certs generate-snakeoil-certs-force

# --- Samopodpisane certyfikaty (snakeoil) ---

generate-snakeoil-certs:
	@if [ -f "$(BPP_CONFIGS_DIR)/ssl/key.pem" ] && [ -f "$(BPP_CONFIGS_DIR)/ssl/cert.pem" ]; then \
		echo "Certyfikaty SSL juz istnieja w $(BPP_CONFIGS_DIR)/ssl/"; \
		echo "Uzyj 'make generate-snakeoil-certs-force' aby je nadpisac."; \
	else \
		echo "Generowanie samopodpisanych certyfikatow SSL..."; \
		openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
			-keyout "$(BPP_CONFIGS_DIR)/ssl/key.pem" \
			-out "$(BPP_CONFIGS_DIR)/ssl/cert.pem" \
			-subj "/CN=$(DJANGO_BPP_HOSTNAME)" \
			-addext "subjectAltName=DNS:$(DJANGO_BPP_HOSTNAME)"; \
		echo "Wygenerowano certyfikaty snakeoil SSL w $(BPP_CONFIGS_DIR)/ssl/"; \
		echo "  key.pem  - klucz prywatny"; \
		echo "  cert.pem - certyfikat (wazny 365 dni, CN=$(DJANGO_BPP_HOSTNAME))"; \
	fi

generate-snakeoil-certs-force:
	@echo "Generowanie samopodpisanych certyfikatow SSL (nadpisanie istniejacych)..."
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout "$(BPP_CONFIGS_DIR)/ssl/key.pem" \
		-out "$(BPP_CONFIGS_DIR)/ssl/cert.pem" \
		-subj "/CN=$(DJANGO_BPP_HOSTNAME)" \
		-addext "subjectAltName=DNS:$(DJANGO_BPP_HOSTNAME)"
	@echo "Wygenerowano certyfikaty snakeoil SSL w $(BPP_CONFIGS_DIR)/ssl/"
	@echo "  key.pem  - klucz prywatny"
	@echo "  cert.pem - certyfikat (wazny 365 dni, CN=$(DJANGO_BPP_HOSTNAME))"

# --- Certbot / Let's Encrypt (niesprawdzone) ---

get-certificate-from-cerbot:
	docker compose --profile get-ssl-certs up certbot

copy-certificates-from-certbot:
	docker compose cp -L webserver_http:/etc/letsencrypt/live/certyfikat_ssl/fullchain.pem $(BPP_CONFIGS_DIR)/ssl/cert.pem
	docker compose cp -L webserver_http:/etc/letsencrypt/live/certyfikat_ssl/privkey.pem $(BPP_CONFIGS_DIR)/ssl/key.pem
	ls -lash $(BPP_CONFIGS_DIR)/ssl/

end-get-certificate-from-cerbot:
	docker compose --profile get-ssl-certs stop certbot webserver_http

update-letsencrypt-certificate: get-certificate-from-cerbot end-get-certificate-from-cerbot copy-certificates-from-certbot
