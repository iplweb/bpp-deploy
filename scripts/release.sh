#!/usr/bin/env bash
set -euo pipefail

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
