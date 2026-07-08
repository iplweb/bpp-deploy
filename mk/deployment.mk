.PHONY: all run refresh up up-quick up-appserver up-webserver stop rmrf restart restart-appserver health check-quic validate-env-quotes fix-env-quotes test-validate-env-quotes test-upgrade test-upgrade-clean autoupdate test-autoupdate

all: run

validate-env-quotes:
	@bash scripts/validate-env-quotes.sh

fix-env-quotes:
	@bash scripts/validate-env-quotes.sh --fix

test-validate-env-quotes:
	@bash scripts/test-validate-env-quotes.sh

restart: validate-env-quotes update-configs
	docker compose down
	docker compose up -d

refresh: validate-env-quotes prune-orphan-volumes ensure-config-files update-configs
	docker system prune -f
	docker compose pull
	docker compose stop
	docker compose rm -f
	docker compose up -d --remove-orphans
	docker system prune -f
	@bash scripts/create-monitoring-user.sh --soft
	$(MAKE) invalidate

DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE ?= false

pull: validate-env-quotes
	docker compose pull
	@if [ "$(DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE)" = "true" ]; then \
		echo "Pulling iplweb/html2docx:latest..."; \
		docker pull iplweb/html2docx:latest; \
	fi

build:
	docker compose build

up: validate-env-quotes ensure-config-files update-configs
	docker compose up -d --wait --force-recreate --remove-orphans
	@bash scripts/create-monitoring-user.sh --soft
	@# Stack jest UP i healthy (--wait powyzej; przy bledzie make juz by stanal).
	@# Sprzatamy nieuzywane obrazy/kontenery/sieci/cache Dockera. BEZ --volumes,
	@# wiec nazwane wolumeny (postgresql_data, media, staticfiles) sa BEZPIECZNE.
	@# -af kasuje WSZYSTKIE nieuzywane obrazy (tez stare wersje BPP, osierocony
	@# alpine po przejsciu backup-runnera na obraz dbservera). Pokazujemy tylko
	@# ile miejsca zwolniono. Robimy to PRZED pullem html2docx, by go nie usunac.
	@echo "Sprzatanie Dockera (docker system prune -af)..."
	@docker system prune -af 2>/dev/null \
		| awk -F': ' '/Total reclaimed space/ {print "  Zwolniono na dysku: " $$2}' \
		|| true
	@if [ "$(DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE)" = "true" ]; then \
		docker pull iplweb/html2docx:latest; \
	fi
	$(MAKE) invalidate
	@# Bramka zdrowia po deployu (read-only): OK -> exit 0 cicho; usluga
	@# unhealthy/restarting -> w TTY prompt [s]shell/[d]doctor, w nie-TTY exit !=0.
	@bash scripts/post-deploy-check.sh

up-appserver: validate-env-quotes pull
	docker compose up --wait --force-recreate -d appserver

stop:
	docker compose stop

rmrf:
	@echo "WARNING: This will forcefully remove all stopped containers!"
	@echo "Target: $$(docker context show)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
	docker compose rm -f

up-quick: validate-env-quotes ensure-config-files pull
	docker compose up -d --wait
	$(MAKE) invalidate

# Unit-testy scripts/post-deploy-check.sh (mock docker/make, bez sieci/dockera).
.PHONY: test-post-deploy-check
test-post-deploy-check:
	@bash scripts/test-post-deploy-check.sh

up-webserver: validate-env-quotes
	docker compose up -d webserver

restart-appserver: validate-env-quotes
	docker compose restart appserver

health:
	@echo "=== Service Status ==="
	@docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Health}}"
	@echo ""
	@echo "=== Recent Errors (last 5 min) ==="
	@docker compose logs --since 5m 2>&1 | grep -i -E "(error|exception|critical|failed)" | tail -20 || echo "No recent errors found"

check-quic:
	@bash scripts/check-quic-port.sh $(HOST)

run: pull build update-configs up
	@echo ""
	@echo "Deploy zakonczony. Diagnostyka powiadomien/uslug na zadanie: make doctor"

# Nienadzorowana aktualizacja: petla co AUTOUPDATE_INTERVAL sekund (domyslnie 2h)
# wolajaca scripts/autoupdate.sh (jeden cykl: sprawdz nowy obraz/commit -> deploy).
# Przeznaczone pod nazwana sesje screen/tmux:
#   screen -dmS bpp-autoupdate make autoupdate   # start w tle
#   screen -r bpp-autoupdate                     # podglad (Ctrl-A D = detach)
# Interwal i backup-przed-deployem konfigurowalne w .env (AUTOUPDATE_INTERVAL,
# AUTOUPDATE_DB_BACKUP). Skrypt wolany swiezo co iteracje, wiec po `git pull`
# nastepny cykl uzywa juz nowej logiki. Blad cyklu NIE zabija petli.
AUTOUPDATE_INTERVAL ?= 7200

autoupdate:
	@echo "BPP auto-update: petla co $(AUTOUPDATE_INTERVAL)s. Ctrl-C aby przerwac."
	@echo "Podglad z innego terminala: screen -r bpp-autoupdate"
	@while true; do \
		bash scripts/autoupdate.sh || echo "autoupdate: cykl zakonczony bledem (kod $$?) — czekam do nastepnego."; \
		echo "autoupdate: nastepny cykl za $(AUTOUPDATE_INTERVAL)s ($$(date '+%H:%M:%S'))."; \
		sleep $(AUTOUPDATE_INTERVAL); \
	done

# Unit-testy scripts/autoupdate.sh (mock git/docker/make, bez sieci/dockera).
test-autoupdate:
	@bash scripts/test-autoupdate.sh

# Proba generalna aktualizacji: backup -> shadow stack (dbserver+redis poza
# projektem Compose) -> restore -> migrate obrazem-kandydatem. Produkcja
# (kontenery, wolumeny, lokalny tag :latest, .env) pozostaje nietknieta.
# Uwaga: NIE mylic z test-upgrade-postgres (unit-testy upgrade'u PG).
test-upgrade: validate-env-quotes
	@TAG="$(TAG)" bash scripts/test-upgrade.sh

test-upgrade-clean:
	@bash scripts/test-upgrade.sh --clean
