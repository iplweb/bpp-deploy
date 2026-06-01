#!/bin/bash
set -euo pipefail

# Check/install dependencies
for cmd in gh jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Installing $cmd..."
        sudo apt install -y "$cmd"
    fi
done

# Poll GitHub Actions workflow.
#
# Deploy NASTEPUJE wylacznie gdy run zakonczyl sie sukcesem (conclusion=success).
# Wczesniej kazdy NIE-running status (failure/cancelled/timed_out, a takze BRAK
# runu przez `// "completed"`) triggerowal pull+restart — nieudany build upstreamu
# i tak wymuszal produkcyjny deploy. Teraz failure/brak runu => exit 1, bez deployu.
while true; do
    read -r status conclusion < <(gh run list \
        --workflow "Docker - oficjalne obrazy" \
        --repo iplweb/bpp \
        --json status,conclusion --limit 1 \
        | jq -r '.[0] // {} | "\(.status // "missing") \(.conclusion // "")"')

    case "$status" in
        queued|in_progress)
            echo "Workflow: $status, czekam..."
            sleep 5
            ;;
        completed)
            if [ "$conclusion" = "success" ]; then
                echo "Workflow zakonczony sukcesem — pull + restart."
                sleep 15
                make pull
                make restart
            else
                echo "Workflow zakonczony ze statusem '$conclusion' (!= success) — NIE deployuje." >&2
                exit 1
            fi
            break
            ;;
        *)
            echo "Nieoczekiwany status / brak runu (status='$status') — NIE deployuje." >&2
            exit 1
            ;;
    esac
done
