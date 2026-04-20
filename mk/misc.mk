.PHONY: clean wait debug-show-current-settings

clean:
	-find . -name '*~' -o -name '\#*' -o -name '.*~' | xargs rm -f

wait:
	@bash scripts/wait-for-build.sh

debug-show-current-settings:
	docker compose exec appserver python src/manage.py debug_setup_initial_data --show-current
