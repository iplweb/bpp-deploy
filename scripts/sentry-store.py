"""Wysyla jedno zdarzenie do GlitchTip/Sentry (endpoint /api/<projekt>/store/).

Uruchamiane WEWNATRZ appservera, z programem podanym na stdin:

    docker exec -i -e BPP_SENTRY_LEVEL=... -e BPP_SENTRY_MSG=... <appserver> \
        python - < scripts/sentry-store.py

Celowo bez `sentry-sdk`: dziala na kazdym obrazie appservera (takze sprzed
wprowadzenia biblioteki do BPP) i nie zalezy od niczego poza stdlib.
DSN czytamy z env appservera (jego env_file), wiec sekret nie przechodzi
przez `-e` ani liste procesow orkiestratora - tak samo jak token Rollbara.

Zmienne:
    SENTRY_DSN          - z env_file appservera; pusty -> komunikat i exit 0
    BPP_SENTRY_LEVEL    - info / warning / error (domyslnie error)
    BPP_SENTRY_MSG      - tresc zdarzenia
    BPP_SENTRY_ENV      - environment (domyslnie SENTRY_ENVIRONMENT albo "production")
    BPP_SENTRY_LOGGER   - logger/komponent (domyslnie backup-cycle)
    BPP_SENTRY_TS       - znacznik cyklu, trafia do "extra"
    BPP_SENTRY_FINGERPRINT - opcjonalny klucz grupowania, lista po przecinku
                          (np. "backup-cycle,fail,<host>,pg_dump"); pusty =
                          GlitchTip grupuje po tresci (kazda inna tresc =
                          nowe zgloszenie)

Kod wyjscia: 0 przy wyslaniu albo braku DSN; !=0 przy bledzie sieci/HTTP.
Wolajacy (backup-cycle.sh) i tak go polyka - notyfikacja nie moze zmienic
wyniku backupu.
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request
import uuid


def store_url_and_key(dsn):
    parts = urllib.parse.urlsplit(dsn)
    if not parts.username or not parts.hostname:
        raise ValueError("SENTRY_DSN nie wyglada na DSN (brak klucza albo hosta)")
    path = parts.path.strip("/")
    prefix, _, project = path.rpartition("/")
    if not project:
        raise ValueError("SENTRY_DSN nie zawiera numeru projektu")
    netloc = parts.hostname + (f":{parts.port}" if parts.port else "")
    base = f"{parts.scheme}://{netloc}" + (f"/{prefix}" if prefix else "")
    return f"{base}/api/{project}/store/", parts.username


def main():
    dsn = os.environ.get("SENTRY_DSN", "").strip()
    if not dsn:
        print("skip (brak SENTRY_DSN w appserverze - po dopisaniu do .env potrzebny make up)")
        return 0
    url, key = store_url_and_key(dsn)
    event = {
        "event_id": uuid.uuid4().hex,
        "timestamp": time.time(),
        "level": os.environ.get("BPP_SENTRY_LEVEL", "error"),
        "platform": "other",
        "logger": os.environ.get("BPP_SENTRY_LOGGER", "backup-cycle"),
        "message": os.environ.get("BPP_SENTRY_MSG", ""),
        "environment": os.environ.get("BPP_SENTRY_ENV")
        or os.environ.get("SENTRY_ENVIRONMENT")
        or "production",
        "tags": {"component": os.environ.get("BPP_SENTRY_LOGGER", "backup-cycle")},
        "extra": {"timestamp": os.environ.get("BPP_SENTRY_TS", "")},
    }
    fingerprint = [
        czesc.strip()
        for czesc in os.environ.get("BPP_SENTRY_FINGERPRINT", "").split(",")
        if czesc.strip()
    ]
    if fingerprint:
        event["fingerprint"] = fingerprint
    req = urllib.request.Request(
        url,
        data=json.dumps(event).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Sentry-Auth": (
                "Sentry sentry_version=7, sentry_client=bpp-deploy/1.0, "
                f"sentry_key={key}"
            ),
        },
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        print(f"http={r.status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
