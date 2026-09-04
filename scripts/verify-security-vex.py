#!/usr/bin/env python3
"""Verify that every VEX decision is exact and backed by distributed evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
VEX = ROOT / "security" / "openvex.json"
RUNTIME_FILES = ROOT / "source" / "runtime-files.txt"
PROMETHEUS_PURL = (
  "pkg:golang/github.com/prometheus/prometheus@"
  "v1.8.2-0.20210914090109-37468d88dce8"
)
PGPROTO_PURL = "pkg:golang/github.com/jackc/pgproto3/v2@v2.3.3"
THRIFT_PURL = "pkg:golang/github.com/apache/thrift@v0.23.0"
UTIL_LINUX_PURL = (
  "pkg:deb/debian/util-linux@2.38.1-5%2Bdeb12u3?"
  "arch=amd64&distro=debian-12.15"
)
LIBTINFO_PURL = "pkg:deb/debian/libtinfo6@6.4-4?arch=amd64&distro=debian-12.15"
X_CRYPTO_PURL = "pkg:golang/golang.org/x/crypto@v0.53.0"
GRPC_ENGINE_PURL = "pkg:golang/google.golang.org/grpc@v1.82.1"
GRPC_CLOUDFLARED_PURL = "pkg:golang/google.golang.org/grpc@v1.83.0"
REMOTE_PREFIX = "engine/vendor/github.com/prometheus/prometheus/storage/remote/"

EXPECTED = {
  "CVE-2026-42154": (PROMETHEUS_PURL, "not_affected", "vulnerable_code_not_in_execute_path"),
  "CVE-2026-32286": (PGPROTO_PURL, "fixed", None),
  "CVE-2026-43871": (THRIFT_PURL, "fixed", None),
  "CVE-2026-84304": ((GRPC_ENGINE_PURL, GRPC_CLOUDFLARED_PURL), "fixed", None),
  "CVE-2026-53615": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-53613": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-76642": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-78408": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-78409": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-78410": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2025-69720": (LIBTINFO_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-56854": (X_CRYPTO_PURL, "not_affected", "vulnerable_code_not_in_execute_path"),
}
REQUIRED_ALIASES = {
  "CVE-2026-43871": {"CVE-2026-43871", "GHSA-8wv5-x4w7-5gww"},
  "CVE-2026-84304": {"CVE-2026-84304", "GHSA-vp52-pcj8-j9qc"},
  "CVE-2026-56854": {"CVE-2026-56854", "GO-2026-6303"},
  "CVE-2026-76642": {"CVE-2026-76642", "GHSA-m25x-3hj9-m26f"},
  "CVE-2026-78408": {"CVE-2026-78408", "GHSA-55fx-f4gg-cfhj"},
  "CVE-2026-78409": {"CVE-2026-78409", "GHSA-8f2p-47x3-43mv"},
  "CVE-2026-78410": {"CVE-2026-78410", "GHSA-rh77-686x-2f2m"},
}


def fail(message: str) -> None:
  print(f"security-vex error: {message}", file=sys.stderr)
  raise SystemExit(1)


def sha256(path: Path) -> str:
  return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_statement(statement: dict) -> str:
  vulnerability_id = statement.get("vulnerability", {}).get("@id", "")
  cve = vulnerability_id.rsplit("/", 1)[-1]
  if cve not in EXPECTED or vulnerability_id != f"https://nvd.nist.gov/vuln/detail/{cve}":
    fail(f"unexpected vulnerability decision: {vulnerability_id}")
  product, status, justification = EXPECTED[cve]
  products = product if isinstance(product, tuple) else (product,)
  if statement.get("products") != [{"@id": item} for item in products]:
    fail(f"VEX product differs for {cve}")
  if statement.get("status") != status or statement.get("justification") != justification:
    fail(f"VEX status or justification differs for {cve}")
  if cve in REQUIRED_ALIASES:
    aliases = statement.get("vulnerability", {}).get("aliases")
    if not isinstance(aliases, list) or set(aliases) != REQUIRED_ALIASES[cve]:
      fail(f"VEX aliases differ for {cve}")
  evidence_key = "status_notes" if status == "fixed" else "impact_statement"
  if not statement.get(evidence_key):
    fail(f"VEX decision has no evidence for {cve}")
  return cve


def verify_prometheus() -> None:
  runtime_files = RUNTIME_FILES.read_text(encoding="utf-8").splitlines()
  if any(path.startswith(REMOTE_PREFIX) for path in runtime_files):
    fail("Prometheus remote-read implementation entered the runtime closure")
  if (ROOT / REMOTE_PREFIX.rstrip("/")).exists():
    fail("Prometheus remote-read source must not be distributed")
  module_record = (ROOT / "engine/vendor/modules.txt").read_text(encoding="utf-8")
  expected = "# github.com/prometheus/prometheus v1.8.2-0.20210914090109-37468d88dce8"
  if expected not in module_record:
    fail("Prometheus dependency version differs from the VEX product")


def verify_pgproto_backport() -> None:
  overrides = json.loads((ROOT / "source/ratio1-engine-overrides.json").read_text(encoding="utf-8"))
  records = [item for item in overrides["securityBackports"] if item["advisory"] == "GO-2026-4518"]
  if len(records) != 1 or records[0].get("module") != "github.com/jackc/pgproto3/v2@v2.3.3":
    fail("pgproto3 backport metadata differs from the VEX product")
  for file_record in records[0].get("files", []):
    path = ROOT / file_record["path"]
    if not path.is_file() or sha256(path) != file_record.get("sha256"):
      fail(f"pgproto3 backport hash differs: {file_record.get('path')}")
  implementation = (ROOT / "engine/vendor/github.com/jackc/pgproto3/v2/data_row.go").read_text()
  if "msgSize < 0 || len(src[rp:]) < msgSize" not in implementation:
    fail("pgproto3 negative field-length backport is absent")
  tests = (ROOT / "engine/vendor/github.com/jackc/pgproto3/v2/data_row_r1_test.go").read_text()
  for evidence in ("negative two", "minimum int32", "RetainsNullField", "FrontendReceive"):
    if evidence not in tests:
      fail(f"pgproto3 regression evidence is absent: {evidence}")


def verify_thrift_backport() -> None:
  overrides = json.loads((ROOT / "source/ratio1-engine-overrides.json").read_text(encoding="utf-8"))
  records = [
    item for item in overrides["securityBackports"]
    if item["advisory"] == "CVE-2026-43871"
  ]
  if len(records) != 1 or records[0].get("module") != "github.com/apache/thrift@v0.23.0":
    fail("Apache Thrift backport metadata differs from the VEX product")
  if len(records[0].get("files", [])) != 2:
    fail("Apache Thrift backport file set is incomplete")
  for file_record in records[0]["files"]:
    path = ROOT / file_record["path"]
    if not path.is_file() or sha256(path) != file_record.get("sha256"):
      fail(f"Apache Thrift backport hash differs: {file_record.get('path')}")

  modules = (ROOT / "engine/vendor/modules.txt").read_text(encoding="utf-8")
  if "# github.com/apache/thrift v0.23.0\n" not in modules:
    fail("Apache Thrift version differs from the VEX product")
  implementation = (
    ROOT / "engine/vendor/github.com/apache/thrift/lib/go/thrift/compact_protocol.go"
  ).read_text(encoding="utf-8")
  for marker in (
    "const maxVarint64Bytes = 10",
    "for rsize := 0; rsize < maxVarint64Bytes; rsize++",
    'errors.New("variable-length int over 10 bytes")',
  ):
    if marker not in implementation:
      fail(f"Apache Thrift varint backport evidence is absent: {marker}")
  tests = (
    ROOT / "engine/vendor/github.com/apache/thrift/lib/go/thrift/compact_protocol_r1_test.go"
  ).read_text(encoding="utf-8")
  for marker in (
    "TestRatio1CompactProtocolRejectsOverlongVarint",
    "TestRatio1CompactProtocolAcceptsValidTenByteVarint",
    "transport.Len(), 1",
  ):
    if marker not in tests:
      fail(f"Apache Thrift backport regression evidence is absent: {marker}")


def verify_grpc_backport() -> None:
  overrides = json.loads((ROOT / "source/ratio1-engine-overrides.json").read_text(encoding="utf-8"))
  records = [
    item for item in overrides["securityBackports"]
    if item["advisory"] == "CVE-2026-84304"
  ]
  if len(records) != 1 or records[0].get("module") != "google.golang.org/grpc@v1.82.1":
    fail("engine gRPC backport metadata differs from the VEX product")
  if len(records[0].get("files", [])) != 9:
    fail("engine gRPC backport file set is incomplete")
  for file_record in records[0]["files"]:
    path = ROOT / file_record["path"]
    if not path.is_file() or sha256(path) != file_record.get("sha256"):
      fail(f"engine gRPC backport hash differs: {file_record.get('path')}")

  modules = (ROOT / "engine/vendor/modules.txt").read_text(encoding="utf-8")
  if "# google.golang.org/grpc v1.82.1\n" not in modules:
    fail("engine gRPC version differs from the VEX product")
  implementation = (
    ROOT / "engine/vendor/google.golang.org/grpc/internal/transport/transport.go"
  ).read_text(encoding="utf-8")
  for marker in (
    "compactionThreshold",
    "EnableReceiveBufferCompaction",
    "uncompactedSuffixLen",
    "mem.NewBuffer(newBuf",
  ):
    if marker not in implementation:
      fail(f"engine gRPC receive-buffer backport evidence is absent: {marker}")
  tests = (
    ROOT
    / "engine/vendor/google.golang.org/grpc/internal/transport/recv_buffer_compaction_r1_test.go"
  ).read_text(encoding="utf-8")
  for marker in ("TestRatio1RecvBufferCompactsFragmentedBacklog", "BufferPoolingThreshold"):
    if marker not in tests:
      fail(f"engine gRPC backport regression evidence is absent: {marker}")

  provenance = json.loads((ROOT / "source/provenance.json").read_text(encoding="utf-8"))
  cloudflared = provenance["buildInputs"]["cloudflared"]
  cloud_records = cloudflared.get("securityBackports", [])
  if len(cloud_records) != 1 or cloud_records[0].get("module") != "google.golang.org/grpc@v1.83.0":
    fail("Cloudflared gRPC backport metadata differs from the VEX product")
  patch = ROOT / cloud_records[0].get("patch", "")
  if not patch.is_file() or sha256(patch) != cloud_records[0].get("patchSha256"):
    fail("Cloudflared gRPC backport patch hash differs")
  cloudflared_build = (ROOT / "source/cloudflared-buildinfo.txt").read_text(encoding="utf-8")
  if "\tdep\tgoogle.golang.org/grpc\tv1.83.0\t\n" not in cloudflared_build:
    fail("Cloudflared gRPC version differs from the VEX product")
  dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
  for marker in (cloud_records[0]["patch"], cloud_records[0]["patchSha256"], "git -C /cloudflared apply"):
    if marker not in dockerfile:
      fail(f"Cloudflared gRPC backport is not enforced by the image build: {marker}")
  cloud_verifier = (ROOT / "scripts/verify-cloudflared-source.py").read_text(encoding="utf-8")
  if "verify_grpc_security_backport" not in cloud_verifier:
    fail("Cloudflared source verifier does not enforce the gRPC backport")


def verify_minimal_runtime() -> None:
  runtime_packages = (ROOT / "source/runtime-packages.txt").read_text(encoding="utf-8").splitlines()
  package_names = {line.split("=", 1)[0] for line in runtime_packages}
  required = {"util-linux", "libtinfo6"}
  forbidden = {
    "bsdutils", "gzip", "libacl1", "libattr1", "libblkid1", "libmount1", "mount", "ncurses-base",
    "ncurses-bin", "perl-base", "util-linux-extra", "zlib1g",
  }
  if not required <= package_names or forbidden & package_names:
    fail("minimal runtime package inventory does not match the VEX evidence")
  if "util-linux=2.38.1-5+deb12u3" not in runtime_packages:
    fail("util-linux version differs from the VEX product")
  assembler = (ROOT / "scripts/assemble-runtime-rootfs.sh").read_text(encoding="utf-8")
  if "/usr/bin/setsid" not in assembler:
    fail("the reviewed util-linux setsid executable is absent from the runtime assembler")
  for forbidden_path in (
    "/bin/mount", "/bin/umount", "/usr/bin/blkid", "/usr/bin/findmnt",
    "/usr/bin/infocmp", "/usr/bin/mount", "/usr/bin/mv", "/usr/bin/umount",
    "/usr/bin/nsenter", "/etc/fstab",
  ):
    if forbidden_path in assembler:
      fail(f"forbidden executable entered the runtime assembler: {forbidden_path}")
  if "libmount" in assembler:
    fail("libmount entered the runtime assembler")
  entrypoint = (ROOT / "entrypoint.sh").read_text(encoding="utf-8")
  if "findmnt" in entrypoint or "/proc/self/mountinfo" not in entrypoint:
    fail("entrypoint mount checks do not match the util-linux VEX evidence")
  dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
  if not re.search(r"(?m)^FROM scratch$", dockerfile):
    fail("final runtime is not the reviewed scratch closure")
  if "r1-atomic-replace" not in dockerfile or "r1-atomic-replace" not in entrypoint:
    fail("the constrained atomic replacement helper is not enforced")


def verify_ssh_server_authentication_absence() -> None:
  ssh_package = "golang.org/x/crypto/ssh"
  engine_ssh_source = ROOT / "engine" / "vendor" / "golang.org" / "x" / "crypto" / "ssh"
  if engine_ssh_source.exists():
    fail("the engine unexpectedly distributes the x/crypto/ssh source package")

  engine_go_mod = (ROOT / "engine" / "go.mod").read_text(encoding="utf-8")
  if "\tgolang.org/x/crypto v0.53.0\n" not in engine_go_mod:
    fail("the engine go.mod x/crypto version differs from the VEX product")
  engine_modules = (ROOT / "engine" / "vendor" / "modules.txt").read_text(encoding="utf-8")
  if "# golang.org/x/crypto v0.53.0\n" not in engine_modules:
    fail("the engine x/crypto version differs from the VEX product")
  if re.search(r"(?m)^golang\.org/x/crypto/ssh(?:/|$)", engine_modules):
    fail("the engine vendor manifest unexpectedly includes x/crypto/ssh")

  runtime_files = RUNTIME_FILES.read_text(encoding="utf-8").splitlines()
  if any(path.startswith("vendor/golang.org/x/crypto/ssh/") for path in runtime_files):
    fail("the engine runtime closure unexpectedly includes x/crypto/ssh")

  cloudflared_build = (ROOT / "source" / "cloudflared-buildinfo.txt").read_text(encoding="utf-8")
  if "\tdep\tgolang.org/x/crypto\tv0.53.0\t\n" not in cloudflared_build:
    fail("the Cloudflared x/crypto version differs from the VEX product")
  cloudflared_packages = set(
    (ROOT / "source" / "cloudflared-compiled-packages.txt").read_text(encoding="utf-8").splitlines()
  )
  required_packages = {ssh_package, "github.com/cloudflare/cloudflared/sshgen"}
  if not required_packages <= cloudflared_packages:
    fail("Cloudflared SSH package evidence is incomplete")

  cloudflared_verifier = (ROOT / "scripts" / "verify-cloudflared-source.py").read_text(encoding="utf-8")
  ssh_verifier = ROOT / "scripts" / "verify_cloudflared_ssh_usage.go"
  ssh_tests = ROOT / "scripts" / "verify_cloudflared_ssh_usage_test.go"
  if not ssh_verifier.is_file() or not ssh_tests.is_file():
    fail("Cloudflared SSH AST verifier or negative tests are missing")
  for marker in (
    "verify_ssh_server_authentication_absence",
    "verify_cloudflared_ssh_usage.go",
    "verify_cloudflared_ssh_usage_test.go",
  ):
    if marker not in cloudflared_verifier:
      fail(f"Cloudflared source verifier does not enforce SSH evidence: {marker}")
  dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
  if "python3 scripts/verify-cloudflared-source.py" not in dockerfile:
    fail("the image build does not verify exact Cloudflared source")


def main() -> None:
  document = json.loads(VEX.read_text(encoding="utf-8"))
  if document.get("@context") != "https://openvex.dev/ns/v0.2.0":
    fail("unexpected OpenVEX context")
  if document.get("@id") != "https://github.com/Ratio1/r1-meshdb/security/vex/7":
    fail("unexpected OpenVEX document identity")
  if document.get("version") != 7 or document.get("timestamp") != "2026-09-04T00:00:00Z":
    fail("unexpected OpenVEX document version or timestamp")
  statements = document.get("statements")
  if not isinstance(statements, list) or len(statements) != len(EXPECTED):
    fail(f"the reviewed VEX allowlist must contain exactly {len(EXPECTED)} statements")
  seen = {validate_statement(statement) for statement in statements}
  if seen != set(EXPECTED):
    fail("VEX decisions are missing or duplicated")

  verify_prometheus()
  verify_pgproto_backport()
  verify_thrift_backport()
  verify_grpc_backport()
  verify_minimal_runtime()
  verify_ssh_server_authentication_absence()
  security_policy = (ROOT / "SECURITY.md").read_text(encoding="utf-8")
  for cve in EXPECTED:
    if cve not in security_policy:
      fail(f"SECURITY.md does not explain {cve}")
  print(f"verified {len(EXPECTED)} exact VEX decisions with source and runtime evidence")


if __name__ == "__main__":
  main()
