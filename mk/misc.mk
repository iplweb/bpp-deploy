.PHONY: clean wait debug-show-current-settings test-docker-versions test-config-path test-grafana-datasources test-winget-ids test-waf test-alloy

clean:
	-find . -name '*~' -o -name '\#*' -o -name '.*~' | xargs rm -f

wait:
	@bash scripts/wait-for-build.sh

debug-show-current-settings:
	docker compose exec appserver python src/manage.py debug_setup_initial_data --show-current

test-docker-versions:
	@bash scripts/test-docker-versions.sh

# Unit-testy normalizacji sciezki katalogu konfiguracyjnego (Windows C:\...,
# cudzyslowy, katalogi-rodzenstwo o wspolnym prefiksie). Windows symulowany
# atrapami cygpath/uname w PATH — bez sieci, dockera i .env.
test-config-path:
	@bash scripts/test-config-path.sh

# Render datasource'ow Grafany. Kluczowa asercja: dziala z PATH-em BEZ
# `envsubst` (Windows nie ma gettexta). Bez sieci, dockera i .env.
test-grafana-datasources:
	@bash scripts/test-grafana-datasources.sh

# Czy identyfikatory pakietow winget z instrukcji dla Windows nadal istnieja
# w microsoft/winget-pkgs. WYMAGA SIECI, wiec swiadomie nie wchodzi do `make
# test` (ta petla ma dzialac offline) — w CI ma wlasny job `winget-ids`.
# Ustaw GITHUB_TOKEN, zeby nie wpasc w limit 60 zapytan/h dla anonimowych.
test-winget-ids:
	@bash scripts/test-winget-ids.sh

# Stack testowy WAF-a (ModSecurity + OWASP CRS). Stawia atrape backendu i
# webserver z PRAWDZIWA konfiguracja z defaults/webserver/, po czym strzela
# bateria zapytan: realne payloady sqlmap maja zostac zerwane (444), a legalny
# ruch BPP ma dostac 200 "pass". Nie wymaga .env ani dzialajacej instalacji.
# Zmienne: WAF_TEST_PORT (domyslnie 18443), MODSEC_RULE_ENGINE (domyslnie On —
# ustaw DetectionOnly, zeby zobaczyc co BY zostalo zablokowane).
test-waf:
	@./scripts/test-waf.sh

# Test pipeline'u logow Alloy. Przepuszcza PRAWDZIWY defaults/alloy/config.alloy
# przez fixture z prawdziwymi liniami (audit log WAF-a + typowe formaty logow
# aplikacji), podmieniajac tylko zrodlo (plik zamiast dockera) i ujscie
# (loki.echo zamiast loki.write). Sprawdza `detected_level` i pola `modsec_*`.
# Nie wymaga .env, Loki ani dzialajacej instalacji.
# Zmienne: ALLOY_TEST_KEEP=1 (zostaw kontener), ALLOY_TEST_WAIT (sekundy).
test-alloy:
	@./scripts/test-alloy.sh
