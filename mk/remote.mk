.PHONY: base-host-update-upgrade base-host-reboot install-docker

base-host-update-upgrade:
	sudo bash -c "apt update && apt -y full-upgrade && apt clean && apt autoclean && apt autoremove -y"

base-host-reboot:
	sudo reboot

install-docker:
	sudo bash scripts/install-docker.sh
