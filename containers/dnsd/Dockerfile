ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    echo "deb http://deb.debian.org/debian buster main" \
            >/etc/apt/sources.list.d/buster.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3-dnslib \
    && rm -rf /var/lib/apt/lists/*

COPY dnsd /usr/local/sbin/
