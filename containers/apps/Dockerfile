ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3 as base

FROM base as builder

RUN    apt-get update \
    && apt-get install -y python3-pip \
    && pip3 install --no-cache docker \
    && rm -rf /var/lib/apt/lists/*

FROM base

COPY --from=builder /usr/local/lib/python3.5/dist-packages/ /usr/local/lib/python3.5/dist-packages/

WORKDIR /apps/
COPY start appserver.py /apps/

CMD ["/apps/start"]
