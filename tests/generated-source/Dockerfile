# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

FROM golang:1.19.10-bullseye@sha256:08defd390a65f3a72cfde1d04a538c6dc2d48d1f0f443ff99a8862c11c19572c

RUN printf '%s\n' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260701T000000Z bullseye main' \
      'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260701T000000Z bullseye-security main' \
      > /etc/apt/sources.list \
  && rm -f /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends \
    autoconf=2.69-14 \
    bison=2:3.7.5+dfsg-1 \
    cmake=3.18.4-2+deb11u1 \
    libncurses-dev=6.2+20201114-2+deb11u2 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*
