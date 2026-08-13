#!/usr/bin/env python3
"""Verify that every VEX exception is narrow and supported by the source closure."""

from __future__ import annotations

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
REMOTE_PREFIX = "engine/vendor/github.com/prometheus/prometheus/storage/remote/"


def fail(message: str) -> None:
  print(f"security-vex error: {message}", file=sys.stderr)
  raise SystemExit(1)


def main() -> None:
  document = json.loads(VEX.read_text(encoding="utf-8"))
  if document.get("@context") != "https://openvex.dev/ns/v0.2.0":
    fail("unexpected OpenVEX context")
  statements = document.get("statements")
  if not isinstance(statements, list) or len(statements) != 1:
    fail("the reviewed VEX allowlist must contain exactly one statement")
  statement = statements[0]
  vulnerability = statement.get("vulnerability", {})
  if vulnerability.get("@id") != "https://nvd.nist.gov/vuln/detail/CVE-2026-42154":
    fail("unexpected vulnerability exception")
  if statement.get("status") != "not_affected":
    fail("VEX statement is not a not-affected assessment")
  if statement.get("justification") != "vulnerable_code_not_in_execute_path":
    fail("VEX statement has an unsupported justification")
  products = statement.get("products")
  if products != [{"@id": PROMETHEUS_PURL}]:
    fail("VEX product must be the exact vulnerable Prometheus module version")
  if not statement.get("impact_statement"):
    fail("VEX statement has no impact evidence")

  runtime_files = RUNTIME_FILES.read_text(encoding="utf-8").splitlines()
  if any(path.startswith(REMOTE_PREFIX) for path in runtime_files):
    fail("Prometheus remote-read implementation entered the runtime closure")
  remote_tree = ROOT / REMOTE_PREFIX.rstrip("/")
  if remote_tree.exists():
    fail("Prometheus remote-read source must not be distributed")
  module_record = (ROOT / "engine" / "vendor" / "modules.txt").read_text(encoding="utf-8")
  expected_module = "# github.com/prometheus/prometheus v1.8.2-0.20210914090109-37468d88dce8"
  if expected_module not in module_record:
    fail("Prometheus dependency version differs from the reviewed VEX product")
  if not re.search(r"CVE-2026-42154.*storage/remote", (
    (ROOT / "SECURITY.md").read_text(encoding="utf-8")
  ), re.DOTALL):
    fail("SECURITY.md does not explain the VEX assessment")
  print("verified 1 narrow VEX statement and excluded Prometheus remote-read code")


if __name__ == "__main__":
  main()
