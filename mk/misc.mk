.PHONY: clean wait debug-show-current-settings

REMOTE_BPP_USERNAME?=admin

clean:
	-find . -name '*~' -o -name '\#*' -o -name '.*~' | xargs rm -f

wait:
	@while true; do \
		status=$$(gh run list --workflow "Docker - oficjalne obrazy" --repo iplweb/bpp --json status --limit 1 | jq -r '.[0].status // "completed"'); \
		if [ "$$status" = "queued" ]; then \
			echo "Workflow 'Docker - oficjalne obrazy' is queued, waiting..."; \
			sleep 5; \
		elif [ "$$status" = "in_progress" ]; then \
			echo "Workflow 'Docker - oficjalne obrazy' is in progress, waiting..."; \
			sleep 5; \
		else \
			echo "Workflow 'Docker - oficjalne obrazy' completed, running make in 15 secs..."; \
			sleep 15; \
			$(MAKE) refresh; \
			break; \
		fi; \
	done

debug-show-current-settings:
	docker compose exec appserver uv run src/manage.py debug_setup_initial_data --show-current
