.PHONY: clean wait debug-show-current-settings test-docker-versions test-waf

clean:
	-find . -name '*~' -o -name '\#*' -o -name '.*~' | xargs rm -f

wait:
	@bash scripts/wait-for-build.sh

debug-show-current-settings:
	docker compose exec appserver python src/manage.py debug_setup_initial_data --show-current

test-docker-versions:
	@bash scripts/test-docker-versions.sh

# Stack testowy WAF-a (ModSecurity + OWASP CRS). Stawia atrape backendu i
# webserver z PRAWDZIWA konfiguracja z defaults/webserver/, po czym strzela
# bateria zapytan: realne payloady sqlmap maja zostac zerwane (444), a legalny
# ruch BPP ma dostac 200 "pass". Nie wymaga .env ani dzialajacej instalacji.
# Zmienne: WAF_TEST_PORT (domyslnie 18443), MODSEC_RULE_ENGINE (domyslnie On —
# ustaw DetectionOnly, zeby zobaczyc co BY zostalo zablokowane).
test-waf:
	@./scripts/test-waf.sh
