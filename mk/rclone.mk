.PHONY: rclone-sync rclone-config rclone-check backup-cycle

# Wszystkie polecenia rclone i caly cykl backupu dzialaja wewnatrz serwisu
# backup-runner (patrz docker-compose.backup.yml). Do backup-runnera
# doinstalowuje rclone przez apk add na starcie, wiec trzeba poczekac az
# healthcheck przejdzie zanim polecenia beda dostepne.

RCLONE_REMOTE ?= $(if $(DJANGO_BPP_RCLONE_REMOTE),$(DJANGO_BPP_RCLONE_REMOTE),backup_enc:)

# Sciezka docelowa i wybor `copy` vs `sync` NIE moga byc tutaj: dokladnie ta
# sama logika siedzi w scripts/backup-cycle.sh i az do sierpnia 2026 byla
# skopiowana w obu miejscach. Jedno zrodlo to scripts/lib-rclone.sh.
# RCLONE_REMOTE przekazujemy jawnie: po przeniesieniu logiki do skryptu
# `make rclone-sync RCLONE_REMOTE=inny:` bylby po cichu ignorowany (skrypt
# czytalby DJANGO_BPP_RCLONE_REMOTE z .env), a `rclone-check` z tym samym
# overridem pokazywalby JUZ INNY remote - dwie komendy rozjechane bez bledu.
rclone-sync:
	docker compose exec -e DJANGO_BPP_RCLONE_REMOTE=$(RCLONE_REMOTE) \
		backup-runner /scripts/rclone-sync.sh

rclone-config:
	docker compose exec backup-runner \
		rclone --config /config/rclone/rclone.conf config

rclone-check:
	docker compose exec backup-runner \
		rclone --config /config/rclone/rclone.conf ls $(RCLONE_REMOTE)

# Pelny cykl backupu: pg_dump + tar media + rotacja lokalna + rclone copy +
# retencja zdalna + Rollbar notify.
# Ofelia wola to samo raz dziennie przez label na backup-runner.
backup-cycle:
	docker compose exec backup-runner /scripts/backup-cycle.sh
