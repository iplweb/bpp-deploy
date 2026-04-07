.PHONY: rclone-sync rclone-config rclone-check

rclone-sync:
	docker compose exec rclone rclone sync /backup/ backup_enc:`date +%Y-%m`/`date +%d`/

rclone-config:
	docker compose exec rclone rclone config

rclone-check:
	docker compose exec rclone rclone ls backup_enc:
