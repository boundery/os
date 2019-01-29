ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    apt-get update \
    && apt-get install -y --no-install-recommends python3-bottle python3-gevent \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /web/
COPY start apiserver.py trans1x1.png /web/
COPY views/ /web/views/

CMD ["/web/start"]
