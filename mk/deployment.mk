.PHONY: all run refresh up up-quick up-appserver up-webserver stop rmrf restart restart-appserver health check-quic validate-env-quotes fix-env-quotes test-validate-env-quotes test-upgrade test-upgrade-clean autoupdate screen-with-autoupdate test-autoupdate setup-autoupdate-cron remove-autoupdate-cron test-autoupdate-cron \
       run-with-warning enable-site-down-warning disable-site-down-warning extend-site-down-warning status-site-down-warning test-deploy-with-warning

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

pull: validate-env-quotes
	docker compose pull

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
	@# ile miejsca zwolniono. Serwis html2docx (gdy wlaczony profilem) jest juz
	@# UP przed prune, wiec jego obraz jest w uzyciu i prune go nie usunie.
	@echo "Sprzatanie Dockera (docker system prune -af)..."
	@docker system prune -af 2>/dev/null \
		| awk -F': ' '/Total reclaimed space/ {print "  Zwolniono na dysku: " $$2}' \
		|| true
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

# === Przerwa techniczna z ostrzezeniem (django-countdown >= 0.3.0) ===========
#
# Sesja: make pull -> baner "za N minut przerwa" -> odciecie -> make run ->
# zdjecie blokady. Cala logika countdownu siedzi w komendach `manage.py`
# dostarczanych przez django-countdown; tutaj sa tylko cienkie opakowania.
#
# Pod screenem:  screen -dmS bpp-deploy make run-with-warning
# Regulacja deklarowanego powrotu Z INNEGO OKNA (sesja nic nie czyta z klawiatury):
#   make extend-site-down-warning MINUTES=+10
#
# Parametry (puste = wartosc z .env, a potem stala w skrypcie):
#   MINUTES  - dlugosc fazy banera (domyslnie 5); w extend-* to przesuniecie ±N
#   SERVICE  - deklarowana dlugosc przerwy (domyslnie 10)
#   MESSAGE  - naglowek banera i strony przerwy
#   SITE_IDS - lista id witryn przy multi-hoscie (domyslnie: witryna biezaca)
# Pelny opis: docs/eksploatacja/przerwa-techniczna.md
SITE_DOWN_ENV = MINUTES='$(MINUTES)' SERVICE='$(SERVICE)' MESSAGE='$(MESSAGE)' \
                LONG_DESCRIPTION='$(LONG_DESCRIPTION)' SITE_IDS='$(SITE_IDS)'

run-with-warning: validate-env-quotes
	@$(SITE_DOWN_ENV) bash scripts/deploy-with-warning.sh

enable-site-down-warning:
	@$(SITE_DOWN_ENV) bash scripts/site-down-warning.sh enable

disable-site-down-warning:
	@bash scripts/site-down-warning.sh disable

extend-site-down-warning:
	@if [ -z "$(MINUTES)" ]; then \
		echo "Uzycie: make extend-site-down-warning MINUTES=+10   (albo -5)"; \
		exit 2; \
	fi
	@$(SITE_DOWN_ENV) bash scripts/site-down-warning.sh adjust '$(MINUTES)'

status-site-down-warning:
	@JSON='$(JSON)' bash scripts/site-down-warning.sh status

# Unit-testy sesji z ostrzezeniem (mock docker/make, bez sieci i Dockera).
test-deploy-with-warning:
	@bash scripts/test-deploy-with-warning.sh

# Nienadzorowana aktualizacja: petla co AUTOUPDATE_INTERVAL sekund (domyslnie 2h)
# wolajaca scripts/autoupdate.sh (jeden cykl: sprawdz nowy obraz/commit -> deploy).
# Przeznaczone pod nazwana sesje screen/tmux:
#   screen -dmS bpp-autoupdate make autoupdate   # start w tle
#   screen -r bpp-autoupdate                     # podglad (Ctrl-A D = detach)
# Interwal i backup-przed-deployem konfigurowalne w .env (AUTOUPDATE_INTERVAL,
# AUTOUPDATE_DB_BACKUP). Skrypt wolany swiezo co iteracje, wiec po `git pull`
# nastepny cykl uzywa juz nowej logiki. Blad cyklu NIE zabija petli.
AUTOUPDATE_INTERVAL ?= 7200
AUTOUPDATE_SCREEN_NAME ?= bpp-autoupdate

autoupdate:
	@echo "BPP auto-update: petla co $(AUTOUPDATE_INTERVAL)s. Ctrl-C aby przerwac."
	@echo "Podglad z innego terminala: screen -r $(AUTOUPDATE_SCREEN_NAME)"
	@while true; do \
		bash scripts/autoupdate.sh || echo "autoupdate: cykl zakonczony bledem (kod $$?) — czekam do nastepnego."; \
		next=$$(($$(date +%s) + $(AUTOUPDATE_INTERVAL))); \
		echo "autoupdate: nastepny cykl za $(AUTOUPDATE_INTERVAL)s, okolo $$(date -d "@$$next" '+%H:%M:%S' 2>/dev/null || date -r "$$next" '+%H:%M:%S' 2>/dev/null || echo '?')."; \
		sleep $(AUTOUPDATE_INTERVAL); \
	done

# Wygodny start petli auto-update w tle, w nazwanej sesji screen (bez recznego
# `screen -dmS ... make autoupdate`). Idempotentny: gdy sesja juz dziala, nie
# startuje drugiej. Pole `-C $(CURDIR)` + czyszczenie MAKEFLAGS/MAKELEVEL, bo
# odlaczony screen przezywa rodzica-make (dziedziczony jobserver bylby martwy).
screen-with-autoupdate:
	@command -v screen >/dev/null 2>&1 || { \
		echo "BLAD: 'screen' nie jest zainstalowany."; \
		echo "Zainstaluj: sudo apt-get install -y screen   (Debian/Ubuntu)"; \
		exit 1; \
	}
	@if screen -list 2>/dev/null | grep -qE "\.$(AUTOUPDATE_SCREEN_NAME)[[:space:]]"; then \
		echo "Sesja screen '$(AUTOUPDATE_SCREEN_NAME)' juz dziala — nie startuje drugiej."; \
		echo "  Podglad: screen -r $(AUTOUPDATE_SCREEN_NAME)"; \
	else \
		screen -dmS $(AUTOUPDATE_SCREEN_NAME) bash -c "cd '$(CURDIR)' && exec env -u MAKEFLAGS -u MAKELEVEL make autoupdate"; \
		echo "✓ Auto-update wystartowal w sesji screen '$(AUTOUPDATE_SCREEN_NAME)' (co $(AUTOUPDATE_INTERVAL)s)."; \
		echo "  Podglad: screen -r $(AUTOUPDATE_SCREEN_NAME)   (odlaczenie: Ctrl-A D)"; \
		echo "  Stop:    screen -S $(AUTOUPDATE_SCREEN_NAME) -X quit"; \
	fi

# Straznik (watchdog) petli auto-update jako wpis w crontabie uzytkownika.
# `screen-with-autoupdate` jest idempotentny, wiec wystarczy wolac go okresowo:
# jeden wpis cron pokrywa ZAROWNO restart hosta (nie trzeba osobnego @reboot),
# JAK I padniecie sesji screen miedzy restartami (OOM, `screen -X quit`, zabity
# proces) — bez tego auto-aktualizacja milkla po cichu i nikt sie nie dowiadywal.
# Cala logika (walidacja harmonogramu, zamrozenie PATH, kopia crontaba, filtr po
# markerze) siedzi w scripts/setup-autoupdate-cron.sh; targety sa cienkie.
# AUTOUPDATE_CRON_LOG celowo puste — pusta wartosc skrypt traktuje jak "nie
# ustawiono" i sam wylicza domyslna sciezke ($BPP_CONFIGS_DIR/logs/...), wiec
# ta logika nie jest tu dublowana.
AUTOUPDATE_CRON_SCHEDULE ?= */15 * * * *
AUTOUPDATE_CRON_LOG ?=

setup-autoupdate-cron:
	@AUTOUPDATE_CRON_SCHEDULE='$(AUTOUPDATE_CRON_SCHEDULE)' \
	 AUTOUPDATE_CRON_LOG='$(AUTOUPDATE_CRON_LOG)' \
	 bash scripts/setup-autoupdate-cron.sh

remove-autoupdate-cron:
	@AUTOUPDATE_CRON_LOG='$(AUTOUPDATE_CRON_LOG)' \
	 bash scripts/setup-autoupdate-cron.sh --remove

# Unit-testy scripts/setup-autoupdate-cron.sh (mock crontab, bez prawdziwego crona).
test-autoupdate-cron:
	@bash scripts/test-autoupdate-cron.sh

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
