ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

#XXX gnupg and others like it should live in an intermediate image
#    that both this and rootfs inherit from.
#XXX Temp added some more useful tools that should go in intermediate img in DEBUG=1 mode.
RUN    apt-get update \
    && apt-get install -y --no-install-recommends \
           python3 python3-requests \
           gnupg openssl \
           iputils-ping iproute2 socat procps net-tools \
    && rm -rf /var/lib/apt/lists/*
