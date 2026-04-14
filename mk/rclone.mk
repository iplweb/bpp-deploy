.PHONY: rclone-sync rclone-config rclone-check backup-cycle

# Wszystkie polecenia rclone i caly cykl backupu dzialaja wewnatrz serwisu
# backup-runner (patrz docker-compose.backup.yml). Do backup-runnera
# doinstalowuje rclone przez apk add na starcie, wiec trzeba poczekac az
# healthcheck przejdzie zanim polecenia beda dostepne.

RCLONE_REMOTE ?= $(if $(DJANGO_BPP_RCLONE_REMOTE),$(DJANGO_BPP_RCLONE_REMOTE),backup_enc:)

rclone-sync:
	docker compose exec backup-runner \
		rclone --config /config/rclone/rclone.conf \
		sync /backup/ $(RCLONE_REMOTE)$$(date +%Y-%m)/$$(date +%d)/

rclone-config:
	docker compose exec backup-runner \
		rclone --config /config/rclone/rclone.conf config

rclone-check:
	docker compose exec backup-runner \
		rclone --config /config/rclone/rclone.conf ls $(RCLONE_REMOTE)

# Pelny cykl backupu: pg_dump + tar media + rotacja + rclone sync + Rollbar notify.
# Ofelia wola to samo raz dziennie przez label na backup-runner.
backup-cycle:
	docker compose exec backup-runner /scripts/backup-cycle.sh
