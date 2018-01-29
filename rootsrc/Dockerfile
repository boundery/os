ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

COPY *.deb /debs/

RUN    apt-get update \
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
           lvm2 \
           /debs/*.deb \
    && mkdir -p /var/lib/docker /etc/docker \
    && ln -s ../bin/busybox /sbin/mdev \
    && rm -rf /var/tmp && ln -s /tmp /var/tmp \
    && rm -rf /var/lib/openntpd && ln -sf /run/openntpd /var/lib/openntpd \
    && rm -rf /debs \
    && rm -rf /var/lib/apt/lists/*

COPY init /sbin/
COPY fstab /etc/
COPY mdev.conf /etc/
COPY wpa_supplicant.conf /usr/local/etc
COPY mkwpaconf /usr/local/sbin
COPY startdocker /usr/local/sbin
COPY netd /usr/local/sbin
COPY storagemgr /usr/local/sbin
COPY unsplit-tar /usr/local/sbin
COPY sethostname /etc/dhcp/dhclient-exit-hooks.d
