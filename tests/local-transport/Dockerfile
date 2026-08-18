# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

ARG BASE_IMAGE

FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS tcp-proxy-builder

WORKDIR /src
COPY tests/local-transport/tcp-proxy.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
  go build -trimpath -buildvcs=false -ldflags='-s -w' \
    -o /out/r1-test-tcp-proxy ./tcp-proxy.go

FROM ${BASE_IMAGE}

COPY --chmod=755 --from=tcp-proxy-builder /out/r1-test-tcp-proxy /usr/local/bin/r1-test-tcp-proxy
COPY --chmod=755 tests/runtime-supervision/cloudflared-test-stub.sh /usr/local/bin/cloudflared
