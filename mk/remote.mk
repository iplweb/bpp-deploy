.PHONY: base-host-update-upgrade base-host-reboot install-docker

base-host-update-upgrade:
	sudo bash -c "apt update && apt -y full-upgrade && apt clean && apt autoclean && apt autoremove -y"

base-host-reboot:
	sudo reboot

install-docker:
	@echo "Installing Docker..."
	sudo bash -c "\
		apt remove -y $$(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null | cut -f1) 2>/dev/null || true && \
		apt update && \
		apt install -y ca-certificates curl && \
		install -m 0755 -d /etc/apt/keyrings && \
		curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
		chmod a+r /etc/apt/keyrings/docker.asc && \
		echo \"Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: $$(. /etc/os-release && echo \$$VERSION_CODENAME)\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\" > /etc/apt/sources.list.d/docker.sources && \
		apt update && \
		apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
	@echo "Docker installed successfully."
