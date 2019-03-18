ARG FROM_PREFIX

FROM ${FROM_PREFIX}python3

RUN    apt-get update \
    && apt-get install -y --no-install-recommends python3-hkdf \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /registration/
COPY register.py /registration/

