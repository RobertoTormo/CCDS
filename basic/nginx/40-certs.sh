#!/bin/sh
# Run by the nginx image entrypoint before nginx starts.
# 1) prepare a certificate now; 2) every 5 minutes check whether certbot
# issued/renewed the Let's Encrypt certificate and, if so, reload nginx
# (a reload swaps the certificate without dropping connections).
/usr/local/bin/link-certs.sh || true

(
    while true; do
        sleep 300
        if /usr/local/bin/link-certs.sh; then
            nginx -s reload
        fi
    done
) &
