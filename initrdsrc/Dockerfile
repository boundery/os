ARG FROM_PREFIX

FROM ${FROM_PREFIX}busybox:1.28.0-uclibc

ARG BOOT_MNT

RUN mkdir /boot /newroot

COPY init /
COPY fstab /etc/
RUN sed -i "s|XBOOT_MNTX|$BOOT_MNT|g" /etc/fstab

