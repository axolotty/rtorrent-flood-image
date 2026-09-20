# rtorrent-flood — image combinée maison, basée sur rakshasa/rtorrent (upstream
# vivant) + libtorrent, au lieu du fork jesec/rtorrent (mort depuis 2023).
# Remplace l'ancienne jesec/rtorrent-flood (abandonnée par jesec en juin 2026).
#
# Un seul `docker build` fait tout (clone + build autotools + assemblage avec
# Flood) — pensé pour tourner tel quel en CI, sans étape préalable côté hôte.
#
#   docker build -t rtorrent-flood:<rtorrent-version>-<flood-version> \
#     --build-arg RTORRENT_VERSION=v0.16.23 --build-arg FLOOD_VERSION=4.16.2 .
#
# Basculer de version : bumper RTORRENT_VERSION (même tag pour rtorrent ET
# libtorrent, obligatoire côté rakshasa — cf configure.ac) et/ou FLOOD_VERSION
# (tags précis sur Docker Hub et ghcr.io, cf docs/UPGRADE.md).

ARG RTORRENT_VERSION=v0.16.23
ARG FLOOD_VERSION=4.16.2

FROM alpine:3.24 AS builder
ARG RTORRENT_VERSION

RUN apk --no-cache add \
    build-base linux-headers pkgconf git \
    autoconf automake libtool \
    openssl-dev zlib-dev curl-dev ncurses-dev \
    xmlrpc-c-dev libunistring-dev

WORKDIR /build
RUN git clone --branch "${RTORRENT_VERSION}" --depth 1 https://github.com/rakshasa/libtorrent.git libtorrent \
 && git clone --branch "${RTORRENT_VERSION}" --depth 1 https://github.com/rakshasa/rtorrent.git rtorrent

# libtorrent : statique (LT_INIT([disable-static]) => désactivé par défaut,
# il faut l'activer explicitement), --disable-debug (sinon -DDEBUG par défaut).
RUN cd libtorrent \
 && autoreconf -ivf \
 && ./configure --prefix=/usr/local --disable-debug --enable-static --disable-shared \
 && make -j"$(nproc)" \
 && make install

# rtorrent : PKG_CONFIG=--static propage bien les dépendances transitives de
# libtorrent.a (openssl/zlib/curl/pthread/atomic) — vérifié, pas besoin de
# LIBS= manuel. --with-xmlrpc-c pour parité avec le binaire jesec précédent.
RUN cd rtorrent \
 && autoreconf -ivf \
 && PKG_CONFIG="pkg-config --static" ./configure --prefix=/usr/local --disable-debug --with-xmlrpc-c \
 && make -j"$(nproc)" \
 && strip src/rtorrent \
 && cp src/rtorrent /build/rtorrent-rakshasa \
 && ldd /build/rtorrent-rakshasa | grep -i "not found" && exit 1 || true

# --- Assemblage avec Flood (upstream actif, versions taguées) ---
FROM jesec/flood:${FLOOD_VERSION}

USER root
RUN apk --no-cache add libcurl ncurses-libs xmlrpc-c xmlrpc-c++ libunistring

COPY --from=builder /build/rtorrent-rakshasa /usr/bin/rtorrent
RUN chmod 0755 /usr/bin/rtorrent \
    && ldd /usr/bin/rtorrent | grep -i "not found" && exit 1 || true \
    && /usr/bin/rtorrent -h | head -1

# Flood spawn rtorrent lui-même comme process enfant quand ce flag est actif
# (config.ts, spawn('rtorrent', ['-o', 'system.daemon.set=true']) sur le PATH).
# --rtconfig pointe rtorrent vers notre rtorrent.rc (session, SCGI, DHT, etc.)
ENV FLOOD_OPTION_RTORRENT=true
ENV FLOOD_OPTION_RTCONFIG=/etc/rtorrent/rtorrent.rc

USER download
