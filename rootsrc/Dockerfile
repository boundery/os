ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

ARG ARCH

COPY *.pub /keys/

RUN    apt-get update \
    && apt-get install -y --no-install-recommends gnupg apt-transport-https ca-certificates \
    && apt-key add /keys/docker.pub \
    && echo 'deb https://download.docker.com/linux/debian/ stretch stable' \
            >/etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
           kmod \
           net-tools \
           isc-dhcp-client \
           inetutils-ping \
           dnsutils \
           wpasupplicant \
           openntpd \
           nvi \
           ca-certificates \
           procps \
           busybox-syslogd \
           dosfstools \
           lvm2 \
           docker-ce \
           xz-utils \
    && apt-get remove -y --purge --autoremove gnupg apt-transport-https \
    && mkdir -p /var/lib/docker /etc/docker \
    && ln -s ../bin/busybox /sbin/mdev \
    && rm -rf /var/tmp && ln -s /tmp /var/tmp \
    && rm -rf /var/lib/openntpd && ln -sf /run/openntpd /var/lib/openntpd \
    && rm -rf /keys \
    && rm -rf /var/lib/apt/lists/*

COPY fstab mdev.conf /etc/
COPY modules.${ARCH} /etc/modules
COPY sethostname /etc/dhcp/dhclient-exit-hooks.d/
COPY wpa_supplicant.conf /usr/local/etc/
COPY init /sbin/
COPY unsplit-tar certmgr storaged runcontainer netd startdocker mkwpaconf /usr/local/sbin/
