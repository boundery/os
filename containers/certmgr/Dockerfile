ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    echo "deb http://deb.debian.org/debian stretch-backports main" \
            >/etc/apt/sources.list.d/stretch-backports.list \
    && apt-get update \
    && apt-get install -t stretch-backports -y --no-install-recommends certbot \
    && rm -rf /var/lib/apt/lists/*

COPY certmgr /usr/local/sbin/
COPY certmgr-auth-hook /usr/local/sbin/
RUN ln -s certmgr-auth-hook /usr/local/sbin/certmgr-cleanup-hook
