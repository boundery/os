ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

COPY zt-gpg-key /
RUN    apt-key add /zt-gpg-key \
    && echo "deb http://download.zerotier.com/debian/stretch stretch main" > /etc/apt/sources.list.d/zt.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends zerotier-one python3-libnacl python3-hkdf \
    && rm -rf /var/lib/apt/lists/*

COPY start clientd zerotier.py zerotier_allow.py handle_client.py /
COPY zerotier-one /usr/sbin

CMD ["/start"]
