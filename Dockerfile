FROM alpine:3.23

LABEL description="synology-certbot-cloudflare: Certbot with Cloudflare DNS plugin and Synology deploy support"

RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-cryptography \
    curl \
    jq \
    bash \
    tzdata \
    openssl \
    ca-certificates \
    inotify-tools \
    && pip3 install --no-cache-dir --break-system-packages \
        certbot \
        certbot-dns-cloudflare \
    && rm -rf /var/cache/apk/* /tmp/*

RUN mkdir -p \
    /etc/letsencrypt \
    /var/lib/letsencrypt \
    /var/log/letsencrypt \
    /config \
    /scripts

COPY entrypoint.sh /scripts/entrypoint.sh
COPY deploy-hook.sh /scripts/deploy-hook.sh

RUN chmod +x /scripts/entrypoint.sh /scripts/deploy-hook.sh

VOLUME ["/etc/letsencrypt", "/var/lib/letsencrypt", "/var/log/letsencrypt", "/config"]

ENTRYPOINT ["/scripts/entrypoint.sh"]
