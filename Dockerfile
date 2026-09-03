# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS cloudflared-builder

ARG CLOUDFLARED_COMMIT=b4f47e2ab538ab6e31d3dc6adc5489455ad446de
ARG CLOUDFLARED_VERSION=2026.7.3-r1.b4f47e2

ENV GOPROXY=off \
    GOSUMDB=off

ADD --checksum=sha256:e897f2cdb6f63964bb7b5841df80087489a65ab9fda356ef48dd13202bba59c0 \
  https://github.com/cloudflare/cloudflared/archive/b4f47e2ab538ab6e31d3dc6adc5489455ad446de.tar.gz \
  /tmp/cloudflared.tar.gz

COPY security/backports/grpc-go-cve-2026-84304-v1.83.0.patch /tmp/grpc-go-cve-2026-84304.patch

RUN printf '%s  %s\n' \
      'c98442d4f6badbb1b0adcfa79dc28478eb105d1cdbad4ca232c85f4a3c653043' \
      '/tmp/grpc-go-cve-2026-84304.patch' \
    | sha256sum -c - \
  && mkdir /cloudflared \
  && tar -xzf /tmp/cloudflared.tar.gz --strip-components=1 -C /cloudflared \
  && git -C /cloudflared apply --directory=vendor/google.golang.org/grpc --unidiff-zero \
       --check /tmp/grpc-go-cve-2026-84304.patch \
  && git -C /cloudflared apply --directory=vendor/google.golang.org/grpc --unidiff-zero \
       /tmp/grpc-go-cve-2026-84304.patch \
  && rm /tmp/cloudflared.tar.gz /tmp/grpc-go-cve-2026-84304.patch

WORKDIR /cloudflared

RUN --mount=type=cache,target=/root/.cache/go-build \
  go test -mod=vendor ./cmd/cloudflared/... ./carrier/... ./tunnelrpc/...

RUN --mount=type=cache,target=/root/.cache/go-build \
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
  go build -mod=vendor -trimpath -buildvcs=false \
    -ldflags="-s -w -X main.Version=${CLOUDFLARED_VERSION} -X main.BuildTime=2026-08-12-16:57_UTC -X github.com/cloudflare/cloudflared/metrics.Runtime=virtual" \
    -o /out/cloudflared ./cmd/cloudflared \
  && printf '%s  %s\n' \
      'd6e54c10c671c061bcb04404c9e2fd7dedb4f5f8a4d9b9ec1b35b6fa1973b62d' \
      '/out/cloudflared' \
    | sha256sum -c -

COPY scripts/runtime-tools/atomic-replace.go /tmp/atomic-replace.go

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
  go build -trimpath -buildvcs=false -ldflags='-s -w' \
    -o /out/r1-atomic-replace /tmp/atomic-replace.go

FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS engine-builder

ARG RATIO1_VERSION=v1.0.1
ARG SOURCE_DATE_EPOCH=1727820937
ARG BUILD_JOBS=4

ENV DEBIAN_FRONTEND=noninteractive \
    GOPROXY=off \
    GOSUMDB=off

RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260812T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260812T000000Z bookworm-security main' \
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
  && python3 scripts/generate-vendor-license-manifest.py --check \
  && python3 scripts/verify-provenance.py \
  && python3 scripts/verify-public-test-fixtures.py \
  && python3 scripts/verify-security-vex.py \
  && python3 scripts/generate-source-manifest.py --check \
  && sha256sum -c source/manifest.sha256 >/tmp/source-manifest.log

RUN --mount=from=cloudflared-builder,source=/cloudflared,target=/cloudflared,ro \
    --mount=from=cloudflared-builder,source=/out/cloudflared,target=/cloudflared-bin,ro \
  python3 scripts/verify-cloudflared-source.py \
    --source-root /cloudflared \
    --binary /cloudflared-bin

RUN --mount=type=cache,target=/root/.cache/go-build \
  cd /workspace/engine \
  && go test -mod=vendor \
    github.com/jackc/pgproto3/v2 \
    github.com/jackc/pgx/v4/internal/sanitize \
    google.golang.org/grpc/internal/transport \
    ./pkg/util/ctxutil \
    ./pkg/util/goschedstats \
  && go test -vet=off -mod=vendor \
    ./pkg/storage -run '^TestPanicOnLocalPebbleCorruption$' -count=1 \
  && cd /workspace \
  && ENGINE_ROOT=/workspace/engine \
  BUILD_ROOT=/build \
  OUTPUT_ROOT=/out \
  BUILD_JOBS="${BUILD_JOBS}" \
  RATIO1_VERSION="${RATIO1_VERSION}" \
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
  scripts/build-engine.sh \
  && mkdir -p /out/licenses/cloudflared /out/licenses/engine /out/licenses/security /out/licenses/source \
  && cp LICENSE LICENSE-OVERVIEW.md NOTICE THIRD_PARTY_NOTICES.md UPSTREAM.md RATIO1_PATCHES.md SECURITY.md /out/licenses/ \
  && cp security/openvex.json /out/licenses/security/ \
  && cp source/provenance.json source/license-inventory.json \
       source/cloudflared-buildinfo.txt source/cloudflared-license-inventory.csv \
       source/vendor-license-manifest.json \
       /out/licenses/source/ \
  && cp -a engine/licenses/. /out/licenses/engine/ \
  && cp engine/AUTHORS /out/licenses/engine/AUTHORS \
  && cp engine/c-deps/geos/COPYING /out/licenses/engine/GEOS-COPYING \
  && cp engine/c-deps/jemalloc/COPYING /out/licenses/engine/JEMALLOC-COPYING \
  && cp engine/c-deps/libedit/COPYING /out/licenses/engine/LIBEDIT-COPYING \
  && cp engine/c-deps/proj/COPYING /out/licenses/engine/PROJ-COPYING \
  && python3 scripts/generate-vendor-license-manifest.py --check \
       --copy-to /out/licenses/engine/vendor \
  && cp -a licenses/cloudflared/. /out/licenses/cloudflared/

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS runtime-rootfs-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260812T000000Z bookworm main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260812T000000Z bookworm-security main' \
      'deb-src [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260812T000000Z bookworm main' \
      'deb-src [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260812T000000Z bookworm-security main' \
      > /etc/apt/sources.list \
  && rm -f /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends \
    bash=5.2.15-2+b13 \
    ca-certificates=20230311+deb12u1 \
    libtinfo6=6.4-4

COPY --chmod=755 scripts/assemble-runtime-rootfs.sh /usr/local/bin/assemble-runtime-rootfs
COPY --chmod=755 scripts/collect-debian-corresponding-source.sh /usr/local/bin/collect-debian-corresponding-source
COPY source/runtime-packages.txt /usr/share/r1-meshdb/runtime-packages.txt
COPY source/runtime-package-sources.tsv /usr/share/r1-meshdb/runtime-package-sources.tsv

RUN --mount=from=engine-builder,source=/out/cockroach,target=/candidate-cockroach,ro \
  assemble-runtime-rootfs \
    /minimal-rootfs \
    /candidate-cockroach \
    /usr/share/r1-meshdb/runtime-packages.txt \
    /usr/share/r1-meshdb/runtime-package-sources.tsv \
  && collect-debian-corresponding-source \
    /minimal-rootfs/usr/share/doc/r1-meshdb/runtime-package-sources.tsv \
    /minimal-rootfs/usr/share/src/r1-meshdb/debian \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

FROM scratch

ARG BUILD_DATE=""
ARG RATIO1_REVISION="unknown"
ARG RATIO1_VERSION="v1.0.1"

LABEL org.opencontainers.image.title="R1 MeshDB" \
      org.opencontainers.image.description="Distributed SQL database runtime for Ratio1 edge nodes" \
      org.opencontainers.image.url="https://github.com/Ratio1/r1-meshdb" \
      org.opencontainers.image.source="https://github.com/Ratio1/r1-meshdb" \
      org.opencontainers.image.documentation="https://github.com/Ratio1/r1-meshdb/blob/main/README.md" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${RATIO1_REVISION}" \
      org.opencontainers.image.version="${RATIO1_VERSION}" \
      org.opencontainers.image.vendor="Ratio1" \
      io.ratio1.r1-meshdb.upstream.version="v23.1.28" \
      io.ratio1.r1-meshdb.upstream.revision="76e598c9b1c100fd9280b979140b5e377c330a20" \
      io.ratio1.r1-meshdb.distribution="OSS"

COPY --from=runtime-rootfs-builder /minimal-rootfs/ /
COPY --chmod=755 --from=cloudflared-builder /out/cloudflared /usr/local/bin/cloudflared
COPY --chmod=755 --from=cloudflared-builder /out/r1-atomic-replace /usr/local/bin/r1-atomic-replace
COPY --chmod=755 --from=engine-builder /out/cockroach /cockroach/cockroach
COPY --from=engine-builder /out/R1_MESHDB_VERSION /usr/share/r1-meshdb/VERSION
COPY --from=engine-builder /out/lib/ /usr/local/lib/r1-meshdb/
COPY --from=engine-builder /out/licenses/ /usr/share/doc/r1-meshdb/
COPY --chmod=755 entrypoint.sh /usr/local/bin/deeploy-crdb-entrypoint

ENV LD_LIBRARY_PATH=/usr/local/lib/r1-meshdb

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/deeploy-crdb-entrypoint"]
