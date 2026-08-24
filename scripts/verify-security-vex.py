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
UTIL_LINUX_PURL = (
  "pkg:deb/debian/util-linux@2.38.1-5%2Bdeb12u3?"
  "arch=amd64&distro=debian-12.15"
)
LIBTINFO_PURL = "pkg:deb/debian/libtinfo6@6.4-4?arch=amd64&distro=debian-12.15"
REMOTE_PREFIX = "engine/vendor/github.com/prometheus/prometheus/storage/remote/"

EXPECTED = {
  "CVE-2026-42154": (PROMETHEUS_PURL, "not_affected", "vulnerable_code_not_in_execute_path"),
  "CVE-2026-32286": (PGPROTO_PURL, "fixed", None),
  "CVE-2026-53615": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2026-53613": (UTIL_LINUX_PURL, "not_affected", "vulnerable_code_not_present"),
  "CVE-2025-69720": (LIBTINFO_PURL, "not_affected", "vulnerable_code_not_present"),
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
  if statement.get("products") != [{"@id": product}]:
    fail(f"VEX product differs for {cve}")
  if statement.get("status") != status or statement.get("justification") != justification:
    fail(f"VEX status or justification differs for {cve}")
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
  assembler = (ROOT / "scripts/assemble-runtime-rootfs.sh").read_text(encoding="utf-8")
  if "/usr/bin/setsid" not in assembler:
    fail("the reviewed util-linux setsid executable is absent from the runtime assembler")
  for forbidden_path in (
    "/bin/mount", "/bin/umount", "/usr/bin/blkid", "/usr/bin/findmnt",
    "/usr/bin/infocmp", "/usr/bin/mount", "/usr/bin/mv", "/usr/bin/umount",
    "/etc/fstab",
  ):
    if forbidden_path in assembler:
      fail(f"forbidden executable entered the runtime assembler: {forbidden_path}")
  entrypoint = (ROOT / "entrypoint.sh").read_text(encoding="utf-8")
  if "findmnt" in entrypoint or "/proc/self/mountinfo" not in entrypoint:
    fail("entrypoint mount checks do not match the util-linux VEX evidence")
  dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
  if not re.search(r"(?m)^FROM scratch$", dockerfile):
    fail("final runtime is not the reviewed scratch closure")
  if "r1-atomic-replace" not in dockerfile or "r1-atomic-replace" not in entrypoint:
    fail("the constrained atomic replacement helper is not enforced")


def main() -> None:
  document = json.loads(VEX.read_text(encoding="utf-8"))
  if document.get("@context") != "https://openvex.dev/ns/v0.2.0":
    fail("unexpected OpenVEX context")
  if document.get("@id") != "https://github.com/Ratio1/r1-meshdb/security/vex/3":
    fail("unexpected OpenVEX document identity")
  if document.get("version") != 3 or document.get("timestamp") != "2026-08-24T00:00:00Z":
    fail("unexpected OpenVEX document version or timestamp")
  statements = document.get("statements")
  if not isinstance(statements, list) or len(statements) != len(EXPECTED):
    fail(f"the reviewed VEX allowlist must contain exactly {len(EXPECTED)} statements")
  seen = {validate_statement(statement) for statement in statements}
  if seen != set(EXPECTED):
    fail("VEX decisions are missing or duplicated")

  verify_prometheus()
  verify_pgproto_backport()
  verify_minimal_runtime()
  security_policy = (ROOT / "SECURITY.md").read_text(encoding="utf-8")
  for cve in EXPECTED:
    if cve not in security_policy:
      fail(f"SECURITY.md does not explain {cve}")
  print(f"verified {len(EXPECTED)} exact VEX decisions with source and runtime evidence")


if __name__ == "__main__":
  main()
