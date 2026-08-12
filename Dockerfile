# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM cloudflare/cloudflared:2026.6.1@sha256:6d91c121b803126f7a5344005d17a9324788fc09d305b6e2560ec6040a7ae283 AS cloudflared

FROM golang:1.19.13-bookworm@sha256:da9da58d86d106a5dda2ce249b00cf3b31cdd626ea41597e476de7b4eebad8c4 AS engine-builder

ARG RATIO1_VERSION=v23.1.28-r1.0.0
ARG SOURCE_DATE_EPOCH=1727820937
ARG BUILD_JOBS=4

ENV DEBIAN_FRONTEND=noninteractive \
    GOPROXY=off \
    GOSUMDB=off

RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260701T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260701T000000Z bookworm-security main' \
      > /etc/apt/sources.list \
  && rm -f /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends \
    autoconf=2.71-3 \
    ca-certificates=20230311+deb12u1 \
    cmake=3.25.1-1 \
    g++=4:12.2.0-3 \
    gcc=4:12.2.0-3 \
    libncurses-dev=6.4-4 \
    libtool=2.4.7-7~deb12u1 \
    make=4.3-4.1 \
    pkg-config=1.8.1-1 \
    python3=3.11.2-1+b1 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . .

RUN python3 scripts/verify-source-boundary.py --worktree-only \
  && python3 scripts/verify-runtime-closure.py \
  && python3 scripts/generate-license-inventory.py --check \
  && python3 scripts/verify-provenance.py \
  && python3 scripts/verify-public-test-fixtures.py \
  && python3 scripts/generate-source-manifest.py --check \
  && sha256sum -c source/manifest.sha256 >/tmp/source-manifest.log

RUN --mount=type=cache,target=/root/.cache/go-build \
  ENGINE_ROOT=/workspace/engine \
  BUILD_ROOT=/build \
  OUTPUT_ROOT=/out \
  BUILD_JOBS="${BUILD_JOBS}" \
  RATIO1_VERSION="${RATIO1_VERSION}" \
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
  scripts/build-engine.sh \
  && mkdir -p /out/licenses/cloudflared /out/licenses/engine /out/licenses/source \
  && cp LICENSE NOTICE THIRD_PARTY_NOTICES.md UPSTREAM.md RATIO1_PATCHES.md /out/licenses/ \
  && cp source/provenance.json source/license-inventory.json \
       source/cloudflared-buildinfo.txt source/cloudflared-license-inventory.csv \
       /out/licenses/source/ \
  && cp -a engine/licenses/. /out/licenses/engine/ \
  && cp engine/c-deps/geos/COPYING /out/licenses/engine/GEOS-COPYING \
  && cp engine/c-deps/jemalloc/COPYING /out/licenses/engine/JEMALLOC-COPYING \
  && cp engine/c-deps/libedit/COPYING /out/licenses/engine/LIBEDIT-COPYING \
  && cp engine/c-deps/proj/COPYING /out/licenses/engine/PROJ-COPYING \
  && cp -a licenses/cloudflared/. /out/licenses/cloudflared/

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

ARG BUILD_DATE=""
ARG RATIO1_REVISION="unknown"
ARG RATIO1_VERSION="v23.1.28-r1.0.0"

LABEL org.opencontainers.image.title="R1 Distributed SQL" \
      org.opencontainers.image.description="Distributed SQL database runtime for Ratio1 edge nodes" \
      org.opencontainers.image.url="https://github.com/Ratio1/r1-distributed-sql" \
      org.opencontainers.image.source="https://github.com/Ratio1/r1-distributed-sql" \
      org.opencontainers.image.documentation="https://github.com/Ratio1/r1-distributed-sql/blob/main/README.md" \
      org.opencontainers.image.licenses="Apache-2.0 AND LicenseRef-ThirdParty" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${RATIO1_REVISION}" \
      org.opencontainers.image.version="${RATIO1_VERSION}" \
      org.opencontainers.image.vendor="Ratio1" \
      io.ratio1.r1-distributed-sql.upstream.version="v23.1.28" \
      io.ratio1.r1-distributed-sql.upstream.revision="76e598c9b1c100fd9280b979140b5e377c330a20" \
      io.ratio1.r1-distributed-sql.distribution="OSS"

RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260701T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260701T000000Z bookworm-security main' \
      > /etc/apt/sources.list \
  && rm -f /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends \
    bash=5.2.15-2+b13 \
    ca-certificates=20230311+deb12u1 \
    libncurses6=6.4-4 \
    libstdc++6=12.2.0-14+deb12u1 \
    libtinfo6=6.4-4 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY --chmod=755 --from=engine-builder /out/cockroach /cockroach/cockroach
COPY --from=engine-builder /out/lib/ /usr/local/lib/r1-distributed-sql/
COPY --from=engine-builder /out/licenses/ /usr/share/doc/r1-distributed-sql/
COPY --chmod=755 entrypoint.sh /usr/local/bin/deeploy-crdb-entrypoint

RUN ln -s /usr/local/bin/deeploy-crdb-entrypoint /usr/local/bin/r1-distributed-sql-entrypoint

RUN printf '%s  %s\n' \
      'a1eb422f052be0854b82bf81bf51f343a87c1c64c35e6ccde22ece001799ab16' \
      '/usr/local/bin/cloudflared' \
    | sha256sum -c -

ENV LD_LIBRARY_PATH=/usr/local/lib/r1-distributed-sql

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/deeploy-crdb-entrypoint"]
