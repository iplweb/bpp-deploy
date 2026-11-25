.PHONY: rclone-sync rclone-config rclone-check backup-cycle images-save

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
# retencja zdalna + Rollbar notify. Target CELOWO exec-uje w backup-runnerze:
# to orkiestrator (docker:cli), ktory sam wykonuje tylko sekwencje i tar,
# a pg_dump/rclone/notyfikacje deleguje przez `docker exec` do dbservera,
# serwisu rclone i appservera. Ofelia wola to samo raz dziennie przez label
# na backup-runner.
# BPP_BACKUP_CYCLE_FORCE=1: reczne wywolanie omija wylacznik nocnego cyklu
# (DJANGO_BPP_BACKUP_ENABLED=0) - operator swiadomie prosi o backup.
backup-cycle:
	docker compose exec -e BPP_BACKUP_CYCLE_FORCE=1 backup-runner /scripts/backup-cycle.sh

# Archiwum obrazow Dockera + git bundle repo (odtworzenie bez Docker Huba
# i GitHuba). Ten sam skrypt co krok 2c nocnego cyklu, w tym samym kontenerze
# (docker:cli ma docker CLI, socket, git i gzip), wiec zapis do /backup jako
# root dziala identycznie. Reczne wywolanie ignoruje wylacznik
# DJANGO_BPP_BACKUP_IMAGES_ENABLED.
#   make images-save              # nowy zestaw tylko, gdy obrazy sie zmienily
#   make images-save FORCE=1      # wymus nowy zestaw
#   make images-save MONITORING=1 # dolacz netdata/loki/grafana/alloy/dozzle/flower
# Odtworzenie: make images-load FILE=... (Makefile, przed ifdef FIRST_RUN).
images-save:
	docker compose exec -T \
		-e DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST=$(DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST) \
		-e DJANGO_BPP_BACKUP_IMAGES_MONITORING=$(if $(MONITORING),1,$(DJANGO_BPP_BACKUP_IMAGES_MONITORING)) \
		backup-runner /scripts/images-archive.sh save $(if $(FORCE),--force)
