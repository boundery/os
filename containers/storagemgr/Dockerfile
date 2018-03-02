ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    apt-get update \
    && apt-get install -y --no-install-recommends \
           lvm2 \
           dosfstools \
    && rm -rf /var/lib/apt/lists/*

COPY storagemgr /usr/local/sbin/
