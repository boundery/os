ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    apt-get update \
    && apt-get install -y haproxy python3-mako \
    && rm -rf /var/lib/apt/lists/*

COPY start config haproxy.mako /

CMD ["bash", "/start"]
