ARG FROM_PREFIX

FROM ${FROM_PREFIX}busybox:1.28.0-uclibc

RUN mkdir /boot /newroot

COPY init /
COPY fstab /etc/
