ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

#XXX gnupg and others like it should live in an intermediate image
#    that both this and rootfs inherit from.
RUN    apt-get update \
    && apt-get install -y --no-install-recommends \
           python3 python3-requests gnupg \
    && rm -rf /var/lib/apt/lists/*
