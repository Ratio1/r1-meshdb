ARG BASE_IMAGE=ghcr.io/ratio1/deeploy-cockroachdb-service:main
ARG ENTRYPOINT_MODE=fixed

FROM ${BASE_IMAGE}

ARG ENTRYPOINT_MODE

RUN apt-get update \
  && apt-get install -y --no-install-recommends socat \
  && rm -rf /var/lib/apt/lists/* \
  && mv /cockroach/cockroach /cockroach/cockroach-real

COPY --chmod=755 tests/runtime-supervision/cockroach-test-wrapper.sh /cockroach/cockroach
COPY --chmod=755 tests/runtime-supervision/cloudflared-test-stub.sh /usr/local/bin/cloudflared
COPY --chmod=755 tests/runtime-supervision/df-test-stub.sh /usr/local/bin/df
COPY --chmod=755 tests/runtime-supervision/find-test-stub.sh /usr/local/bin/find
COPY --chmod=755 tests/runtime-supervision/mv-test-stub.sh /usr/local/bin/mv
COPY --chmod=755 tests/runtime-supervision/rm-test-stub.sh /usr/local/bin/rm
COPY --chmod=755 tests/runtime-supervision/sync-test-stub.sh /usr/local/bin/sync
COPY --chmod=755 tests/runtime-supervision/tail-test-stub.sh /usr/local/bin/tail
COPY --chmod=755 entrypoint.sh /tmp/candidate-entrypoint

RUN case "${ENTRYPOINT_MODE}" in \
    fixed) cp /tmp/candidate-entrypoint /usr/local/bin/deeploy-crdb-entrypoint ;; \
    broken) ;; \
    *) echo "unknown ENTRYPOINT_MODE: ${ENTRYPOINT_MODE}" >&2; exit 2 ;; \
  esac \
  && rm /tmp/candidate-entrypoint
