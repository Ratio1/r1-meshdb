#!/usr/bin/env python3
"""Verify hashes and metadata claimed by source/provenance.json."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "source" / "provenance.json"
OVERRIDES = ROOT / "source" / "ratio1-engine-overrides.json"
EXPECTED_MODIFIED_FILES = {
  "engine/pkg/build/info.go",
  "engine/pkg/cli/cli.go",
  "engine/pkg/cli/clierrorplus/decorate_error.go",
  "engine/pkg/cli/cliflags/flags.go",
  "engine/pkg/cli/clisqlcfg/context.go",
  "engine/pkg/cli/clisqlclient/conn.go",
  "engine/pkg/cli/clisqlshell/sql.go",
  "engine/pkg/cli/demo.go",
  "engine/pkg/cli/debug_recover_loss_of_quorum.go",
  "engine/pkg/cli/examples.go",
  "engine/pkg/cli/flags.go",
  "engine/pkg/cli/gen.go",
  "engine/pkg/cli/import.go",
  "engine/pkg/cli/init.go",
  "engine/pkg/cli/sql_shell_cmd.go",
  "engine/pkg/cli/start.go",
  "engine/pkg/docs/docs.go",
  "engine/pkg/kv/kvserver/replica_consistency.go",
  "engine/pkg/kv/kvserver/replica_corruption.go",
  "engine/pkg/kv/kvclient/kvcoord/txn_coord_sender.go",
  "engine/pkg/server/api_v2_error.go",
  "engine/pkg/server/diagnostics/diagnostics.go",
  "engine/pkg/server/server.go",
  "engine/pkg/settings/cluster/cluster_settings.go",
  "engine/pkg/sql/crdb_internal.go",
  "engine/pkg/sql/vars.go",
  "engine/pkg/storage/pebble_iterator.go",
  "engine/pkg/ui/ui.go",
  "engine/pkg/util/ctxutil/context.go",
  "engine/pkg/util/log/clog.go",
  "engine/pkg/util/log/logcrash/crash_reporting.go",
  "engine/pkg/util/tracing/tracer.go",
}
EXPECTED_REMOVED_FILES = {"engine/pkg/util/ctxutil/context_abi_pre1_20.go"}
EXPECTED_ADDED_FILES = {
  "engine/pkg/storage/pebble_iterator_r1_test.go",
  "engine/pkg/util/ctxutil/context_go1.20_test.go",
  "engine/pkg/util/goschedstats/runtime_go1.26.go",
  "engine/pkg/util/goschedstats/runtime_go1.26_test.go",
}
EXPECTED_SECURITY_BACKPORTS = {"GO-2026-4518", "GO-2026-5004"}
EXPECTED_COMPATIBILITY_BACKPORTS = {"google-api-grpc-credentials-options"}
MIN_RETAINED_UPSTREAM_PACKAGE_FILES = 3000
MODIFICATION_NOTICE = b"Modified by Ratio1 in 2026; see RATIO1_PATCHES.md."
RATIO1_APACHE_MARKERS = (
  b"Copyright 2026 Ratio1",
  b'Licensed under the Apache License, Version 2.0 (the "License")',
)


def fail(message: str) -> None:
  print(f"provenance error: {message}", file=sys.stderr)
  raise SystemExit(1)


def file_sha256(path: Path) -> str:
  digest = hashlib.sha256()
  with path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
      digest.update(chunk)
  return digest.hexdigest()


def check_source_notice(path: Path, change_type: str) -> None:
  content = path.read_bytes()
  if change_type == "modified-upstream":
    if MODIFICATION_NOTICE not in content:
      fail(f"modified upstream file has no prominent Ratio1 notice: {path.relative_to(ROOT)}")
    return
  if change_type == "ratio1-added":
    if any(marker not in content for marker in RATIO1_APACHE_MARKERS):
      fail(f"Ratio1-added file has no Apache-2.0 source header: {path.relative_to(ROOT)}")
    return
  fail(f"invalid source change type for {path.relative_to(ROOT)}: {change_type}")


def without_go_comments(content: bytes) -> bytes:
  output = bytearray()
  index = 0
  state = "code"
  while index < len(content):
    current = content[index]
    following = content[index + 1] if index + 1 < len(content) else None
    if state == "code":
      if current == ord("/") and following == ord("/"):
        state = "line-comment"
        index += 2
        continue
      if current == ord("/") and following == ord("*"):
        state = "block-comment"
        index += 2
        continue
      output.append(current)
      if current == ord('"'):
        state = "string"
      elif current == ord("'"):
        state = "rune"
      elif current == ord("`"):
        state = "raw-string"
      index += 1
      continue
    if state == "line-comment":
      if current in (ord("\n"), ord("\r")):
        output.append(current)
        state = "code"
      index += 1
      continue
    if state == "block-comment":
      if current in (ord("\n"), ord("\r")):
        output.append(current)
      if current == ord("*") and following == ord("/"):
        state = "code"
        index += 2
      else:
        index += 1
      continue
    output.append(current)
    if state in ("string", "rune") and current == ord("\\"):
      if following is not None:
        output.append(following)
        index += 2
      else:
        index += 1
      continue
    if (state == "string" and current == ord('"')) or (
      state == "rune" and current == ord("'")
    ) or (state == "raw-string" and current == ord("`")):
      state = "code"
    index += 1
  if state in ("string", "rune", "raw-string", "block-comment"):
    fail(f"unterminated Go lexical state while validating overrides: {state}")
  return bytes(output)


def comments_only_projection(content: bytes) -> bytes:
  """Remove comments and blank lines that only carried comments."""
  uncommented = without_go_comments(content)
  return b"\n".join(line for line in uncommented.splitlines() if line.strip())


def tree_sha256(root: Path) -> str:
  digest = hashlib.sha256()
  paths = sorted(
    (path for path in root.rglob("*") if ".git" not in path.relative_to(root).parts),
    key=lambda path: path.relative_to(root).as_posix(),
  )
  for path in paths:
    relative = path.relative_to(root).as_posix().encode("utf-8")
    if path.is_symlink():
      target = os.readlink(path).encode("utf-8")
      try:
        path.resolve(strict=True).relative_to(root.resolve())
      except (OSError, ValueError):
        fail(f"native dependency symlink escapes its tree: {path.relative_to(ROOT)}")
      digest.update(b"L\0" + relative + b"\0" + target + b"\0")
    elif path.is_file():
      digest.update(b"F\0" + relative + b"\0" + bytes.fromhex(file_sha256(path)) + b"\0")
  return digest.hexdigest()


def check_build_input(build_inputs: dict, dockerfile: str, build_info: str) -> None:
  go_builder = build_inputs.get("goBuilder", "")
  runtime_image = build_inputs.get("runtime", "")
  if not re.fullmatch(r"golang:[^@]+@sha256:[0-9a-f]{64}", go_builder):
    fail("Go builder is not tag-and-digest pinned")
  if not re.fullmatch(r"debian:[^@]+@sha256:[0-9a-f]{64}", runtime_image):
    fail("runtime image is not tag-and-digest pinned")
  if go_builder not in dockerfile:
    fail("Dockerfile Go builder differs from provenance")
  if runtime_image not in dockerfile:
    fail("Dockerfile runtime image differs from provenance")

  cloudflared = build_inputs.get("cloudflared", {})
  source_archive = cloudflared.get("sourceArchiveUrl", "")
  source_hash = cloudflared.get("sourceArchiveSha256", "")
  binary_hash = cloudflared.get("binarySha256", "")
  commit = cloudflared.get("commit", "")
  if source_archive != f"https://github.com/cloudflare/cloudflared/archive/{commit}.tar.gz":
    fail("Cloudflared source archive does not use the exact provenance commit")
  if not re.fullmatch(r"[0-9a-f]{64}", source_hash):
    fail("Cloudflared source archive SHA-256 is invalid")
  if not re.fullmatch(r"[0-9a-f]{64}", binary_hash):
    fail("Cloudflared binary SHA-256 is invalid")
  for value, label in (
    (source_archive, "source archive"),
    (source_hash, "source archive hash"),
    (binary_hash, "binary hash"),
    (commit, "commit"),
  ):
    if value not in dockerfile:
      fail(f"Dockerfile does not enforce the Cloudflared {label}")
  if re.search(r"FROM\s+cloudflare/cloudflared", dockerfile, re.IGNORECASE):
    fail("Dockerfile must build Cloudflared from pinned source")
  if "/cloudflared: go1.26.6" not in build_info:
    fail("Cloudflared was not built with the pinned Go toolchain")
  if "\tdep\tgoogle.golang.org/grpc\tv1.83.0\t" not in build_info:
    fail("Cloudflared does not embed the reviewed gRPC version")

  release_tooling = build_inputs.get("releaseTooling")
  expected_release_tooling = {
    "buildx": "v0.36.1",
    "buildkit": (
      "moby/buildkit:v0.32.2@sha256:"
      "28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8"
    ),
    "cosign": "v3.1.3",
    "gh": "v2.97.0",
    "syft": "v1.51.0",
    "trivy": "v0.73.0",
  }
  if release_tooling != expected_release_tooling:
    fail("release tooling versions differ from the reviewed set")
  workflow_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml"))
  )
  for name, version in release_tooling.items():
    if version not in workflow_text:
      fail(f"workflow does not pin reviewed release tool: {name}")

  schema_validation = build_inputs.get("schemaValidation", {})
  expected_schema_validation = {
    "pythonImage": (
      "python:3.13.7-slim@sha256:"
      "5f55cdf0c5d9dc1a415637a5ccc4a9e18663ad203673173b8cda8f8dcacef689"
    ),
    "jsonschema": "4.25.1",
    "requirementsSha256": file_sha256(ROOT / "source/sbom-validation-requirements.txt"),
    "spdxSchemaCommit": "aadf3b0b8dbbabdb4d880b0fc714255fea436ff7",
    "spdxSchemaSha256": file_sha256(ROOT / "schemas/spdx/spdx-2.3.schema.json"),
    "cycloneDxSchemaCommit": "b29bae660048e0ad2fbc5f2972927b442ce951c4",
    "cycloneDxSchemaSha256": file_sha256(ROOT / "schemas/cyclonedx/bom-1.7.schema.json"),
  }
  if schema_validation != expected_schema_validation:
    fail("SBOM schema-validation inputs differ from the reviewed set")
  for value in (schema_validation["pythonImage"], schema_validation["jsonschema"]):
    if value not in workflow_text:
      fail("release workflow does not enforce the reviewed schema validator")


def check_engine_dependency_snapshot(upstream: dict) -> None:
  snapshot = upstream.get("dependencySnapshot", {})
  expected = {
    "goModSha256": ROOT / "engine" / "go.mod",
    "goSumSha256": ROOT / "engine" / "go.sum",
    "vendorModulesSha256": ROOT / "engine" / "vendor" / "modules.txt",
  }
  if snapshot.get("goVersion") != "1.25.0":
    fail("engine dependency snapshot must use Go 1.25 language semantics")
  for key, path in expected.items():
    if snapshot.get(key) != file_sha256(path):
      fail(f"engine dependency snapshot differs: {key}")


def load_generated_files(upstream: dict) -> set[str]:
  generated_path = ROOT / "source" / "generated-files.txt"
  generated = [line.strip() for line in generated_path.read_text(encoding="utf-8").splitlines() if line.strip()]
  if generated != sorted(set(generated)):
    fail("generated source inventory must be sorted and contain no duplicates")
  missing = [path for path in generated if not (ROOT / "engine" / path).is_file()]
  if missing:
    fail(f"generated source inventory contains missing files: {missing[:5]}")
  if upstream.get("generatedFiles") != "source/generated-files.txt":
    fail("provenance does not reference the generated source inventory")
  generated_validation = upstream.get("generatedSourceValidation")
  expected_validation = {
    "method": "make",
    "validatorDockerfile": "tests/generated-source/Dockerfile",
    "baseImage": (
      "golang:1.19.10-bullseye@sha256:"
      "08defd390a65f3a72cfde1d04a538c6dc2d48d1f0f443ff99a8862c11c19572c"
    ),
    "goVersion": "go1.19.10",
    "debianSnapshot": "20260701T000000Z",
    "targets": (
      "vendor/modules.txt, protobuf, and every non-protobuf path in "
      "source/generated-files.txt"
    ),
  }
  if generated_validation != expected_validation:
    fail("generated-source validation inputs differ from the reviewed set")
  verifier = (ROOT / "scripts" / "verify-upstream-provenance.sh").read_text(encoding="utf-8")
  required_verifier_values = (
    expected_validation["validatorDockerfile"],
    expected_validation["goVersion"],
    "make -j4 vendor/modules.txt",
    "make -j4 protobuf",
    "verify-generated-provenance.py",
  )
  for value in required_verifier_values:
    if value not in verifier:
      fail("upstream provenance script does not enforce generated-source inputs")
  return {f"engine/{path}" for path in generated}


def check_retained_upstream_package_files(
  upstream_root: Path,
) -> int:
  declared_differences = EXPECTED_MODIFIED_FILES | EXPECTED_ADDED_FILES
  compared = 0
  for local_path in sorted((ROOT / "engine" / "pkg").rglob("*")):
    if not local_path.is_file() and not local_path.is_symlink():
      continue
    relative = local_path.relative_to(ROOT / "engine").as_posix()
    recorded_path = f"engine/{relative}"
    if recorded_path in declared_differences:
      continue
    upstream_path = upstream_root / relative
    if local_path.is_symlink():
      if not upstream_path.is_symlink() or os.readlink(local_path) != os.readlink(upstream_path):
        fail(f"retained upstream symlink differs without a declaration: {recorded_path}")
    elif not upstream_path.is_file() or file_sha256(local_path) != file_sha256(upstream_path):
      fail(f"retained upstream file differs without a declaration: {recorded_path}")
    compared += 1
  if compared < MIN_RETAINED_UPSTREAM_PACKAGE_FILES:
    fail(f"retained upstream comparison was unexpectedly small: {compared}")
  return compared


def parse_native_upstreams(values: list[str]) -> dict[str, Path]:
  parsed = {}
  for value in values:
    name, separator, path = value.partition("=")
    if not separator or not name or not path or name in parsed:
      fail(f"invalid native upstream mapping: {value}")
    parsed[name] = Path(path).resolve()
  return parsed


def check_native_upstreams(dependencies: list[dict], native_roots: dict[str, Path]) -> None:
  expected_names = {dependency.get("name") for dependency in dependencies}
  if set(native_roots) != expected_names:
    fail("native upstream mappings do not match the provenance dependency set")
  for dependency in dependencies:
    name = dependency["name"]
    remote_root = native_roots[name]
    if not remote_root.is_dir():
      fail(f"native upstream checkout is missing: {name}")
    revision = subprocess.run(
      ["git", "rev-parse", "HEAD"],
      cwd=remote_root,
      check=True,
      text=True,
      stdout=subprocess.PIPE,
    ).stdout.strip()
    if revision != dependency.get("commit"):
      fail(f"native upstream revision differs for {name}: {revision}")
    expected_upstream_tree = dependency.get("upstreamTreeSha256", dependency.get("treeSha256"))
    if tree_sha256(remote_root) != expected_upstream_tree:
      fail(f"native upstream tree differs from the distributed tree: {name}")
    additions = dependency.get("complianceAdditions", [])
    if not isinstance(additions, list):
      fail(f"native compliance additions have an invalid shape: {name}")
    for addition in additions:
      path = addition.get("path", "")
      target = ROOT / "engine" / "c-deps" / name / path
      if not target.is_file() or file_sha256(target) != addition.get("sha256"):
        fail(f"native compliance addition differs: {name}/{path}")
      if not addition.get("source"):
        fail(f"native compliance addition has no source: {name}/{path}")


def check_source_dependency_baseline(baseline: dict, upstream_root: Path | None) -> None:
  baseline_repository = baseline.get("repository", "")
  baseline_commit = baseline.get("commit", "")
  baseline_source_path = baseline.get("path", "")
  baseline_artifact = baseline.get("artifact", "")
  baseline_sha256 = baseline.get("vendorModulesSha256", "")
  if baseline_repository != "https://github.com/Ratio1/r1-distributed-sql.git":
    fail("source dependency baseline repository is invalid")
  if not re.fullmatch(r"[0-9a-f]{40}", baseline_commit):
    fail("source dependency baseline commit is invalid")
  if baseline_source_path != "engine/vendor/modules.txt":
    fail("source dependency baseline path is invalid")
  if baseline_artifact != "source/engine-v23.1.28-vendor-modules.baseline.txt":
    fail("source dependency baseline artifact is invalid")
  if not re.fullmatch(r"[0-9a-f]{64}", baseline_sha256):
    fail("source baseline vendor module hash is invalid")

  artifact_path = ROOT / baseline_artifact
  try:
    artifact_path.resolve(strict=True).relative_to(ROOT.resolve())
  except (OSError, ValueError):
    fail("source dependency baseline artifact is missing or outside the source tree")
  if file_sha256(artifact_path) != baseline_sha256:
    fail("source dependency baseline artifact differs")

  if upstream_root is not None:
    baseline_path = upstream_root / Path(baseline_source_path).relative_to("engine")
    if not baseline_path.is_file() or file_sha256(baseline_path) != baseline_sha256:
      fail("source baseline vendor module snapshot differs")
    return

  git_probe = subprocess.run(
    ["git", "rev-parse", "--is-inside-work-tree"],
    cwd=ROOT,
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
  )
  if git_probe.returncode != 0:
    return
  commit_probe = subprocess.run(
    ["git", "cat-file", "-e", f"{baseline_commit}^{{commit}}"],
    cwd=ROOT,
    check=False,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )
  if commit_probe.returncode != 0:
    return
  result = subprocess.run(
    ["git", "show", f"{baseline_commit}:{baseline_source_path}"],
    cwd=ROOT,
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
  )
  if result.returncode != 0:
    fail("source baseline commit has no vendor module snapshot")
  if hashlib.sha256(result.stdout).hexdigest() != baseline_sha256:
    fail("source baseline vendor module snapshot differs")


def check_engine_overrides(upstream_commit: str, patch_record: str, upstream_root: Path | None) -> None:
  overrides = json.loads(OVERRIDES.read_text(encoding="utf-8"))
  if overrides.get("upstreamCommit") != upstream_commit:
    fail("engine override record does not use the provenance upstream commit")
  records = overrides.get("modifiedUpstreamFiles")
  if not isinstance(records, list):
    fail("modified upstream file records must be a list")
  paths = {record.get("path") for record in records if isinstance(record, dict)}
  if paths != EXPECTED_MODIFIED_FILES or len(records) != len(EXPECTED_MODIFIED_FILES):
    fail(f"engine override set changed: {sorted(path for path in paths if path)}")
  for record in records:
    path = record.get("path", "")
    upstream_hash = record.get("upstreamSha256", "")
    distributed_hash = record.get("distributedSha256", "")
    change_class = record.get("changeClass")
    if change_class not in {
      "comments-only",
      "go-toolchain-compatibility",
      "product-identity-and-privacy",
      "runtime-recovery-signal",
    }:
      fail(f"engine override has an invalid change class: {path}")
    if not record.get("reason"):
      fail(f"engine override has no reason: {path}")
    if not re.fullmatch(r"[0-9a-f]{64}", upstream_hash):
      fail(f"engine override has an invalid upstream hash: {path}")
    target = ROOT / path
    if not target.is_file() or file_sha256(target) != distributed_hash:
      fail(f"engine override distributed hash differs: {path}")
    check_source_notice(target, "modified-upstream")
    if path not in patch_record:
      fail(f"engine override is absent from RATIO1_PATCHES.md: {path}")
    if upstream_root is not None:
      upstream_path = upstream_root / path.removeprefix("engine/")
      if not upstream_path.is_file() or file_sha256(upstream_path) != upstream_hash:
        fail(f"engine override upstream hash differs: {path}")
      if change_class == "comments-only" and (
        comments_only_projection(upstream_path.read_bytes())
        != comments_only_projection(target.read_bytes())
      ):
        fail(f"engine override changes more than Go comments: {path}")

  removed = overrides.get("removedUpstreamFiles")
  removed_paths = {record.get("path") for record in removed if isinstance(record, dict)}
  if removed_paths != EXPECTED_REMOVED_FILES or len(removed) != len(EXPECTED_REMOVED_FILES):
    fail("removed upstream file set changed")
  for record in removed:
    path = record["path"]
    if (ROOT / path).exists() or not record.get("reason"):
      fail(f"removed upstream file is present or unexplained: {path}")
    if path not in patch_record:
      fail(f"removed upstream file is absent from RATIO1_PATCHES.md: {path}")
    if upstream_root is not None:
      upstream_path = upstream_root / path.removeprefix("engine/")
      if not upstream_path.is_file() or file_sha256(upstream_path) != record.get("upstreamSha256"):
        fail(f"removed upstream file hash differs: {path}")

  added = overrides.get("ratio1AddedFiles")
  added_paths = {record.get("path") for record in added if isinstance(record, dict)}
  if added_paths != EXPECTED_ADDED_FILES or len(added) != len(EXPECTED_ADDED_FILES):
    fail("Ratio1-added engine file set changed")
  for record in added:
    path = record["path"]
    target = ROOT / path
    if not target.is_file() or file_sha256(target) != record.get("sha256"):
      fail(f"Ratio1-added engine file hash differs: {path}")
    check_source_notice(target, "ratio1-added")
    if path not in patch_record:
      fail(f"Ratio1-added engine file is absent from RATIO1_PATCHES.md: {path}")

  dependency = overrides.get("dependencySnapshot", {})
  distributed = dependency.get("distributed", {})
  current_dependency_files = {
    "goModSha256": ROOT / "engine" / "go.mod",
    "goSumSha256": ROOT / "engine" / "go.sum",
    "vendorModulesSha256": ROOT / "engine" / "vendor" / "modules.txt",
  }
  for key, path in current_dependency_files.items():
    if distributed.get(key) != file_sha256(path):
      fail(f"distributed dependency snapshot differs: {key}")
  if not dependency.get("reason") or "dependency snapshot" not in patch_record.lower():
    fail("dependency snapshot is not explained in RATIO1_PATCHES.md")
  if upstream_root is not None:
    upstream = dependency.get("upstream", {})
    for key, path in list(current_dependency_files.items())[:2]:
      upstream_path = upstream_root / path.relative_to(ROOT / "engine")
      if not upstream_path.is_file() or upstream.get(key) != file_sha256(upstream_path):
        fail(f"upstream dependency snapshot differs: {key}")
  check_source_dependency_baseline(dependency.get("sourceBaseline", {}), upstream_root)

  backports = overrides.get("securityBackports")
  advisories = {record.get("advisory") for record in backports if isinstance(record, dict)}
  if advisories != EXPECTED_SECURITY_BACKPORTS or len(backports) != len(EXPECTED_SECURITY_BACKPORTS):
    fail("security backport set changed")
  for backport in backports:
    if not backport.get("module") or not backport.get("source"):
      fail(f"security backport metadata is incomplete: {backport.get('advisory')}")
    if backport["advisory"] not in patch_record:
      fail(f"security backport is absent from RATIO1_PATCHES.md: {backport['advisory']}")
    files = backport.get("files")
    if not files:
      fail(f"security backport has no files: {backport['advisory']}")
    for record in files:
      target = ROOT / record.get("path", "")
      if not target.is_file() or file_sha256(target) != record.get("sha256"):
        fail(f"security backport file hash differs: {record.get('path')}")
      check_source_notice(target, record.get("changeType", ""))

  compatibility_backports = overrides.get("dependencyCompatibilityBackports")
  backport_ids = {
    record.get("id") for record in compatibility_backports if isinstance(record, dict)
  }
  if backport_ids != EXPECTED_COMPATIBILITY_BACKPORTS or (
    len(compatibility_backports) != len(EXPECTED_COMPATIBILITY_BACKPORTS)
  ):
    fail("dependency compatibility backport set changed")
  for backport in compatibility_backports:
    if not backport.get("module") or not backport.get("source") or not backport.get("reason"):
      fail(f"dependency compatibility backport metadata is incomplete: {backport.get('id')}")
    if backport["id"] not in patch_record:
      fail(f"dependency compatibility backport is absent from RATIO1_PATCHES.md: {backport['id']}")
    files = backport.get("files")
    if not files:
      fail(f"dependency compatibility backport has no files: {backport['id']}")
    for record in files:
      target = ROOT / record.get("path", "")
      if not target.is_file() or file_sha256(target) != record.get("sha256"):
        fail(f"dependency compatibility backport file hash differs: {record.get('path')}")
      check_source_notice(target, "modified-upstream")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--print-native-hashes", action="store_true")
  parser.add_argument("--upstream-root", type=Path)
  parser.add_argument("--native-upstream", action="append", default=[])
  args = parser.parse_args()

  provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
  expected_algorithm = (
    "sha256 over sorted entries: type-byte, NUL, relative UTF-8 path, NUL, "
    "file SHA-256 bytes or symlink target, NUL"
  )
  if provenance.get("nativeTreeHashAlgorithm") != expected_algorithm:
    fail("native tree-hash algorithm is missing or changed")
  actual_hashes = {}
  native_dependencies = provenance.get("nativeDependencies", [])
  for dependency in native_dependencies:
    name = dependency.get("name", "")
    root = ROOT / "engine" / "c-deps" / name
    if not root.is_dir():
      fail(f"native dependency tree is missing: {name}")
    actual = tree_sha256(root)
    actual_hashes[name] = actual
    if not args.print_native_hashes and dependency.get("treeSha256") != actual:
      fail(f"native dependency tree hash differs for {name}: {actual}")

  if args.print_native_hashes:
    print(json.dumps(actual_hashes, indent=2, sort_keys=True))
    return

  if args.native_upstream:
    check_native_upstreams(native_dependencies, parse_native_upstreams(args.native_upstream))

  runtime = provenance.get("runtimeLayer", {})
  if runtime.get("entrypointSha256") != file_sha256(ROOT / "entrypoint.sh"):
    fail("entrypoint hash differs from provenance")

  check_build_input(
    provenance.get("buildInputs", {}),
    (ROOT / "Dockerfile").read_text(encoding="utf-8"),
    (ROOT / "source" / "cloudflared-buildinfo.txt").read_text(encoding="utf-8"),
  )
  check_engine_dependency_snapshot(provenance.get("upstream", {}))
  load_generated_files(provenance.get("upstream", {}))
  check_engine_overrides(
    provenance.get("upstream", {}).get("commit", ""),
    (ROOT / "RATIO1_PATCHES.md").read_text(encoding="utf-8"),
    args.upstream_root.resolve() if args.upstream_root else None,
  )
  compared = 0
  if args.upstream_root:
    compared = check_retained_upstream_package_files(args.upstream_root.resolve())
  print(
    f"provenance verified: {len(actual_hashes)} native trees, "
    f"{compared} retained upstream package files, and pinned runtime inputs"
  )


if __name__ == "__main__":
  main()
