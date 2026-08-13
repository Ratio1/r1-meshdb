# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

ARG BASE_IMAGE

FROM golang:1.26.5-bookworm@sha256:0d327c83532d3cdeeeebab56ce85962bf09cb89545355b10207c7771b0c3713f AS tcp-proxy-builder

WORKDIR /src
COPY tests/local-transport/tcp-proxy.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
  go build -trimpath -buildvcs=false -ldflags='-s -w' \
    -o /out/r1-test-tcp-proxy ./tcp-proxy.go

FROM ${BASE_IMAGE}

COPY --chmod=755 --from=tcp-proxy-builder /out/r1-test-tcp-proxy /usr/local/bin/r1-test-tcp-proxy
COPY --chmod=755 tests/runtime-supervision/cloudflared-test-stub.sh /usr/local/bin/cloudflared
