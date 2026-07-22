FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/tmp

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        bash \
        binutils \
        build-essential \
        bzip2 \
        ca-certificates \
        coreutils \
        curl \
        debianutils \
        diffutils \
        file \
        findutils \
        gawk \
        gettext \
        git \
        grep \
        gzip \
        libncurses-dev \
        libssl-dev \
        openssl \
        patch \
        perl \
        python3 \
        python3-setuptools \
        rsync \
        squashfs-tools \
        tar \
        unzip \
        util-linux \
        wget \
        xsltproc \
        xz-utils \
        zlib1g-dev \
        zstd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
USER 65532:65532
