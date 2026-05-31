# Wydanie

Wersjonowanie kalendarzowe: `YYYY.MM.DD` (pierwsze danego dnia) lub `YYYY.MM.DD.N`
(auto-inkrementowany sufiks od 0). Np. `2026.04.19`, `2026.04.19.0`, `2026.04.19.1`.

```bash
make release          # Tag + push
make version          # Wyświetl bieżącą wersję
```

## Co robi `make release`

Skrypt `scripts/release.sh`:

1. Liczy następną wersję z dzisiejszej daty + istniejących tagów
2. `sed` badge wersji w README (`version-X.Y.Z-blue`) → nowa wersja
3. `git add README.md && git commit -m "release: $VERSION"`
4. `git tag $VERSION`
5. `git push origin main --tags`

## Wymagania

- Working tree musi być czysty (oprócz README, który skrypt modyfikuje).
- Brak `CHANGELOG.md` — historia to `git log --grep='^release:'`.

!!! note "Calendar versioning"
    Brak decyzji major/minor/patch. Breaking changes sygnalizuj w treści commita +
    README. O zasadach kompatybilności wstecznej (`.env`) czytaj w
    [Backwards compatibility](../rozwoj/backwards-compatibility.md).
