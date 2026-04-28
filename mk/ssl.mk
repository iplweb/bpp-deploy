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

.PHONY: generate-snakeoil-certs generate-snakeoil-certs-force

# Lista hostow do obsluzenia: preferuj DJANGO_BPP_HOSTNAMES (CSV), fallback do
# DJANGO_BPP_HOSTNAME (single). Spacje i puste elementy sa odfiltrowane przez
# scripts/generate-snakeoil-certs.sh.

generate-snakeoil-certs:
	@bash scripts/generate-snakeoil-certs.sh "$(BPP_CONFIGS_DIR)"

generate-snakeoil-certs-force:
	@bash scripts/generate-snakeoil-certs.sh "$(BPP_CONFIGS_DIR)" --force
