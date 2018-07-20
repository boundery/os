ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    apt-get update \
    && apt-get install -y python3-docker \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /apps/
COPY start appserver.py /apps/

CMD ["/apps/start"]
