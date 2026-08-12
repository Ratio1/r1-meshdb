ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260701T000000Z bookworm main' \
      > /etc/apt/sources.list \
  && rm -f /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends socat=1.7.4.4-2 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 tests/runtime-supervision/cloudflared-test-stub.sh /usr/local/bin/cloudflared
