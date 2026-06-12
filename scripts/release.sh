#!/usr/bin/env bash
set -euo pipefail

# Working tree musi byc czysty (poza README.md, ktore zaraz sami zmienimy
# i zacommitujemy). Bez tego guardu `git add README.md && git commit`
# zabralby do release-commita takze przypadkowo zastage'owane zmiany.
if ! git diff --cached --quiet; then
    echo "ERROR: staging area nie jest pusty - commitnij lub odstage'uj przed release." >&2
    git status --short >&2
    exit 1
fi
if ! git diff --quiet -- . ':(exclude)README.md'; then
    echo "ERROR: working tree ma niezacommitowane zmiany (poza README.md)." >&2
    git status --short >&2
    exit 1
fi

TODAY=$(date +%Y.%m.%d)
SUFFIX=0

if git tag --list "$TODAY" | grep -q "$TODAY"; then
    while git tag --list "$TODAY.$SUFFIX" | grep -q "$TODAY.$SUFFIX"; do
        SUFFIX=$((SUFFIX + 1))
    done
    VERSION="$TODAY.$SUFFIX"
else
    VERSION="$TODAY"
fi

echo "Wersja: $VERSION"

sed -i.bak "s|version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*[^)]*-blue|version-$VERSION-blue|" README.md
rm -f README.md.bak

git add README.md
git commit -m "release: $VERSION"
git tag "$VERSION"

echo ""
echo "Tag $VERSION utworzony. Wysyłam na serwer..."
git push origin main --tags
echo "Gotowe."
