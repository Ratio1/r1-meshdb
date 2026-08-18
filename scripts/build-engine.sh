#!/usr/bin/env bash
set -euo pipefail

engine_root="${ENGINE_ROOT:-/workspace/engine}"
build_root="${BUILD_ROOT:-/build}"
output_root="${OUTPUT_ROOT:-/out}"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
meshdb_version_file="${R1_MESHDB_VERSION_FILE:-${repository_root}/VERSION}"
source_date_epoch="${SOURCE_DATE_EPOCH:-1727820937}"
ratio1_version="${RATIO1_VERSION:-v23.1.28-r1.0.0}"
upstream_revision="76e598c9b1c100fd9280b979140b5e377c330a20"
native_root="${build_root}/native"
source_root="${build_root}/native-source"
parallelism="${BUILD_JOBS:-4}"

export LC_ALL=C
export SOURCE_DATE_EPOCH="${source_date_epoch}"
export TZ=UTC

if [[ ! -f "${meshdb_version_file}" ]]; then
  printf 'R1 MeshDB version file does not exist: %s\n' "${meshdb_version_file}" >&2
  exit 1
fi
meshdb_version="$(<"${meshdb_version_file}")"
if [[ ! "${meshdb_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  printf 'R1 MeshDB VERSION must use <major>.<minor>: %s\n' "${meshdb_version}" >&2
  exit 1
fi

case "${ratio1_version}" in
  v23.1.28-r1.*.*) ;;
  *)
    printf 'RATIO1_VERSION must use v23.1.28-r1.<major>.<patch>: %s\n' "${ratio1_version}" >&2
    exit 1
    ;;
esac

case "${parallelism}" in
  ''|*[!0-9]*|0)
    printf 'BUILD_JOBS must be a positive integer: %s\n' "${parallelism}" >&2
    exit 1
    ;;
esac

mkdir -p "${native_root}" "${source_root}" "${output_root}/lib"
printf '%s\n' "${meshdb_version}" > "${output_root}/R1_MESHDB_VERSION"
cp -a "${engine_root}/c-deps/jemalloc" "${source_root}/jemalloc"
cp -a "${engine_root}/c-deps/libedit" "${source_root}/libedit"

(
  cd "${source_root}/jemalloc"
  autoconf
)
mkdir -p "${native_root}/jemalloc"
(
  cd "${native_root}/jemalloc"
  export je_cv_madv_free=no
  "${source_root}/jemalloc/configure" --enable-prof
  make -j"${parallelism}" build_lib_static
)

(
  cd "${source_root}/libedit"
  autoconf
)
mkdir -p "${native_root}/libedit"
(
  cd "${native_root}/libedit"
  "${source_root}/libedit/configure" --disable-examples --disable-shared
  make -j"${parallelism}" -C src
)

mkdir -p "${native_root}/proj"
cmake \
  -S "${engine_root}/c-deps/proj" \
  -B "${native_root}/proj" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_LIBPROJ_SHARED=OFF
cmake --build "${native_root}/proj" --target proj --parallel "${parallelism}"

mkdir -p "${native_root}/geos"
cmake \
  -S "${engine_root}/c-deps/geos" \
  -B "${native_root}/geos" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS=-fPIC \
  -DCMAKE_CXX_FLAGS=-fPIC
cmake --build "${native_root}/geos" --target geos_c --parallel "${parallelism}"
cp -a "${native_root}"/geos/lib/libgeos*.so* "${output_root}/lib/"

build_time="$(date -u -d "@${source_date_epoch}" '+%Y/%m/%d %H:%M:%S')"
link_flags="-buildid=${ratio1_version} \
-X 'github.com/cockroachdb/cockroach/pkg/build.typ=release' \
-X 'github.com/cockroachdb/cockroach/pkg/build.tag=${ratio1_version}' \
-X 'github.com/cockroachdb/cockroach/pkg/build.buildTagOverride=${ratio1_version}' \
-X 'github.com/cockroachdb/cockroach/pkg/build.rev=${upstream_revision}' \
-X 'github.com/cockroachdb/cockroach/pkg/build.cgoTargetTriple=x86_64-linux-gnu' \
-X 'github.com/cockroachdb/cockroach/pkg/build.utcTime=${build_time}' \
-X 'github.com/cockroachdb/cockroach/pkg/util/log/logcrash.crashReportEnv=${ratio1_version}'"

export CGO_ENABLED=1
export CGO_CPPFLAGS="-I${engine_root}/c-deps/libedit/include -I${engine_root}/c-deps/libedit/src -I${native_root}/jemalloc/include"
export CGO_LDFLAGS="-L${native_root}/jemalloc/lib -L${native_root}/proj/lib -L${native_root}/libedit/src/.libs"
export GOPROXY=off
export GOSUMDB=off
export GOFLAGS="-buildvcs=false -p=${parallelism}"

(
  cd "${engine_root}"
  go build \
    -mod=vendor \
    -trimpath \
    -ldflags "${link_flags}" \
    -o "${output_root}/cockroach" \
    ./pkg/cmd/cockroach-oss
)

"${output_root}/cockroach" version | grep -F 'Distribution:     OSS'
"${output_root}/cockroach" version | grep -F "Build Tag:        ${ratio1_version}"
"${output_root}/cockroach" version | grep -F 'Build Type:       release'
