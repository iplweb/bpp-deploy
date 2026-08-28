.PHONY: base-host-update-upgrade base-host-reboot install-docker

base-host-update-upgrade:
	sudo bash -c "apt update && apt -y full-upgrade && apt clean && apt autoclean && apt autoremove -y"

base-host-reboot:
	sudo reboot

# Bez sudo: skrypt sam podbija uprawnienia na Linuksie. Pod Git Bash sudo
# nie istnieje, a Docker Desktop instaluje sie przez winget (UAC), wiec
# sudo w tym miejscu wywracalo target na Windows przed startem skryptu.
install-docker:
	@bash scripts/install-docker.sh
