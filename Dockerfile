# syntax=docker/dockerfile:1
ARG OPENCONNECT_VERSION=latest

########################
# 构建阶段：编译 OpenConnect
########################
FROM debian:bookworm-slim AS builder
ARG OPENCONNECT_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential autoconf automake libtool pkg-config gettext \
        libxml2-dev libgnutls28-dev zlib1g-dev libproxy-dev \
        liblz4-dev libpskc-dev libp11-kit-dev \
        ca-certificates curl wget xz-utils jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 若未由 --build-arg 指定明确版本号，则自动从 GitLab 获取最新 tag
RUN set -eu; \
    if [ "$OPENCONNECT_VERSION" = "latest" ]; then \
        VER=$(curl -fsSL "https://gitlab.com/api/v4/projects/openconnect%2Fopenconnect/repository/tags" \
              | jq -r '[.[].name | select(startswith("v"))] | sort_by(.) | .[-1]' \
              | sed 's/^v//'); \
    else \
        VER="$OPENCONNECT_VERSION"; \
    fi; \
    echo "==> 编译 OpenConnect 版本: ${VER}"; \
    echo "${VER}" > /build/VERSION; \
    ( curl -fsSL "https://www.infradead.org/openconnect/download/openconnect-${VER}.tar.gz" -o openconnect.tar.gz \
      || curl -fsSL "ftp://ftp.infradead.org/pub/openconnect/openconnect-${VER}.tar.gz" -o openconnect.tar.gz ); \
    tar xf openconnect.tar.gz --strip-components=1

RUN ./configure --prefix=/usr --without-gssapi --disable-nls \
    && make -j"$(nproc)" \
    && make install DESTDIR=/install

########################
# 运行阶段：精简镜像
########################
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libxml2 libgnutls30 zlib1g libproxy1v5 liblz4-1 libpskc0 \
        iproute2 iptables vpnc-scripts iputils-ping ca-certificates bash \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /install/usr /usr
COPY --from=builder /build/VERSION /VERSION

COPY vpnc-script-nat /usr/local/bin/vpnc-script-nat
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/vpnc-script-nat /entrypoint.sh

LABEL org.opencontainers.image.title="openconnect-site2site" \
      org.opencontainers.image.description="OpenConnect VPN client container with NAT for site-to-site connectivity"

ENTRYPOINT ["/entrypoint.sh"]