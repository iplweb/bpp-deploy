# Multi-host SSL: certyfikat per nazwa domenowa.
#
# Layout w $BPP_CONFIGS_DIR/ssl/:
#   cert.pem, key.pem                          - tryb single-host (legacy, gdy
#                                                tylko DJANGO_BPP_HOSTNAME jest
#                                                ustawione i brak per-host pliku)
#   <host>/cert.pem, <host>/key.pem            - tryb multi-host (preferowany,
#                                                gdy DJANGO_BPP_HOSTNAMES zawiera
#                                                liste CSV)
#
# entrypoint nginx (defaults/webserver/30-render-bpp-vhosts.sh) generuje server
# bloki na podstawie tej listy i dla kazdego hosta probuje najpierw per-host
# certyfikat, fallback do legacy jednego pliku.

.PHONY: generate-snakeoil-certs generate-snakeoil-certs-force \
        ssl-letsencrypt-issue ssl-letsencrypt-renew test-letsencrypt

# Lista hostow do obsluzenia: preferuj DJANGO_BPP_HOSTNAMES (CSV), fallback do
# DJANGO_BPP_HOSTNAME (single). Spacje i puste elementy sa odfiltrowane przez
# scripts/generate-snakeoil-certs.sh.

generate-snakeoil-certs:
	@bash scripts/generate-snakeoil-certs.sh "$(BPP_CONFIGS_DIR)"

generate-snakeoil-certs-force:
	@bash scripts/generate-snakeoil-certs.sh "$(BPP_CONFIGS_DIR)" --force

# Let's Encrypt — wystawienie i odswiezanie certyfikatow.
#
# Layout: cert LE trafia do $BPP_CONFIGS_DIR/letsencrypt/live/<canonical-host>/,
# nigdy do ssl/ (manualne certy zachowane bez ryzyka utraty). Aktywacja przez
# DJANGO_BPP_SSL_MODE=letsencrypt - ten target sam ja proponuje po sukcesie
# w trybie PROD.
#
# Pierwszy raz:
#   make ssl-letsencrypt-issue           # staging (test pipeline'u)
#   make ssl-letsencrypt-issue PROD=1    # prawdziwy cert + ewentualna aktywacja
#
# Manualne odnowienie (debugging / rotation - codzienne dzieje sie przez Ofelia):
#   make ssl-letsencrypt-renew

ssl-letsencrypt-issue:
	@PROD="$(PROD)" ACTIVATE="$(ACTIVATE)" bash scripts/letsencrypt.sh issue

ssl-letsencrypt-renew:
	@bash scripts/letsencrypt.sh renew

# Testy logiki orchestratora LE (mock-uje docker w PATH, nie wymaga sieci ani
# prawdziwego daemona Docker dla samych assertion-ow). Pelne testy nginx-a
# z LE cert paths zyja w tests/test_makefile.sh (test_nginx_config_valid + 14c-e
# oraz test_nginx_runtime + 15c) - tam wymagane jest Docker daemon w trybie
# linux. Tutaj tylko logika scripts/letsencrypt.sh: parsowanie .env, gating
# na SSL_MODE, ACTIVATE/PROD/email-fallback, manipulacja .env przy aktywacji.
test-letsencrypt:
	@bash scripts/test-letsencrypt.sh
