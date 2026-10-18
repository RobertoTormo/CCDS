#!/bin/sh
# Puts the certificate nginx must use into /etc/nginx/certs:
#  - the Let's Encrypt one, if certbot has already issued it;
#  - otherwise a temporary self-signed one, so nginx can always start.
# Exit code: 0 = certificate changed (nginx must reload), 1 = unchanged.

LE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
SELF_DIR="/etc/nginx/selfsigned"
DST_DIR="/etc/nginx/certs"
mkdir -p "$DST_DIR" "$SELF_DIR"

if [ -f "$LE_DIR/fullchain.pem" ] && [ -f "$LE_DIR/privkey.pem" ]; then
    SRC_DIR="$LE_DIR"
else
    if [ ! -f "$SELF_DIR/fullchain.pem" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
            -subj "/CN=${DOMAIN}" \
            -keyout "$SELF_DIR/privkey.pem" \
            -out "$SELF_DIR/fullchain.pem" 2>/dev/null
    fi
    SRC_DIR="$SELF_DIR"
fi

if cmp -s "$SRC_DIR/fullchain.pem" "$DST_DIR/fullchain.pem"; then
    exit 1
fi

cp "$SRC_DIR/fullchain.pem" "$DST_DIR/fullchain.pem"
cp "$SRC_DIR/privkey.pem" "$DST_DIR/privkey.pem"
echo "link-certs: using certificate from $SRC_DIR"
exit 0
