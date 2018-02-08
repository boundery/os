ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

COPY zt-gpg-key /
RUN    apt-key add /zt-gpg-key \
    && echo "deb http://download.zerotier.com/debian/stretch stretch main" > /etc/apt/sources.list.d/zt.list \
    && apt-get update \
    && apt-get install -y zerotier-one \
    && rm -rf /var/lib/apt/lists/*

COPY zerotier_allow.py /
COPY start.sh /

CMD ["bash", "/start.sh"]
