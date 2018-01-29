ARG FROM_PREFIX

FROM ${FROM_PREFIX}debian:stretch-slim

RUN    apt-get update \
    && apt-get install -y --no-install-recommends \
           python3 python3-requests \
    && rm -rf /var/lib/apt/lists/*
