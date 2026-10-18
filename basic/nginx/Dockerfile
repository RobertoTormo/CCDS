# Frontend reverse proxy for the whole infrastructure (stack "basic").
# Stable branch of nginx, pinned (no :latest, see CONVENTIONS.md section 6).
FROM nginx:1.30-alpine

# openssl: used only to create a temporary self-signed certificate
# until Let's Encrypt has issued the real one.
RUN apk add --no-cache openssl

# Defaults for local use; production.yml overrides them.
ENV DOMAIN=localhost \
    CERT_NAME=balkan-ccds

# The official nginx image renders /etc/nginx/templates/*.template into
# /etc/nginx/conf.d/ at start, replacing ${DOMAIN} with the env variable.
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY proxy_params.conf /etc/nginx/proxy_params.conf
COPY link-certs.sh /usr/local/bin/link-certs.sh
# Scripts in /docker-entrypoint.d/ run before nginx starts.
COPY 40-certs.sh /docker-entrypoint.d/40-certs.sh
RUN chmod +x /usr/local/bin/link-certs.sh /docker-entrypoint.d/40-certs.sh
