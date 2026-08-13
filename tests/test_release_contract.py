#!/usr/bin/env python3
import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
  return (ROOT / path).read_text(encoding="utf-8")


class ReleaseContractTests(unittest.TestCase):

  def test_required_compliance_and_provenance_files_exist(self):
    required = (
      "LICENSE",
      ".gitattributes",
      "NOTICE",
      "THIRD_PARTY_NOTICES.md",
      "UPSTREAM.md",
      "RATIO1_PATCHES.md",
      "SECURITY.md",
      "RELEASE.md",
      "source/provenance.json",
      "source/ratio1-engine-overrides.json",
      "source/manifest.sha256",
      "source/license-inventory.json",
      "source/runtime-files.txt",
      "source/generated-files.txt",
      "source/public-test-fixtures.sha256",
      "source/cloudflared-buildinfo.txt",
      "source/cloudflared-compiled-packages.txt",
      "source/cloudflared-license-inventory.csv",
      "scripts/verify-source-boundary.py",
      "scripts/verify-runtime-closure.py",
      "scripts/verify-provenance.py",
      "scripts/verify-cloudflared-source.py",
      "scripts/verify-public-test-fixtures.py",
      "scripts/verify-security-vex.py",
      "security/openvex.json",
      "scripts/verify-image.sh",
    )
    missing = [path for path in required if not (ROOT / path).is_file()]
    self.assertEqual(missing, [], f"missing release-contract files: {missing}")

  def test_root_license_is_apache_2(self):
    license_text = read("LICENSE")
    self.assertIn("Apache License", license_text)
    self.assertIn("Version 2.0", license_text)

  def test_git_does_not_normalize_manifested_source_bytes(self):
    self.assertIn("* -text", read(".gitattributes"))

  def test_source_provenance_pins_upstream_and_native_dependencies(self):
    provenance = json.loads(read("source/provenance.json"))
    self.assertEqual(provenance["upstream"]["tag"], "v23.1.28")
    self.assertEqual(
      provenance["upstream"]["commit"],
      "76e598c9b1c100fd9280b979140b5e377c330a20",
    )
    self.assertEqual(provenance["upstream"]["changeLicense"], "Apache-2.0")
    self.assertEqual(provenance["upstream"]["changeDate"], "2026-04-01")
    self.assertEqual(
      provenance["buildInputs"]["goBuilder"],
      "golang:1.26.5-bookworm@sha256:0d327c83532d3cdeeeebab56ce85962bf09cb89545355b10207c7771b0c3713f",
    )
    dependencies = {item["name"]: item for item in provenance["nativeDependencies"]}
    self.assertEqual(set(dependencies), {"geos", "jemalloc", "libedit", "proj"})
    for dependency in dependencies.values():
      for key in ("sourceUrl", "commit", "treeSha256", "licenseFile", "role"):
        self.assertTrue(dependency.get(key), f"native dependency is missing {key}: {dependency}")
    cloudflared = provenance["buildInputs"]["cloudflared"]
    self.assertEqual(cloudflared["commit"], "b4f47e2ab538ab6e31d3dc6adc5489455ad446de")
    self.assertEqual(
      cloudflared["sourceArchiveSha256"],
      "e897f2cdb6f63964bb7b5841df80087489a65ab9fda356ef48dd13202bba59c0",
    )
    self.assertEqual(
      cloudflared["binarySha256"],
      "ab478b502bc27dc33180df190483ba84f941e18266d0ae382e85c49fc19ede29",
    )

    overrides = json.loads(read("source/ratio1-engine-overrides.json"))
    self.assertEqual(overrides["upstreamCommit"], provenance["upstream"]["commit"])
    self.assertEqual(
      {record["path"] for record in overrides["modifiedUpstreamFiles"]},
      {
        "engine/pkg/cli/cli.go",
        "engine/pkg/ui/ui.go",
        "engine/pkg/util/ctxutil/context.go",
      },
    )
    self.assertEqual(
      {record["advisory"] for record in overrides["securityBackports"]},
      {"GO-2026-4518", "GO-2026-5004"},
    )
    self.assertEqual(
      {record["id"] for record in overrides["dependencyCompatibilityBackports"]},
      {"google-api-grpc-credentials-options"},
    )

  def test_cloudflared_dependency_notices_are_complete_and_pinned(self):
    rows = read("source/cloudflared-license-inventory.csv").splitlines()
    self.assertEqual(rows[0], "package,license_url,spdx")
    self.assertGreaterEqual(len(rows), 60)
    for row in rows[1:]:
      package, url, spdx = row.split(",", 2)
      self.assertTrue(package)
      self.assertIn("/blob/", url)
      self.assertNotIn("/blob/HEAD/", url)
      self.assertNotIn(spdx.lower(), {"", "unknown", "noassertion"})
    by_package = {row.split(",", 2)[0]: row.split(",", 2)[2] for row in rows[1:]}
    self.assertEqual(by_package["gopkg.in/yaml.v2"], "Apache-2.0 AND MIT")
    self.assertEqual(by_package["gopkg.in/yaml.v3"], "Apache-2.0 AND MIT")
    self.assertEqual(
      by_package["github.com/klauspost/compress"],
      "BSD-3-Clause AND Apache-2.0 AND MIT",
    )
    self.assertEqual(by_package["github.com/facebookgo/grace"], "MIT")
    self.assertIn("github.com/chungthuang/quic-go", by_package)
    self.assertIn("github.com/ipostelnik/cli/v2", by_package)
    notices = [
      path for path in (ROOT / "licenses/cloudflared/dependencies").rglob("*")
      if path.is_file()
    ]
    self.assertEqual(len(notices), 96)
    self.assertTrue((ROOT / "licenses/cloudflared/dependencies/gopkg.in/yaml.v2/LICENSE.libyaml").is_file())
    build_info = read("source/cloudflared-buildinfo.txt")
    self.assertIn("github.com/cloudflare/cloudflared/cmd/cloudflared", build_info)
    self.assertIn("/cloudflared: go1.26.5", build_info)
    self.assertIn("google.golang.org/grpc\tv1.83.0", build_info)
    self.assertNotIn("vcs.modified=true", build_info)
    self.assertEqual(len(read("source/cloudflared-compiled-packages.txt").splitlines()), 603)

  def test_checked_out_source_has_no_ccl_implementation_or_nested_git(self):
    forbidden_paths = (
      ROOT / "engine/pkg/ccl",
      ROOT / "engine/pkg/ui/distccl",
      ROOT / "engine/pkg/ui/workspaces/db-console/ccl",
    )
    self.assertFalse([str(path) for path in forbidden_paths if path.exists()])
    nested_git = [
      path for path in (ROOT / "engine").rglob(".git")
      if path != ROOT / ".git"
    ] if (ROOT / "engine").exists() else []
    self.assertEqual(nested_git, [])
    boundary_script = read("scripts/verify-source-boundary.py")
    self.assertIn("rev-list", boundary_script)
    self.assertIn("cat-file", boundary_script)
    self.assertIn("is_engine_file", boundary_script)
    self.assertIn("Cockroach Community License", boundary_script)
    self.assertFalse((ROOT / "engine/.github").exists())

  def test_every_engine_file_has_an_affirmative_license_classification(self):
    inventory = json.loads(read("source/license-inventory.json"))
    entries = inventory["files"]
    classified = {entry["path"] for entry in entries}
    actual = {
      path.relative_to(ROOT).as_posix()
      for path in (ROOT / "engine").rglob("*")
      if path.is_file()
    }
    self.assertEqual(classified, actual)
    for entry in entries:
      self.assertTrue(entry["spdx"])
      self.assertTrue(entry["basis"])
      self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")

    by_path = {entry["path"]: entry["spdx"] for entry in entries}
    self.assertEqual(by_path["engine/c-deps/geos/COPYING"], "LGPL-2.1-only")
    self.assertEqual(
      by_path["engine/c-deps/geos/include/geos/algorithm/ttmath/COPYRIGHT"],
      "BSD-3-Clause",
    )
    self.assertEqual(
      by_path["engine/c-deps/geos/macros/ax_check_compile_flag.m4"],
      "GPL-3.0-or-later WITH Autoconf-exception-macro",
    )
    self.assertEqual(by_path["engine/c-deps/jemalloc/test/src/SFMT.c"], "BSD-3-Clause")
    self.assertEqual(by_path["engine/c-deps/jemalloc/test/unit/hash.c"], "MIT")
    self.assertEqual(
      by_path["engine/c-deps/libedit/compile"],
      "GPL-2.0-or-later WITH Autoconf-exception-generic",
    )
    self.assertEqual(
      by_path["engine/c-deps/libedit/ltmain.sh"],
      "GPL-2.0-or-later WITH Libtool-exception",
    )
    self.assertEqual(by_path["engine/c-deps/libedit/install-sh"], "MIT")
    self.assertEqual(by_path["engine/c-deps/proj/jniwrap/org/proj4/PJ.java"], "MIT")
    for yaml_version in ("v2", "v3"):
      yaml_root = f"engine/vendor/gopkg.in/yaml.{yaml_version}"
      for filename in (
        "apic.go", "emitterc.go", "parserc.go", "readerc.go",
        "scannerc.go", "writerc.go", "yamlh.go", "yamlprivateh.go",
      ):
        self.assertEqual(by_path[f"{yaml_root}/{filename}"], "MIT")
      self.assertEqual(by_path[f"{yaml_root}/decode.go"], "Apache-2.0")
    self.assertEqual(
      by_path["engine/vendor/github.com/klauspost/compress/flate/deflate.go"],
      "BSD-3-Clause",
    )
    self.assertEqual(
      by_path["engine/vendor/github.com/klauspost/compress/internal/snapref/decode.go"],
      "BSD-3-Clause",
    )
    self.assertEqual(
      by_path["engine/vendor/github.com/klauspost/compress/zstd/internal/xxhash/xxhash.go"],
      "MIT",
    )

  def test_source_manifest_covers_release_governance_and_tests(self):
    manifest_paths = {
      line.split("  ", 1)[1]
      for line in read("source/manifest.sha256").splitlines()
      if "  " in line
    }
    for path in (
      ".gitattributes",
      ".github/workflows/ci.yml",
      ".github/workflows/release.yml",
      ".github/workflows/security.yml",
      "Dockerfile",
      "RATIO1_PATCHES.md",
      "tests/test_release_contract.py",
      "testbed/run-local-cluster.sh",
    ):
      self.assertIn(path, manifest_paths)

  def test_public_history_has_no_forbidden_ccl_paths(self):
    result = subprocess.run(
      ["git", "rev-list", "--objects", "--all"],
      cwd=ROOT,
      check=True,
      text=True,
      stdout=subprocess.PIPE,
    )
    forbidden = (
      "engine/pkg/ccl/",
      "engine/pkg/ui/distccl/",
      "engine/pkg/ui/workspaces/db-console/ccl/",
    )
    offenders = [line for line in result.stdout.splitlines() if any(path in line for path in forbidden)]
    self.assertEqual(offenders, [])

  def test_every_engine_path_is_tracked(self):
    tracked = set(subprocess.run(
      ["git", "ls-files", "engine"],
      cwd=ROOT,
      check=True,
      text=True,
      stdout=subprocess.PIPE,
    ).stdout.splitlines())
    actual = {
      path.relative_to(ROOT).as_posix()
      for path in (ROOT / "engine").rglob("*")
      if path.is_file() or path.is_symlink()
    }
    self.assertEqual(actual - tracked, set())

  def test_release_build_uses_only_pinned_neutral_inputs(self):
    dockerfile = read("Dockerfile")
    lowered = dockerfile.lower()
    self.assertNotIn("cockroachdb/builder", lowered)
    self.assertNotRegex(lowered, r"from\s+cockroachdb/")
    self.assertNotRegex(lowered, r"git\s+clone\s+[^\n]*cockroachdb/cockroach")
    self.assertNotRegex(lowered, r"\bmake\s+[^\n]*cockroach")
    self.assertRegex(dockerfile, r"FROM\s+[^\s]+@sha256:[0-9a-f]{64}")
    self.assertNotIn("perl -0pi", dockerfile)
    self.assertIn("GOPROXY=off", dockerfile)
    self.assertIn("snapshot.debian.org/archive/debian/20260701T000000Z", dockerfile)
    self.assertIn("autoconf=2.71-3", dockerfile)
    self.assertIn("bash=5.2.15-2+b13", dockerfile)
    self.assertIn("scripts/build-engine.sh", dockerfile)
    self.assertIn("scripts/verify-provenance.py", dockerfile)
    self.assertIn("go test -mod=vendor", dockerfile)
    self.assertIn("github.com/jackc/pgproto3/v2", dockerfile)
    self.assertIn("github.com/jackc/pgx/v4/internal/sanitize", dockerfile)
    self.assertIn("./pkg/util/ctxutil", dockerfile)
    self.assertIn("./pkg/util/goschedstats", dockerfile)
    self.assertIn("ab478b502bc27dc33180df190483ba84f941e18266d0ae382e85c49fc19ede29", dockerfile)
    self.assertIn("ADD --checksum=sha256:e897f2cdb6f63964bb7b5841df80087489a65ab9fda356ef48dd13202bba59c0", dockerfile)
    self.assertNotRegex(lowered, r"from\s+cloudflare/cloudflared")
    self.assertIn("scripts/verify-cloudflared-source.py", dockerfile)
    self.assertIn("ARG BUILD_JOBS=4", dockerfile)
    self.assertIn("ENTRYPOINT [\"/usr/local/bin/deeploy-crdb-entrypoint\"]", dockerfile)
    self.assertIn("source/manifest.sha256", dockerfile)
    self.assertIn("generate-source-manifest.py --check", dockerfile)

  def test_ci_verifies_ratio1_overrides_against_exact_upstream_source(self):
    for workflow in (".github/workflows/ci.yml", ".github/workflows/release.yml"):
      text = read(workflow)
      self.assertIn("76e598c9b1c100fd9280b979140b5e377c330a20", text)
      self.assertIn("https://github.com/cockroachdb/cockroach.git", text)
      self.assertIn("verify-provenance.py --upstream-root", text)

  def test_ci_proves_oss_and_release_supply_chain(self):
    workflows = list((ROOT / ".github/workflows").glob("*.yml"))
    self.assertTrue(workflows)
    workflow_text = "\n".join(path.read_text(encoding="utf-8") for path in workflows)
    self.assertIn("./cockroach version | grep -F 'Distribution:     OSS'", workflow_text)
    self.assertIn("spdx-json", workflow_text)
    self.assertIn("cyclonedx-json", workflow_text)
    self.assertIn("cosign sign", workflow_text)
    self.assertIn("cosign attest", workflow_text)
    self.assertIn("cosign verify", workflow_text)
    self.assertIn("--certificate-oidc-issuer", workflow_text)
    self.assertIn("--certificate-identity", workflow_text)
    self.assertNotIn("--certificate-identity-regexp", workflow_text)
    self.assertIn("actions/attest@", workflow_text)
    self.assertIn("https://spdx.dev/Document/v2.3", workflow_text)
    self.assertNotIn("--predicate-type 'https://spdx.dev/Document'", workflow_text)
    self.assertIn("artifact-metadata: write", workflow_text)
    self.assertIn("environment: release", read(".github/workflows/release.yml"))
    self.assertIn('git merge-base --is-ancestor "$GITHUB_SHA" origin/main', workflow_text)
    self.assertIn("platforms: linux/amd64", workflow_text)
    self.assertIn("image-reference.txt", read(".github/workflows/security.yml"))
    self.assertNotIn("r1-distributed-sql:latest", read(".github/workflows/security.yml"))
    self.assertIn(
      "skip-dirs: engine/pkg/security/securitytest/test_certs",
      read(".github/workflows/security.yml"),
    )
    floating = []
    for path in workflows:
      for line in path.read_text(encoding="utf-8").splitlines():
        match = re.search(r"\buses:\s*([^\s]+)@([^\s#]+)", line)
        if match and not re.fullmatch(r"[0-9a-f]{40}", match.group(2)):
          floating.append(f"{path.name}: {line.strip()}")
    self.assertEqual(floating, [], f"workflow actions must be commit-pinned: {floating}")

  def test_public_fixture_allowlist_is_enforced(self):
    subprocess.run(
      ["python3", "scripts/verify-public-test-fixtures.py"],
      cwd=ROOT,
      check=True,
      stdout=subprocess.PIPE,
      text=True,
    )

  def test_security_vex_is_narrow_and_evidenced(self):
    subprocess.run(
      ["python3", "scripts/verify-security-vex.py"],
      cwd=ROOT,
      check=True,
      stdout=subprocess.PIPE,
      text=True,
    )

  def test_runtime_and_local_testbed_are_present(self):
    required = (
      "entrypoint.sh",
      "scripts/entrypoint-multinode-smoke.sh",
      "scripts/direct-engine-three-node-smoke.sh",
      "scripts/validate-runtime-change.sh",
      "tests/local-transport/Dockerfile",
      "testbed/run-local-cluster.sh",
      "testbed/README.md",
    )
    missing = [path for path in required if not (ROOT / path).is_file()]
    self.assertEqual(missing, [], f"missing runtime/testbed files: {missing}")
    testbed = read("scripts/entrypoint-multinode-smoke.sh")
    self.assertIn('CRDB_TEST_MAX_OFFSET:-500ms', testbed)
    self.assertIn("generate_series(1, 10000)", testbed)
    self.assertIn("expected replicated row count 10000", testbed)
    self.assertIn("array_length(voting_replicas, 1) < 3", testbed)
    self.assertIn("array_length(learner_replicas, 1) > 0", testbed)
    self.assertNotIn("ranges.underreplicated", testbed)
    direct_test = read("scripts/direct-engine-three-node-smoke.sh")
    self.assertIn("--max-offset=500ms", direct_test)
    self.assertIn("generate_series(1, 10000)", direct_test)
    self.assertIn("array_length(voting_replicas, 1) < 3", direct_test)
    self.assertIn("array_length(learner_replicas, 1) > 0", direct_test)
    self.assertNotIn("ranges.underreplicated", direct_test)
    local_runner = read("testbed/run-local-cluster.sh")
    self.assertIn("base_binary_hash", local_runner)
    self.assertIn("base_entrypoint_hash", local_runner)


if __name__ == "__main__":
  unittest.main()
