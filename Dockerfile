FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 \
        mawk \
        passwd \
        procps \
        util-linux \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*
