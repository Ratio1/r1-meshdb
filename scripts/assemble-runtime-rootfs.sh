#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail

rootfs="${1:?usage: assemble-runtime-rootfs.sh <rootfs> <engine-binary> <expected-packages> <expected-sources>}"
engine_binary="${2:?usage: assemble-runtime-rootfs.sh <rootfs> <engine-binary> <expected-packages> <expected-sources>}"
expected_packages="${3:?usage: assemble-runtime-rootfs.sh <rootfs> <engine-binary> <expected-packages> <expected-sources>}"
expected_sources="${4:?usage: assemble-runtime-rootfs.sh <rootfs> <engine-binary> <expected-packages> <expected-sources>}"
package_list="$(mktemp)"

cleanup() {
  rm -f "${package_list}"
}
trap cleanup EXIT

mkdir -p "${rootfs}"

record_package() {
  local path="$1"
  local candidate package=""
  local -a candidates=("${path}")
  candidates+=("$(readlink -f -- "${path}" 2>/dev/null || true)")
  case "${path}" in
    /usr/bin/*) candidates+=("/bin/${path#/usr/bin/}") ;;
    /bin/*) candidates+=("/usr/bin/${path#/bin/}") ;;
    /usr/sbin/*) candidates+=("/sbin/${path#/usr/sbin/}") ;;
    /sbin/*) candidates+=("/usr/sbin/${path#/sbin/}") ;;
    /usr/lib/*) candidates+=("/lib/${path#/usr/lib/}") ;;
    /lib/*) candidates+=("/usr/lib/${path#/lib/}") ;;
  esac
  for candidate in "${candidates[@]}"; do
    [[ -z "${candidate}" ]] && continue
    package="$(dpkg-query -S -- "${candidate}" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
    [[ -z "${package}" ]] || break
  done
  [[ -z "${package}" ]] || printf '%s\n' "${package%%:*}" >> "${package_list}"
}

copy_path() {
  local path="$1"
  local resolved
  [[ -e "${path}" || -L "${path}" ]] || {
    echo "runtime rootfs input is missing: ${path}" >&2
    return 1
  }
  mkdir -p "${rootfs}/$(dirname "${path#/}")"
  cp -a -- "${path}" "${rootfs}/${path#/}"
  record_package "${path}"
  if [[ -L "${path}" ]]; then
    resolved="$(readlink -- "${path}")"
    if [[ "${resolved}" != /* ]]; then
      resolved="$(dirname "${path}")/${resolved}"
    fi
    resolved="$(realpath -s -m -- "${resolved}")"
    copy_path "${resolved}"
  fi
}

copy_dependencies() {
  local binary="$1"
  local dependency
  while IFS= read -r dependency; do
    [[ -z "${dependency}" ]] || copy_path "${dependency}"
  done < <(
    ldd "${binary}" \
      | awk '/=> \// { print $3 } /^[[:space:]]*\// { print $1 }' \
      | sort -u
  )
}

copy_binary() {
  copy_path "$1"
  copy_dependencies "$1"
}

runtime_binaries=(
  /bin/bash
  /bin/hostname
  /usr/bin/awk
  /usr/bin/cat
  /usr/bin/chmod
  /usr/bin/chown
  /usr/bin/date
  /usr/bin/df
  /usr/bin/env
  /usr/bin/find
  /usr/bin/grep
  /usr/bin/head
  /usr/bin/mkdir
  /usr/bin/mktemp
  /usr/bin/realpath
  /usr/bin/rm
  /usr/bin/seq
  /usr/bin/setsid
  /usr/bin/sha256sum
  /usr/bin/sleep
  /usr/bin/sort
  /usr/bin/stat
  /usr/bin/sync
  /usr/bin/tail
  /usr/bin/test
  /usr/bin/timeout
  /usr/bin/tr
)

for binary in "${runtime_binaries[@]}"; do
  copy_binary "${binary}"
done
copy_dependencies "${engine_binary}"

for path in \
  /etc/group \
  /etc/host.conf \
  /etc/debian_version \
  /etc/nsswitch.conf \
  /etc/os-release \
  /etc/passwd \
  /etc/ssl/certs/ca-certificates.crt; do
  copy_path "${path}"
done
printf '%s\n' base-passwd ca-certificates libc-bin >> "${package_list}"

for nss_library in /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2; do
  [[ ! -e "${nss_library}" ]] || copy_path "${nss_library}"
done

mkdir -p \
  "${rootfs}/cockroach/cockroach-data" \
  "${rootfs}/cockroach/certs" \
  "${rootfs}/tmp" \
  "${rootfs}/usr/local/bin" \
  "${rootfs}/usr/share/doc/r1-meshdb" \
  "${rootfs}/var/lib/dpkg"
chmod 1777 "${rootfs}/tmp"
ln -s bash "${rootfs}/bin/sh"
ln -s deeploy-crdb-entrypoint "${rootfs}/usr/local/bin/r1-meshdb-entrypoint"

sort -u "${package_list}" | while IFS= read -r package; do
  dpkg-query -W -f='${Package}=${Version}\n' "${package}"
done | sort -u > "${rootfs}/usr/share/doc/r1-meshdb/runtime-packages.txt"

if ! diff -u "${expected_packages}" \
    "${rootfs}/usr/share/doc/r1-meshdb/runtime-packages.txt"; then
  echo "minimal runtime package inventory changed" >&2
  exit 1
fi

printf 'binary-package\tbinary-version\tsource-package\tsource-version\n' \
  > "${rootfs}/usr/share/doc/r1-meshdb/runtime-package-sources.tsv"
cut -d= -f1 "${expected_packages}" | while IFS= read -r package; do
  record="$(dpkg-query -W -f='${Package}\t${Version}\t${source:Package}\t${source:Version}' "${package}")"
  IFS=$'\t' read -r binary_package binary_version source_package source_version <<< "${record}"
  source_package="${source_package:-${binary_package}}"
  source_version="${source_version:-${binary_version}}"
  printf '%s\t%s\t%s\t%s\n' \
    "${binary_package}" "${binary_version}" "${source_package}" "${source_version}"
done | LC_ALL=C sort -u >> "${rootfs}/usr/share/doc/r1-meshdb/runtime-package-sources.tsv"

if ! diff -u "${expected_sources}" \
    "${rootfs}/usr/share/doc/r1-meshdb/runtime-package-sources.tsv"; then
  echo "minimal runtime source-package inventory changed" >&2
  exit 1
fi

cut -d= -f1 "${expected_packages}" | while IFS= read -r package; do
  record="$(dpkg-query -W -f='${source:Package}\t${source:Version}' "${package}")"
  IFS=$'\t' read -r source_package source_version <<< "${record}"
  source_package="${source_package:-${package}}"
  source_version="${source_version:-$(dpkg-query -W -f='${Version}' "${package}")}"
  dpkg-query -W -f='Package: ${Package}\nStatus: install ok installed\nArchitecture: ${Architecture}\nVersion: ${Version}\n' \
    "${package}"
  printf 'Source: %s (%s)\nDescription: retained files for the R1 MeshDB minimal runtime\n\n' \
    "${source_package}" "${source_version}"
  copyright="/usr/share/doc/${package}/copyright"
  [[ ! -e "${copyright}" && ! -L "${copyright}" ]] || copy_path "${copyright}"
done > "${rootfs}/var/lib/dpkg/status"

echo "minimal runtime rootfs assembled from $(wc -l < "${expected_packages}") tracked packages"
