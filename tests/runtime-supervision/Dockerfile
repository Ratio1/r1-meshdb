# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BASE_IMAGE=ghcr.io/ratio1/deeploy-cockroachdb-service:main

FROM golang:1.26.5-bookworm@sha256:0d327c83532d3cdeeeebab56ce85962bf09cb89545355b10207c7771b0c3713f AS proxy-builder

WORKDIR /src
COPY tests/local-transport/tcp-proxy.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
  go build -trimpath -buildvcs=false -ldflags='-s -w' -o /out/r1-test-tcp-proxy tcp-proxy.go

FROM ${BASE_IMAGE} AS candidate

FROM candidate AS common

COPY --from=candidate /cockroach/cockroach /cockroach/cockroach-real
COPY --from=candidate /usr/local/bin/r1-atomic-replace /usr/local/bin/r1-atomic-replace-real
COPY --from=proxy-builder /out/r1-test-tcp-proxy /usr/local/bin/r1-test-tcp-proxy
# These utilities are test-harness dependencies, not additions to the
# production scratch image. Their two extra libraries are needed only by GNU
# cp/sed and come from the same pinned Debian builder as the static proxy.
COPY --from=proxy-builder \
  /usr/bin/cp \
  /usr/bin/cut \
  /usr/bin/dd \
  /usr/bin/od \
  /usr/bin/readlink \
  /usr/bin/sed \
  /usr/bin/touch \
  /usr/bin/wc \
  /usr/bin/
COPY --from=proxy-builder \
  /lib/x86_64-linux-gnu/libacl.so.1* \
  /lib/x86_64-linux-gnu/libattr.so.1* \
  /lib/x86_64-linux-gnu/

COPY --chmod=755 tests/runtime-supervision/cockroach-test-wrapper.sh /cockroach/cockroach
COPY --chmod=755 tests/runtime-supervision/cloudflared-test-stub.sh /usr/local/bin/cloudflared
COPY --chmod=755 tests/runtime-supervision/df-test-stub.sh /usr/local/bin/df
COPY --chmod=755 tests/runtime-supervision/find-test-stub.sh /usr/local/bin/find
COPY --chmod=755 tests/runtime-supervision/atomic-replace-test-stub.sh /usr/local/bin/r1-atomic-replace
COPY --chmod=755 tests/runtime-supervision/rm-test-stub.sh /usr/local/bin/rm
COPY --chmod=755 tests/runtime-supervision/sync-test-stub.sh /usr/local/bin/sync
COPY --chmod=755 tests/runtime-supervision/tail-test-stub.sh /usr/local/bin/tail

FROM common AS broken

FROM common AS fixed
COPY --chmod=755 entrypoint.sh /usr/local/bin/deeploy-crdb-entrypoint
