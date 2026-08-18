#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail

mapping="${1:?usage: collect-debian-corresponding-source.sh <runtime-package-sources.tsv> <destination>}"
destination="${2:?usage: collect-debian-corresponding-source.sh <runtime-package-sources.tsv> <destination>}"

[[ -f "${mapping}" ]] || {
  echo "Debian runtime source mapping is missing: ${mapping}" >&2
  exit 1
}
mkdir -p "${destination}/packages"
cp "${mapping}" "${destination}/runtime-package-sources.tsv"

tail -n +2 "${mapping}" \
  | cut -f3,4 \
  | LC_ALL=C sort -u \
  | while IFS=$'\t' read -r source_package source_version; do
      [[ -n "${source_package}" && -n "${source_version}" ]] || {
        echo "incomplete Debian source mapping" >&2
        exit 1
      }
      source_dir="${destination}/packages/${source_package}"
      mkdir -p "${source_dir}"
      (
        cd "${source_dir}"
        apt-get -o Acquire::Check-Valid-Until=false source --download-only \
          "${source_package}=${source_version}"
      )
      find "${source_dir}" -maxdepth 1 -type f -name '*.dsc' -print -quit \
        | grep -q . || {
          echo "Debian source package did not provide a .dsc: ${source_package}=${source_version}" >&2
          exit 1
        }
    done

(
  cd "${destination}"
  find packages -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS
)

cat > "${destination}/README" <<'EOF'
This directory accompanies the R1 MeshDB object-code image with the exact
Debian source packages for every Debian binary package retained in the minimal
runtime. runtime-package-sources.tsv maps binary package versions to source
package versions. SHA256SUMS authenticates every downloaded source artifact.
The files were downloaded from the Debian snapshot repositories pinned in the
R1 MeshDB Dockerfile.
EOF

echo "collected $(find "${destination}/packages" -type f | wc -l) Debian corresponding-source files"
