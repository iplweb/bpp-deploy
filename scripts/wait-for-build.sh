#!/bin/bash
set -euo pipefail

# Check/install dependencies
for cmd in gh jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Installing $cmd..."
        sudo apt install -y "$cmd"
    fi
done

# Poll GitHub Actions workflow
while true; do
    status=$(gh run list \
        --workflow "Docker - oficjalne obrazy" \
        --repo iplweb/bpp \
        --json status --limit 1 \
        | jq -r '.[0].status // "completed"')

    case "$status" in
        queued|in_progress)
            echo "Workflow: $status, waiting..."
            sleep 5
            ;;
        *)
            echo "Workflow completed."
            sleep 15
            make repull
            make restart
            break
            ;;
    esac
done
