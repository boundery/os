ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

COPY *.pub /keys/

ARG ARCH

RUN    apt-get update \
    && apt-get install -y --no-install-recommends gnupg apt-transport-https ca-certificates \
    && if [ "$ARCH" = armhf ]; then \
           apt-key add /keys/raspbian.pub \
        && echo 'deb http://archive.raspberrypi.org/debian/ stretch main' \
                >/etc/apt/sources.list.d/raspbian.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends firmware-brcm80211 \
       ;fi \
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
    && apt-get remove -y --purge --autoremove gnupg apt-transport-https \
    && mkdir -p /var/lib/docker /etc/docker \
    && ln -s ../bin/busybox /sbin/mdev \
    && rm -rf /var/tmp && ln -s /tmp /var/tmp \
    && rm -rf /var/lib/openntpd && ln -sf /run/openntpd /var/lib/openntpd \
    && rm -rf /keys \
    && rm -rf /var/lib/apt/lists/*

COPY init /sbin/
COPY fstab /etc/
COPY modules.${ARCH} /etc/modules
COPY mdev.conf /etc/
COPY wpa_supplicant.conf /usr/local/etc
COPY mkwpaconf /usr/local/sbin
COPY startdocker /usr/local/sbin
COPY netd /usr/local/sbin
COPY runcontainer /usr/local/sbin
COPY storaged /usr/local/sbin
COPY smdocker /usr/local/sbin
COPY certmgr /usr/local/sbin
COPY unsplit-tar /usr/local/sbin
COPY sethostname /etc/dhcp/dhclient-exit-hooks.d
