#!/usr/bin/env bash
# Usuwa volume RabbitMQ (rabbitmq_data) i restartuje stack.
# Wszystkie kolejki i wiadomosci RabbitMQ zostana utracone.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [ ! -f .env ]; then
    echo "BLAD: brak .env w $REPO_DIR" >&2
    exit 1
fi

# shellcheck source=/dev/null
set -a; . ./.env; set +a

if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    echo "BLAD: COMPOSE_PROJECT_NAME nie ustawione w .env" >&2
    exit 1
fi

VOLUME_NAME="${COMPOSE_PROJECT_NAME}_rabbitmq_data"

echo ""
echo "UWAGA: usuwam volume RabbitMQ — wszystkie kolejki i wiadomosci"
echo "(w tym nieprzetworzone zadania Celery) zostana skasowane."
echo ""
echo "  Projekt: ${COMPOSE_PROJECT_NAME}"
echo "  Volume:  ${VOLUME_NAME}"
echo ""
read -r -p "Kontynuowac? [y/N] " confirm
case "${confirm:-}" in
    y|Y) ;;
    *) echo "Anulowano."; exit 1 ;;
esac

echo ""
echo "[1/3] Zatrzymuje rabbitmq..."
docker compose down rabbitmq

echo ""
echo "[2/3] Usuwam volume ${VOLUME_NAME}..."
docker volume rm "${VOLUME_NAME}"

echo ""
echo "[3/3] Startuje stack..."
docker compose up -d

echo ""
echo "Gotowe. RabbitMQ wystartowal z czystym volumem."
