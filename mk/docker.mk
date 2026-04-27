.PHONY: docker-clean prune-orphan-volumes remove-rabbitmq-volume open-docker-volume open-all-docker-volumes \
       find-stale-compose-containers docker-compose-stop-rm-purge

docker-clean:
	docker system prune -f
	docker image prune -f

prune-orphan-volumes:
	docker volume prune -f

remove-rabbitmq-volume:
	@bash scripts/remove-rabbitmq-volume.sh

open-docker-volume: prune-orphan-volumes
	@VOLUME=$$(docker volume ls --format '{{.Name}}' | fzf --prompt="Select volume: ") && \
	docker run --rm -it -v "$$VOLUME":/volume -w /volume alpine:latest /bin/sh -c "ls -las; exec /bin/sh"

COMPOSE_PROJECT := $(notdir $(CURDIR))

open-all-docker-volumes: prune-orphan-volumes
	@MOUNTS=$$(docker volume ls --format '{{.Name}}' | grep "^$(COMPOSE_PROJECT)_" | while read vol; do \
		name=$${vol#$(COMPOSE_PROJECT)_}; \
		echo "-v $$vol:/volumes/$$name"; \
	done | tr '\n' ' ') && \
	docker run --rm -it $$MOUNTS -w /volumes alpine:latest /bin/sh -c "ls -las; exec /bin/sh"

find-stale-compose-containers:
	docker ps -a --filter label=com.docker.compose.project=$(shell basename "$(CURDIR)")

docker-compose-stop-rm-purge: stop rmrf docker-clean up
