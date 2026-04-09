.PHONY: release version

version:
	@if git describe --tags --abbrev=0 >/dev/null 2>&1; then \
		echo "BPP Deploy $$(git describe --tags --abbrev=0)"; \
	else \
		echo "Brak tagów wersji. Uruchom 'make release' aby utworzyć pierwszą wersję."; \
	fi

release:
	@scripts/release.sh
