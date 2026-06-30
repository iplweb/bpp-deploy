# Diagnostyka (doctor) - interaktywne menu testow powiadomien/uslug.
#
# Laczy domeny: django (test-email/test-rollbar), monitoring (test-ntfy),
# deployment (health), rclone (backup-cycle). Stad osobny plik zamiast
# doklejania do ktorejs domeny.

.PHONY: doctor test-doctor

# Interaktywne menu: wybierz mail / ntfy / rollbar / health / backup / wszystko.
# Deploy (`make run`) NIE testuje juz nic automatycznie - to jest punkt wejscia.
doctor:
	@bash scripts/doctor.sh

# Unit-testy scripts/doctor.sh (mock make, bez sieci/dockera).
test-doctor:
	@bash scripts/test-doctor.sh
