ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

RUN    apt-get update \
    && apt-get install -y --no-install-recommends \
           dropbear-bin \
    && rm -rf \
           /var/lib/apt/lists/* \
           /var/lib/dpkg/status-old \
           /var/log/apt \
           /var/log/dpkg.log

RUN    mkdir -p /etc/dropbear /root/.ssh \
    && chmod 700 /root/.ssh \
    && ln -s /boot/ssh_host_rsa_key /etc/dropbear/dropbear_rsa_host_key \
    && ln -s /boot/ssh_host_ecdsa_key /etc/dropbear/dropbear_ecdsa_host_key \
    && ln -s /boot/ssh_authorized_keys /root/.ssh/authorized_keys

COPY startsshd /usr/local/sbin/
