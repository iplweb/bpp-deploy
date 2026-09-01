.PHONY: rclone-sync rclone-config rclone-check backup-cycle

# Polecenia rclone (sync/config/check) dzialaja wewnatrz zadeklarowanego
# serwisu compose `rclone` (obraz rclone/rclone, patrz docker-compose.backup.yml).
# Serwis niczego nie doinstalowuje w runtime - narzedzie jest gotowe od razu,
# wystarczy poczekac az przejdzie healthcheck.

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
		rclone /scripts/rclone-sync.sh

# Kreator + wyrownanie wlasciciela rclone.conf (powstaje jako root, bo kontener
# jest rootem) — logika w scripts/rclone-config.sh, nie tutaj.
rclone-config:
	docker compose exec rclone /scripts/rclone-config.sh

rclone-check:
	docker compose exec rclone \
		rclone --config /config/rclone/rclone.conf ls $(RCLONE_REMOTE)

# Pelny cykl backupu: pg_dump + tar media + rotacja lokalna + rclone copy +
# retencja zdalna + Rollbar notify. Nadal dziala w backup-runnerze - to
# Zadanie 3 przenosi sama orkiestracje cyklu na osobne kontenery, nie ten plik.
# Ofelia wola to samo raz dziennie przez label na backup-runner.
backup-cycle:
	docker compose exec backup-runner /scripts/backup-cycle.sh
