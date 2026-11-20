#!/bin/sh
# NGINX2Root guard (CVE-2026-123007: unauthenticated RCE in HTTP/2 flow control,
# plus use-after-free in HTTP/2 and HTTP/3; fixed in nginx 1.30.7 / 1.31.9).
#
# Runs LAST in /docker-entrypoint.d/ (after the CRS image's 96-update-http3-config.sh
# and our 30-render-bpp-vhosts.sh), when every config file is already rendered.
# If the nginx binary in the image is still vulnerable, it switches HTTP/2 and
# HTTP/3 off in the RENDERED config; on a fixed nginx it does nothing.
#
# Why it exists: our templates have h2/h3 ON, and the image tag
# (owasp/modsecurity-crs:nginx) floats. `make up` does NOT pull images (only
# `make run`/`make pull` do), so `git pull && make up` on a host whose local
# image still has nginx 1.30.6 would turn h2 back on over the vulnerable binary.
# This script makes the template safe regardless of which image is local.
#
# Unparseable version -> treated as vulnerable (falls back to HTTP/1.1, the site
# keeps working). Never exits non-zero: a failed guard must not keep nginx down.
#
# BPP_NGINX_CONF_ROOT exists only for tests/test_makefile.sh
# (test_nginx2root_guard), which runs this script on the host with a stub `nginx`.

ME="99-bpp-nginx2root-guard.sh"
ROOT="${BPP_NGINX_CONF_ROOT:-/etc/nginx}"

ver=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')

vulnerable=$(echo "$ver" | awk -F. '
    NF < 3 { print 1; exit }
    {
        maj = $1 + 0; min = $2 + 0; pat = $3 + 0
        if (maj > 1)                       { print 0; exit }
        if (maj == 1 && min > 31)          { print 0; exit }
        if (maj == 1 && min == 31)         { print (pat >= 9 ? 0 : 1); exit }
        if (maj == 1 && min == 30)         { print (pat >= 7 ? 0 : 1); exit }
        print 1
    }')
# Empty input -> awk prints nothing -> vulnerable.
vulnerable="${vulnerable:-1}"

if [ "$vulnerable" = "0" ]; then
    echo "$ME: nginx $ver is patched for NGINX2Root, HTTP/2 + HTTP/3 stay as configured"
    exit 0
fi

echo "$ME: WARNING: nginx ${ver:-<unknown>} is vulnerable to NGINX2Root (CVE-2026-123007)." >&2
echo "$ME: WARNING: switching HTTP/2 and HTTP/3 OFF. Fix: make pull && make up (needs nginx >= 1.30.7)." >&2

for f in "$ROOT/nginx.conf" "$ROOT"/conf.d/*.conf; do
    [ -f "$f" ] || continue
    # `http2 on` -> off (nginx.conf gets it from the CRS image's `http2 ${HTTP2}`);
    # drop QUIC listeners and `http3 on`; tell browsers to forget cached h3.
    if ! sed -i -E \
        -e 's/^([[:space:]]*)http2[[:space:]]+on;/\1http2 off;/' \
        -e '/^[[:space:]]*listen[^;]*[[:space:]]quic([[:space:]][^;]*)?;/d' \
        -e 's/^([[:space:]]*)http3[[:space:]]+on;/\1http3 off;/' \
        -e "s/add_header[[:space:]]+Alt-Svc[[:space:]]+'h3=[^']*'/add_header Alt-Svc 'clear'/" \
        "$f"; then
        echo "$ME: ERROR: could not rewrite $f — HTTP/2/3 may still be ON" >&2
    fi
done
exit 0
