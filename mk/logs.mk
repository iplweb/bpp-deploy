.PHONY: logs logs-celery logs-appserver logs-dbserver logs-denorm ps

logs:
	docker compose logs -f

logs-celery:
	docker compose logs workerserver-general workerserver-denorm -f

logs-appserver:
	docker compose logs appserver -f

logs-dbserver:
	docker compose logs dbserver -f

logs-denorm:
	docker compose logs denorm-queue -f

ps:
	docker compose ps
