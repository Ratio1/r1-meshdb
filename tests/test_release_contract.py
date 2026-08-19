#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
  return (ROOT / path).read_text(encoding="utf-8")


def load_script(path: str):
  spec = importlib.util.spec_from_file_location(Path(path).stem, ROOT / path)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"unable to load {path}")
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


def source_baseline(repository: Path, commit: str, content: bytes) -> dict:
  artifact = repository / "source" / "engine-v23.1.28-vendor-modules.baseline.txt"
  artifact.parent.mkdir(parents=True, exist_ok=True)
  artifact.write_bytes(content)
  return {
    "repository": "https://github.com/Ratio1/r1-meshdb.git",
    "commit": commit,
    "path": "engine/vendor/modules.txt",
    "artifact": "source/engine-v23.1.28-vendor-modules.baseline.txt",
    "vendorModulesSha256": hashlib.sha256(content).hexdigest(),
  }


class ReleaseContractTests(unittest.TestCase):

  def test_release_version_resolution_is_strict_and_monotonic(self):
    resolver = load_script("scripts/resolve-release-version.py")
    resolved = resolver.resolve_release_version(
      "1.2.3", previous_version="1.2.2", existing_tags=("v1.2.1",)
    )
    self.assertEqual(resolved, {"version": "1.2.3", "release_tag": "v1.2.3"})

    for invalid in ("1.2", "v1.2.3", "01.2.3", "1.02.3", "1.2.03", "1.2.3-rc.1"):
      with self.subTest(invalid=invalid), self.assertRaises(ValueError):
        resolver.resolve_release_version(invalid)

    for previous in ("1.2.3", "1.2.4"):
      with self.subTest(previous=previous), self.assertRaises(ValueError):
        resolver.resolve_release_version("1.2.3", previous_version=previous)

    with self.assertRaises(ValueError):
      resolver.resolve_release_version("1.2.3", existing_tags=("v1.3.0",))
    with self.assertRaises(ValueError):
      resolver.resolve_release_version("1.2.3", existing_tags=("v1.2.3",))
    self.assertEqual(
      resolver.resolve_release_version(
        "1.2.3", existing_tags=("v1.2.3",), allow_current_tag=True
      )["release_tag"],
      "v1.2.3",
    )

  def test_release_version_resolution_supports_first_version_file(self):
    resolver = load_script("scripts/resolve-release-version.py")
    self.assertEqual(
      resolver.resolve_release_version("1.0.0"),
      {"version": "1.0.0", "release_tag": "v1.0.0"},
    )

  def test_comments_only_projection_accepts_comments_but_rejects_code_changes(self):
    verifier = load_script("scripts/verify-provenance.py")
    upstream = b'''package sample

// Upstream comment.
func value() string {
  return "// preserved literal"
}
'''
    comments_changed = b'''// Required modification notice.

package sample

// Ratio1 comment spanning
// multiple lines.
func value() string {
  return "// preserved literal"
}
'''
    code_changed = comments_changed.replace(b"preserved literal", b"changed literal")

    self.assertEqual(
      verifier.comments_only_projection(upstream),
      verifier.comments_only_projection(comments_changed),
    )
    self.assertNotEqual(
      verifier.comments_only_projection(upstream),
      verifier.comments_only_projection(code_changed),
    )

  def test_source_baseline_validation_survives_squash_history(self):
    verifier = load_script("scripts/verify-provenance.py")
    with tempfile.TemporaryDirectory() as directory:
      repository = Path(directory)
      subprocess.run(["git", "init", "--quiet"], cwd=repository, check=True)
      baseline = source_baseline(repository, "a" * 40, b"# baseline vendor modules\n")
      original_root = verifier.ROOT
      verifier.ROOT = repository
      try:
        verifier.check_source_dependency_baseline(baseline, None)
      finally:
        verifier.ROOT = original_root

  def test_source_baseline_validation_checks_available_history(self):
    verifier = load_script("scripts/verify-provenance.py")
    content = b"# baseline vendor modules\n"
    with tempfile.TemporaryDirectory() as directory:
      repository = Path(directory)
      target = repository / "engine" / "vendor" / "modules.txt"
      target.parent.mkdir(parents=True)
      target.write_bytes(content)
      subprocess.run(["git", "init", "--quiet"], cwd=repository, check=True)
      subprocess.run(["git", "add", "."], cwd=repository, check=True)
      subprocess.run(
        [
          "git", "-c", "user.name=CI", "-c", "user.email=ci@example.invalid",
          "commit", "--quiet", "-m", "baseline",
        ],
        cwd=repository,
        check=True,
      )
      commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repository,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
      ).stdout.strip()
      baseline = source_baseline(repository, commit, content)
      original_root = verifier.ROOT
      verifier.ROOT = repository
      try:
        verifier.check_source_dependency_baseline(baseline, None)
        with self.assertRaises(SystemExit):
          verifier.check_source_dependency_baseline(
            {**baseline, "vendorModulesSha256": "0" * 64},
            None,
          )
      finally:
        verifier.ROOT = original_root

  def test_source_baseline_validation_rejects_history_without_snapshot(self):
    verifier = load_script("scripts/verify-provenance.py")
    with tempfile.TemporaryDirectory() as directory:
      repository = Path(directory)
      (repository / "README.md").write_text("baseline\n", encoding="utf-8")
      subprocess.run(["git", "init", "--quiet"], cwd=repository, check=True)
      subprocess.run(["git", "add", "."], cwd=repository, check=True)
      subprocess.run(
        [
          "git", "-c", "user.name=CI", "-c", "user.email=ci@example.invalid",
          "commit", "--quiet", "-m", "baseline",
        ],
        cwd=repository,
        check=True,
      )
      commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repository,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
      ).stdout.strip()
      baseline = source_baseline(repository, commit, b"# baseline vendor modules\n")
      original_root = verifier.ROOT
      verifier.ROOT = repository
      try:
        with self.assertRaises(SystemExit):
          verifier.check_source_dependency_baseline(
            baseline,
            None,
          )
      finally:
        verifier.ROOT = original_root

  def test_source_baseline_validation_uses_exact_upstream_snapshot(self):
    verifier = load_script("scripts/verify-provenance.py")
    content = b"# exact upstream vendor modules\n"
    with tempfile.TemporaryDirectory() as directory:
      upstream_root = Path(directory)
      target = upstream_root / "vendor" / "modules.txt"
      target.parent.mkdir(parents=True)
      target.write_bytes(content)
      with tempfile.TemporaryDirectory() as directory:
        repository = Path(directory)
        baseline = source_baseline(repository, "a" * 40, content)
        original_root = verifier.ROOT
        verifier.ROOT = repository
        try:
          verifier.check_source_dependency_baseline(baseline, upstream_root)
          with self.assertRaises(SystemExit):
            verifier.check_source_dependency_baseline(
              {**baseline, "vendorModulesSha256": "0" * 64},
              upstream_root,
            )
        finally:
          verifier.ROOT = original_root

  def test_hosted_provenance_paths_require_exact_upstream_verification(self):
    for workflow_path in (
      ".github/workflows/ci.yml",
      ".github/workflows/release.yml",
      ".github/workflows/security.yml",
    ):
      workflow = read(workflow_path)
      self.assertIn("python3 scripts/verify-provenance.py", workflow)
      self.assertIn("scripts/verify-upstream-provenance.sh", workflow)
    self.assertIn(
      'python3 "${root}/scripts/verify-provenance.py" "${args[@]}"',
      read("scripts/verify-upstream-provenance.sh"),
    )

  def test_required_compliance_and_provenance_files_exist(self):
    required = (
      "LICENSE",
      "VERSION",
      "LICENSE-OVERVIEW.md",
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
      "source/engine-v23.1.28-vendor-modules.baseline.txt",
      "source/vendor-license-manifest.json",
      "source/runtime-files.txt",
      "source/runtime-package-sources.tsv",
      "source/generated-files.txt",
      "source/public-test-fixtures.sha256",
      "source/cloudflared-buildinfo.txt",
      "source/cloudflared-compiled-packages.txt",
      "source/cloudflared-license-inventory.csv",
      "source/sbom-validation-requirements.txt",
      "schemas/spdx/spdx-2.3.schema.json",
      "schemas/cyclonedx/bom-1.7.schema.json",
      "scripts/verify-source-boundary.py",
      "scripts/verify-runtime-closure.py",
      "scripts/verify-provenance.py",
      "scripts/verify-cloudflared-source.py",
      "scripts/verify-public-test-fixtures.py",
      "scripts/verify-security-vex.py",
      "scripts/verify-vendor-provenance.go",
      "scripts/generate-vendor-license-manifest.py",
      "scripts/collect-debian-corresponding-source.sh",
      "scripts/verify-generated-provenance.py",
      "scripts/cloudflare_ephemeral_tunnels.py",
      "testbed/run-real-cloudflare-cluster.sh",
      "scripts/augment-sbom.py",
      "scripts/verify-sbom.py",
      "scripts/validate-sbom-schema.py",
      "scripts/verify-upstream-provenance.sh",
      "security/openvex.json",
      "scripts/verify-image.sh",
      "scripts/inspect-ghcr-tag.sh",
      "scripts/inspect-github-release.sh",
    )
    missing = [path for path in required if not (ROOT / path).is_file()]
    self.assertEqual(missing, [], f"missing release-contract files: {missing}")

  def test_direct_workflow_entrypoints_are_executable(self):
    required = {
      "scripts/inspect-ghcr-tag.sh",
      "scripts/inspect-github-release.sh",
      "scripts/verify-upstream-provenance.sh",
      "testbed/run-real-cloudflare-cluster.sh",
      "testbed/run-rolling-upgrade.sh",
    }
    result = subprocess.run(
      ["git", "ls-files", "--stage", "--", *sorted(required)],
      cwd=ROOT,
      check=True,
      text=True,
      stdout=subprocess.PIPE,
    )
    modes = {
      line.split(maxsplit=3)[3]: line.split(maxsplit=1)[0]
      for line in result.stdout.splitlines()
    }
    self.assertEqual(modes, {path: "100755" for path in required})

  def test_current_vendor_license_closure_is_hash_pinned_and_shipped(self):
    manifest = json.loads(read("source/vendor-license-manifest.json"))
    records = manifest["files"]
    self.assertEqual(len(records), 258)
    self.assertEqual(len({record["path"] for record in records}), len(records))
    for record in records:
      path = ROOT / record["path"]
      self.assertTrue(path.is_file(), record["path"])
      self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), record["sha256"])
    subprocess.run(
      ["python3", "scripts/generate-vendor-license-manifest.py", "--check"],
      cwd=ROOT,
      check=True,
    )
    dockerfile = read("Dockerfile")
    self.assertIn("generate-vendor-license-manifest.py --check", dockerfile)
    self.assertIn("--copy-to /out/licenses/engine/vendor", dockerfile)
    self.assertIn("/usr/share/doc/r1-meshdb/", dockerfile)

  def test_debian_corresponding_source_accompanies_runtime_object_code(self):
    dockerfile = read("Dockerfile")
    assembler = read("scripts/assemble-runtime-rootfs.sh")
    collector = read("scripts/collect-debian-corresponding-source.sh")
    ci = read(".github/workflows/ci.yml")
    release = read(".github/workflows/release.yml")
    for required in (
      "deb-src [check-valid-until=no]",
      "collect-debian-corresponding-source",
      "/usr/share/src/r1-meshdb/debian",
    ):
      self.assertIn(required, dockerfile)
    self.assertIn("runtime-package-sources.tsv", assembler)
    self.assertIn("${source:Package}", assembler)
    self.assertIn("Source: %s (%s)", assembler)
    self.assertIn("apt-get -o Acquire::Check-Valid-Until=false source --download-only", collector)
    self.assertIn("sha256sum -c SHA256SUMS", collector)
    self.assertIn("r1-meshdb-debian-corresponding-source.tar.gz", release)
    self.assertGreaterEqual(release.count("source/runtime-package-sources.tsv"), 3)
    self.assertIn("docker cp", release)
    self.assertIn("--entrypoint /bin/bash r1-meshdb:ci", ci)
    self.assertNotIn("--entrypoint /usr/bin/bash", ci)

  def test_root_license_is_apache_2(self):
    license_text = read("LICENSE")
    self.assertIn("Apache License", license_text)
    self.assertIn("Version 2.0", license_text)

  def test_public_mixed_license_and_candidate_status_are_explicit(self):
    overview = read("LICENSE-OVERVIEW.md")
    self.assertIn("mixed-license distribution", overview)
    self.assertIn("THIRD_PARTY_NOTICES.md", overview)
    self.assertIn("source/license-inventory.json", overview)
    self.assertIn("SPDX and CycloneDX SBOMs", overview)

    readme = read("README.md")
    self.assertIn(
      "source-derived OSS runtime closure from CockroachDB v23.1.28",
      readme,
    )
    self.assertNotIn("CockroachDB v23.1.28 open-source core", readme)
    self.assertIn("LICENSE-OVERVIEW.md", readme)
    self.assertIn(
      "python3 -m unittest tests.test_release_contract tests.test_sbom_contract",
      readme,
    )

    notices = read("THIRD_PARTY_NOTICES.md")
    self.assertIn("replaceable shared libraries", notices)
    self.assertIn("engine/c-deps/geos", notices)
    self.assertIn("95 notice files", notices)
    self.assertIn("one additional MIT license", notices)
    self.assertIn("All 258 current vendored", notices)
    self.assertIn("r1-meshdb-debian-corresponding-source.tar.gz", notices)

    release = read("RELEASE.md")
    self.assertIn("An untagged candidate digest is not a release", release)
    self.assertIn("verify-image.sh", release)
    workflow = read(".github/workflows/release.yml")
    self.assertGreaterEqual(workflow.count("LICENSE-OVERVIEW.md"), 3)
    self.assertNotIn("LicenseRef-R1-MeshDB-Third-Party", read("scripts/verify-image.sh"))

  def test_oci_license_label_uses_standard_application_license(self):
    dockerfile = read("Dockerfile")
    self.assertIn('org.opencontainers.image.licenses="Apache-2.0"', dockerfile)
    self.assertNotIn("LicenseRef-R1-MeshDB-Third-Party", dockerfile)
    self.assertNotIn("LicenseRef-ThirdParty", dockerfile)

  def test_git_does_not_normalize_manifested_source_bytes(self):
    self.assertIn("* -text", read(".gitattributes"))

  def test_meshdb_version_is_valid_single_source_and_build_input(self):
    version = read("VERSION").strip()
    self.assertRegex(version, r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
    self.assertEqual(read("VERSION"), f"{version}\n")
    build_script = read("scripts/build-engine.sh")
    self.assertIn("R1_MESHDB_VERSION_FILE", build_script)
    self.assertIn("R1_MESHDB_VERSION", build_script)
    self.assertIn('ratio1_version="${ratio1_version:-v${meshdb_version}}"', build_script)
    self.assertIn('"${ratio1_version}" != "v${meshdb_version}"', build_script)
    self.assertIn(
      "COPY --from=engine-builder /out/R1_MESHDB_VERSION "
      "/usr/share/r1-meshdb/VERSION",
      read("Dockerfile"),
    )
    workflows = read(".github/workflows/ci.yml") + read(".github/workflows/release.yml")
    self.assertEqual(workflows.count("/usr/share/r1-meshdb/VERSION"), 2)
    self.assertEqual(workflows.count("cmp VERSION"), 2)
    ci = read(".github/workflows/ci.yml")
    release = read(".github/workflows/release.yml")
    self.assertIn("Resolve CI build version", ci)
    self.assertIn("printf 'build_tag=v%s-ci.%s", ci)
    self.assertIn("RATIO1_VERSION=${{ steps.version.outputs.build_tag }}", ci)
    self.assertNotIn("RATIO1_VERSION=v1.0.0-ci.", ci)
    self.assertIn("python3 scripts/resolve-release-version.py", release)
    self.assertNotIn("v1\\.0\\.", read("scripts/inspect-ghcr-tag.sh"))
    self.assertNotIn("v1\\.0\\.", read("scripts/inspect-github-release.sh"))
    self.assertNotIn("v1\\.0\\.", read("scripts/verify-image.sh"))

  def test_release_runs_automatically_only_for_main_version_changes(self):
    release = read(".github/workflows/release.yml")
    self.assertRegex(
      release,
      r"on:\n  push:\n    branches:\n      - main\n    paths:\n      - VERSION\n  workflow_dispatch:\s*\n",
    )
    self.assertNotIn("inputs:", release.partition("concurrency:")[0])
    self.assertIn("github.event.before", release)
    self.assertIn("steps.version.outputs.release_tag", release)
    self.assertIn("queue: max", release)
    self.assertNotIn("inputs.release_tag", release)
    self.assertLess(
      release.index("Resolve and validate release version"),
      release.index("Build and publish the untagged release candidate"),
    )

  def test_repository_identity_is_r1_meshdb_everywhere(self):
    repository = "Ratio1/r1-meshdb"
    source_url = f"https://github.com/{repository}"
    old_slug = "r1-" + "distributed-sql"
    old_repository = f"Ratio1/{old_slug}"
    tracked_hits = subprocess.run(
      ["git", "grep", "-l", "-e", old_repository, "-e", old_slug],
      cwd=ROOT,
      check=False,
      capture_output=True,
      text=True,
    ).stdout.splitlines()
    self.assertEqual(tracked_hits, [], f"stale repository identity: {tracked_hits}")

    release = read(".github/workflows/release.yml")
    self.assertIn(f"public_remote='{source_url}.git'", release)
    self.assertIn(f'"{source_url}/archive/${{GITHUB_SHA}}.tar.gz"', release)
    self.assertIn(f"repos/{repository}/releases/tags/%s", read("scripts/inspect-github-release.sh"))

    dockerfile = read("Dockerfile")
    self.assertIn(f'org.opencontainers.image.url="{source_url}"', dockerfile)
    self.assertIn(f'org.opencontainers.image.source="{source_url}"', dockerfile)
    self.assertIn(
      f'org.opencontainers.image.documentation="{source_url}/blob/main/README.md"',
      dockerfile,
    )

    verifier = read("scripts/verify-image.sh")
    self.assertIn(
      f'expected_identity="{source_url}/.github/workflows/release.yml@refs/heads/main"',
      verifier,
    )
    self.assertIn(f'--repo {repository}', verifier)
    self.assertIn(f'"org.opencontainers.image.source": "{source_url}"', verifier)

    self.assertIn(f'APPLICATION_SOURCE = "{source_url}"', read("scripts/augment-sbom.py"))
    self.assertIn(f'APPLICATION_SOURCE = "{source_url}"', read("scripts/verify-sbom.py"))
    self.assertIn(
      f'baseline_repository != "{source_url}.git"',
      read("scripts/verify-provenance.py"),
    )
    self.assertEqual(json.loads(read("security/openvex.json"))["@id"], f"{source_url}/security/vex/2")
    self.assertEqual(
      json.loads(read("source/ratio1-engine-overrides.json"))["dependencySnapshot"]
      ["sourceBaseline"]["repository"],
      f"{source_url}.git",
    )
    for path in (
      "engine/pkg/build/info.go",
      "engine/pkg/kv/kvclient/kvcoord/txn_coord_sender.go",
      "engine/pkg/util/log/clog.go",
    ):
      self.assertIn(f"{source_url}/issues/new", read(path))

  def test_queued_push_release_remains_valid_after_main_advances(self):
    release = read(".github/workflows/release.yml")
    self.assertIn('if [[ "$EVENT_NAME" == "push" ]]; then', release)
    self.assertIn('git merge-base --is-ancestor "$GITHUB_SHA" origin/main', release)
    self.assertIn('[[ "$(git rev-parse origin/main)" == "$GITHUB_SHA" ]]', release)
    self.assertIn('[[ "$public_sha" == "$(git rev-parse origin/main)" ]]', release)
    self.assertNotIn('[[ "$public_sha" == "$GITHUB_SHA" ]]', release)

  def test_release_reruns_verify_source_tag_and_published_image_reference(self):
    release = read(".github/workflows/release.yml")
    self.assertIn("Verify the created source tag", release)
    self.assertIn("Verify published release immutability", release)
    published = release[release.index("Verify published release immutability"):]
    self.assertIn("gh release download", published)
    self.assertIn("--pattern image-reference.txt", published)
    self.assertIn('cmp image-reference.txt "$downloaded/image-reference.txt"', published)

  def test_draft_release_tag_creation_is_explicit_and_resumable(self):
    release = read(".github/workflows/release.yml")
    source_preflight = release[
      release.index("      - name: Validate immutable source release identity"):
      release.index("      - name: Prepare pristine source snapshot")
    ]
    self.assertIn(
      '[[ "$release_state" == "draft" && "$tag_exists" != "true" ]]',
      source_preflight,
    )
    self.assertNotIn(
      'if [[ "$release_state" != "missing" && "$tag_exists" != "true" ]]',
      source_preflight,
    )

    preflight = release[
      release.index("      - name: Preflight resumable immutable release identifiers"):
      release.index("      - name: Verify published release immutability")
    ]
    self.assertIn("--json targetCommitish", preflight)
    self.assertIn('[[ "$release_target" == "$GITHUB_SHA" ]]', preflight)
    self.assertIn('repos/$GITHUB_REPOSITORY/git/refs', preflight)
    self.assertIn('-f ref="refs/tags/$RELEASE_TAG"', preflight)
    self.assertIn('-f sha="$GITHUB_SHA"', preflight)

    create = release[
      release.index("      - name: Prepare draft release and immutable source tag"):
      release.index("      - name: Verify the created source tag")
    ]
    self.assertLess(create.index("gh release create"), create.index("git/refs"))
    self.assertIn('-f ref="refs/tags/$RELEASE_TAG"', create)
    self.assertIn('-f sha="$GITHUB_SHA"', create)

  def test_engine_identity_support_and_telemetry_defaults_are_meshdb_owned(self):
    self.assertIn('return fmt.Sprintf("R1 MeshDB %s %s', read("engine/pkg/build/info.go"))
    self.assertIn('"Name":         "R1 MeshDB"', read("engine/pkg/sql/crdb_internal.go"))
    self.assertIn('semconv.ServiceNameKey.String("R1 MeshDB")', read("engine/pkg/util/tracing/tracer.go"))
    diagnostics = read("engine/pkg/server/diagnostics/diagnostics.go")
    self.assertIn("const defaultUpdatesURL = ``", diagnostics)
    self.assertIn("const defaultReportingURL = ``", diagnostics)
    self.assertIn("func parseOptionalURL(value string) (*url.URL, error)", diagnostics)
    self.assertNotIn("register.cockroachdb.com", diagnostics)
    self.assertIn("serverCfg.StartDiagnosticsReporting = false", read("engine/pkg/cli/flags.go"))
    self.assertIn(
      'EnvOrDefaultBool("COCKROACH_SKIP_ENABLING_DIAGNOSTIC_REPORTING", true)',
      read("engine/pkg/settings/cluster/cluster_settings.go"),
    )
    crash = read("engine/pkg/util/log/logcrash/crash_reporting.go")
    self.assertIn('EnvOrDefaultString("COCKROACH_CRASH_REPORTS", "")', crash)
    self.assertNotIn("errors.cockroachdb.com", crash)
    support = read("engine/pkg/util/log/clog.go")
    self.assertIn("Ratio1 maintainers", support)
    self.assertNotIn("support@cockroachlabs.com", support)

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
      "golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36",
    )
    dependencies = {item["name"]: item for item in provenance["nativeDependencies"]}
    self.assertEqual(set(dependencies), {"geos", "jemalloc", "libedit", "proj"})
    for dependency in dependencies.values():
      for key in ("sourceUrl", "commit", "treeSha256", "license", "licenseFile", "role"):
        self.assertTrue(dependency.get(key), f"native dependency is missing {key}: {dependency}")
    cloudflared = provenance["buildInputs"]["cloudflared"]
    self.assertEqual(cloudflared["commit"], "b4f47e2ab538ab6e31d3dc6adc5489455ad446de")
    self.assertEqual(
      cloudflared["sourceArchiveSha256"],
      "e897f2cdb6f63964bb7b5841df80087489a65ab9fda356ef48dd13202bba59c0",
    )
    self.assertEqual(
      cloudflared["binarySha256"],
      "77d66f9223e8ec418ef31613ee861e2e9067f6b2544ec93d185a2e468fcb2e47",
    )
    self.assertEqual(
      provenance["buildInputs"]["releaseTooling"],
      {
        "buildx": "v0.36.1",
        "buildkit": (
          "moby/buildkit:v0.32.2@sha256:"
          "28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8"
        ),
        "cosign": "v3.1.3",
        "gh": "v2.97.0",
        "syft": "v1.51.0",
        "trivy": "v0.73.0",
      },
    )

    overrides = json.loads(read("source/ratio1-engine-overrides.json"))
    self.assertEqual(overrides["upstreamCommit"], provenance["upstream"]["commit"])
    verifier = load_script("scripts/verify-provenance.py")
    self.assertEqual(
      {record["path"] for record in overrides["modifiedUpstreamFiles"]},
      verifier.EXPECTED_MODIFIED_FILES,
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
    self.assertIn("/cloudflared: go1.26.6", build_info)
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
    self.assertIn("CockroachDB Community License", boundary_script)
    self.assertIn("Cockroach Enterprise License", boundary_script)
    self.assertIn("CockroachDB Enterprise License", boundary_script)
    self.assertIn('b"pkg/ccl"', boundary_script)
    self.assertFalse((ROOT / "engine/.github").exists())

  def test_source_boundary_rejects_ccl_license_and_namespace_markers(self):
    verifier = load_script("scripts/verify-source-boundary.py")
    markers = (
      b"Cockroach Community License",
      b"CockroachDB Community License",
      b"Cockroach Enterprise License",
      b"CockroachDB Enterprise License",
      b"github.com/cockroachdb/cockroach/pkg/ccl/sqlproxyccl",
      b"pkg/ccl/changefeedccl",
    )
    with tempfile.TemporaryDirectory() as directory:
      fixture = Path(directory) / "source.go"
      for marker in markers:
        fixture.write_bytes(b"// " + marker + b"\n")
        with self.assertRaises(SystemExit):
          verifier.scan_source(fixture, "engine/pkg/fixture/source.go")

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
    self.assertEqual(by_path["engine/AUTHORS"], "Apache-2.0")
    self.assertEqual(
      hashlib.sha256((ROOT / "engine/AUTHORS").read_bytes()).hexdigest(),
      "43f782e23df565c0f003c45dae70b25788c6fc0266a87f8624a157b499a8aac8",
    )
    self.assertEqual(by_path["engine/c-deps/geos/COPYING"], "LGPL-2.1-only")
    tut_root = "engine/c-deps/geos/tests/unit/tut"
    tut_files = {
      path.relative_to(ROOT).as_posix()
      for path in (ROOT / tut_root).iterdir()
      if path.is_file()
    }
    self.assertTrue(tut_files)
    self.assertEqual({by_path[path] for path in tut_files}, {"BSD-2-Clause"})
    self.assertEqual(
      hashlib.sha256((ROOT / tut_root / "LICENSE").read_bytes()).hexdigest(),
      "c208bc4abd59b0885130cd47eb9b400480a0aeeb5f0a937d35d84393258ea6c3",
    )
    astyle_root = "engine/c-deps/geos/tools/astyle"
    astyle_mit_files = {
      "ASBeautifier.cpp", "ASEnhancer.cpp", "ASFormatter.cpp",
      "ASLocalizer.cpp", "ASLocalizer.h", "ASResource.cpp", "astyle.h",
      "astyle_main.cpp", "astyle_main.h",
    }
    self.assertEqual(
      {by_path[f"{astyle_root}/{filename}"] for filename in astyle_mit_files},
      {"MIT"},
    )
    for filename in ("tinyxml2.cpp", "tinyxml2.h"):
      self.assertEqual(
        by_path[f"engine/c-deps/geos/tests/xmltester/tinyxml2/{filename}"],
        "Zlib",
      )
    self.assertEqual(
      by_path["engine/c-deps/geos/debian/copyright"],
      "LGPL-2.0-or-later",
    )
    public_domain_paths = (
      "engine/c-deps/jemalloc/msvc/test_threads/test_threads.cpp",
      "engine/c-deps/proj/src/PJ_isea.c",
    )
    public_domain_refs = {by_path[path] for path in public_domain_paths}
    self.assertEqual(len(public_domain_refs), 2)
    for path in public_domain_paths:
      license_ref = by_path[path]
      self.assertRegex(
        license_ref,
        r"^LicenseRef-Public-Domain-Notice-[0-9a-f]{12}$",
      )
      self.assertEqual(
        license_ref.rsplit("-", 1)[1],
        hashlib.sha256((ROOT / path).read_bytes()).hexdigest()[:12],
      )
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
    dockerignore = read(".dockerignore")
    lowered = dockerfile.lower()
    self.assertNotIn("cockroachdb/builder", lowered)
    self.assertNotRegex(lowered, r"from\s+cockroachdb/")
    self.assertNotRegex(lowered, r"git\s+clone\s+[^\n]*cockroachdb/cockroach")
    self.assertNotRegex(lowered, r"\bmake\s+[^\n]*cockroach")
    self.assertRegex(dockerfile, r"FROM\s+[^\s]+@sha256:[0-9a-f]{64}")
    self.assertNotIn("perl -0pi", dockerfile)
    self.assertIn("GOPROXY=off", dockerfile)
    self.assertIn("snapshot.debian.org/archive/debian/20260812T000000Z", dockerfile)
    self.assertIn("autoconf=2.71-3", dockerfile)
    self.assertIn("bash=5.2.15-2+b13", dockerfile)
    self.assertIn("scripts/build-engine.sh", dockerfile)
    self.assertIn("scripts/verify-provenance.py", dockerfile)
    self.assertIn("go test -mod=vendor", dockerfile)
    self.assertIn("github.com/jackc/pgproto3/v2", dockerfile)
    self.assertIn("github.com/jackc/pgx/v4/internal/sanitize", dockerfile)
    self.assertIn("./pkg/util/ctxutil", dockerfile)
    self.assertIn("./pkg/util/goschedstats", dockerfile)
    self.assertIn("77d66f9223e8ec418ef31613ee861e2e9067f6b2544ec93d185a2e468fcb2e47", dockerfile)
    self.assertIn("ADD --checksum=sha256:e897f2cdb6f63964bb7b5841df80087489a65ab9fda356ef48dd13202bba59c0", dockerfile)
    self.assertNotRegex(lowered, r"from\s+cloudflare/cloudflared")
    self.assertIn("scripts/verify-cloudflared-source.py", dockerfile)
    self.assertIn("ARG BUILD_JOBS=4", dockerfile)
    self.assertIn("ENTRYPOINT [\"/usr/local/bin/deeploy-crdb-entrypoint\"]", dockerfile)
    self.assertIn("source/manifest.sha256", dockerfile)
    self.assertIn("generate-source-manifest.py --check", dockerfile)
    self.assertRegex(dockerfile, r"(?m)^FROM scratch$")
    self.assertIn("scripts/assemble-runtime-rootfs.sh", dockerfile)
    self.assertIn("source/runtime-packages.txt", dockerfile)
    self.assertIn("/usr/bin/seq", read("scripts/assemble-runtime-rootfs.sh"))
    self.assertIn("source-snapshot", dockerignore.splitlines())

  def test_ci_verifies_ratio1_overrides_against_exact_upstream_source(self):
    for workflow in (".github/workflows/ci.yml", ".github/workflows/release.yml"):
      text = read(workflow)
      self.assertIn("verify-upstream-provenance.sh", text)
    verifier = read("scripts/verify-upstream-provenance.sh")
    self.assertIn("76e598c9b1c100fd9280b979140b5e377c330a20", verifier)
    self.assertIn("https://github.com/cockroachdb/cockroach.git", verifier)
    self.assertIn("--native-upstream", verifier)
    self.assertIn("tests/generated-source/Dockerfile", verifier)
    validator = read("tests/generated-source/Dockerfile")
    self.assertIn("golang:1.19.10-bullseye@sha256:", validator)
    self.assertIn("08defd390a65f3a72cfde1d04a538c6dc2d48d1f0f443ff99a8862c11c19572c", validator)
    self.assertNotIn("cockroachdb/builder", validator)
    self.assertIn("make -j4 vendor/modules.txt", verifier)
    self.assertIn("make -j4 protobuf", verifier)
    self.assertNotIn("//pkg/gen:code", verifier)
    self.assertIn("verify-generated-provenance.py", verifier)

  def test_ci_proves_oss_and_release_supply_chain(self):
    workflows = list((ROOT / ".github/workflows").glob("*.yml"))
    self.assertTrue(workflows)
    workflow_text = "\n".join(path.read_text(encoding="utf-8") for path in workflows)
    for workflow in (".github/workflows/ci.yml", ".github/workflows/release.yml"):
      self.assertIn(
        "python3 -m unittest tests.test_release_contract tests.test_sbom_contract",
        read(workflow),
      )
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
    self.assertIn('[[ "$(git rev-parse origin/main)" == "$GITHUB_SHA" ]]', workflow_text)
    self.assertIn("platforms: linux/amd64", workflow_text)
    self.assertIn("image-reference.txt", read(".github/workflows/security.yml"))
    self.assertNotIn("r1-meshdb:latest", read(".github/workflows/security.yml"))
    verifier = read("scripts/verify-image.sh")
    self.assertIn('DOCKER_CONFIG="${anonymous_config}" docker pull', verifier)
    self.assertNotIn("docker logout ghcr.io", verifier)
    self.assertIn(
      "skip-dirs: engine/pkg/security/securitytest/test_certs",
      read(".github/workflows/security.yml"),
    )
    self.assertNotIn("ignore-unfixed", workflow_text)
    self.assertIn("testbed/run-local-cluster.sh", read(".github/workflows/ci.yml"))
    self.assertIn("testbed/run-local-cluster.sh", read(".github/workflows/release.yml"))
    self.assertIn("testbed/run-rolling-upgrade.sh", read(".github/workflows/ci.yml"))
    self.assertIn("testbed/run-rolling-upgrade.sh", read(".github/workflows/release.yml"))
    self.assertIn("testbed/run-real-cloudflare-cluster.sh", read(".github/workflows/release.yml"))
    self.assertIn("scripts/runtime-supervision-smoke.sh", read(".github/workflows/ci.yml"))
    self.assertIn("scripts/runtime-supervision-smoke.sh", read(".github/workflows/release.yml"))
    self.assertEqual(read(".github/workflows/ci.yml").count("path: source-snapshot"), 2)
    for secret in ("CF_ACCOUNT_ID", "CF_ZONE_ID", "CF_API_TOKEN", "CF_BASE_DOMAIN"):
      self.assertIn("${{ secrets." + secret + " }}", read(".github/workflows/release.yml"))
    release = read(".github/workflows/release.yml")
    self.assertIn("workflow_dispatch:", release)
    self.assertNotIn("push:\n    tags:", release)
    self.assertLess(release.index("cosign sign"), release.index("imagetools create"))
    self.assertLess(release.index("cosign verify"), release.index("imagetools create"))
    self.assertIn("imagetools create --prefer-index=false", release)
    self.assertIn("push-by-digest=true", release)
    self.assertIn("verify-vendor-provenance.go", release)
    self.assertIn("scripts/validate-sbom-schema.py", release)
    self.assertIn("path: source-snapshot", release)
    self.assertIn("if: always()", release)
    self.assertEqual(
      release.count("uses: docker/build-push-action@"),
      1,
      "release must build the candidate exactly once",
    )
    self.assertNotIn("load: true", release)
    self.assertLess(
      release.index("push-by-digest=true"),
      release.index("Record raw candidate findings"),
    )
    self.assertNotIn("Build and publish image tags", release)
    self.assertNotIn('"sha-${GITHUB_SHA}"', release)
    self.assertNotIn("--field visibility=public", release)
    self.assertIn('DOCKER_CONFIG="$anonymous_config" docker pull', release)
    self.assertNotIn("docker logout ghcr.io", release)
    self.assertIn("Preflight resumable immutable release identifiers", release)
    self.assertGreaterEqual(release.count("scripts/inspect-ghcr-tag.sh"), 2)
    self.assertIn('scripts/inspect-github-release.sh "$RELEASE_TAG"', release)
    self.assertIn('case "$tag_status" in', release)
    self.assertIn('could not determine whether source tag exists', release)
    self.assertIn('missing|draft|published)', release)
    self.assertIn('invalid GitHub release state', release)
    self.assertIn("image_tag_exists=true", release)
    self.assertIn("existing source tag does not identify this release commit", release)
    self.assertIn("immutable image tag identifies a different digest", release)
    self.assertIn("Refresh and verify resumable draft release assets", release)
    self.assertIn("gh release upload", release)
    self.assertIn("--clobber", release)
    self.assertIn("gh release download", release)
    self.assertIn("gh release view", release)
    self.assertIn("--json assets", release)
    self.assertIn(".assets[].name", release)
    self.assertIn('cmp "$downloaded/expected-assets.txt" "$downloaded/actual-assets.txt"', release)
    self.assertLess(
      release.index("Refresh and verify resumable draft release assets"),
      release.index("Promote the single immutable version tag"),
    )
    self.assertLess(
      release.index("Prove public anonymous pull before tag promotion"),
      release.index("Prepare draft release and immutable source tag"),
    )
    self.assertLess(
      release.index("Prove corresponding source is anonymously available"),
      release.index("Build and publish the untagged release candidate"),
    )
    self.assertIn(
      'diff --no-dereference --recursive source-snapshot "$extracted"',
      release,
    )
    self.assertNotIn('cmp "$path" "$extracted/$path"', release)
    self.assertLess(
      release.index("Prepare draft release and immutable source tag"),
      release.index("Promote the single immutable version tag"),
    )
    self.assertLess(
      release.index("Promote the single immutable version tag"),
      release.index("Publish the validated release"),
    )
    self.assertLess(
      release.index("Publish the validated release"),
      release.index("Update latest only after release publication"),
    )
    floating = []
    for path in workflows:
      for line in path.read_text(encoding="utf-8").splitlines():
        match = re.search(r"\buses:\s*([^\s]+)@([^\s#]+)", line)
        if match and not re.fullmatch(r"[0-9a-f]{40}", match.group(2)):
          floating.append(f"{path.name}: {line.strip()}")
    self.assertEqual(floating, [], f"workflow actions must be commit-pinned: {floating}")

  def test_published_image_verifier_binds_release_source_and_binary(self):
    verifier = read("scripts/verify-image.sh")
    for required in (
      "gh release view",
      "gh release download",
      "image-reference.txt",
      "ls-remote",
      "--source-digest",
      'Build Tag:        ${release_tag}',
      "org.opencontainers.image.revision",
      "org.opencontainers.image.version",
    ):
      self.assertIn(required, verifier)

  def test_cosign_v3_uses_bundle_aware_installer(self):
    installer = (
      "sigstore/cosign-installer@"
      "6f9f17788090df1f26f669e9d70d6ae9567deba6"
    )
    for workflow_path in (
      ".github/workflows/release.yml",
      ".github/workflows/security.yml",
    ):
      workflow = read(workflow_path)
      self.assertIn(f"uses: {installer}", workflow)
      self.assertIn("cosign-release: v3.1.3", workflow)
      self.assertNotIn(
        "sigstore/cosign-installer@398d4b0eeef1380460a10c8013a76f728fb906ac",
        workflow,
      )

  def test_release_attestation_verification_has_scoped_github_token(self):
    release = read(".github/workflows/release.yml")
    signing_step = release[
      release.index("      - name: Sign and verify the exact digest"):
      release.index("      - name: Prove public anonymous pull before tag promotion")
    ]
    self.assertIn("GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}", signing_step)
    self.assertIn("gh attestation verify", signing_step)

  def test_ghcr_tag_inspection_fails_closed(self):
    fake_curl = r'''#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
if [[ "${config}" == *'/token?'* ]]; then
  printf '{"token":"fixture-registry-token"}\n'
  exit 0
fi
if [[ "${FAKE_CURL_TRANSPORT_FAILURE:-false}" == "true" ]]; then
  exit 7
fi
headers="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' <<< "${config}")"
if [[ "${FAKE_REGISTRY_STATUS}" == "200" ]]; then
  printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "${FAKE_REGISTRY_DIGEST}" > "${headers}"
else
  printf 'HTTP/2 %s\r\n\r\n' "${FAKE_REGISTRY_STATUS}" > "${headers}"
fi
printf '%s' "${FAKE_REGISTRY_STATUS}"
'''
    digest = "sha256:" + "a" * 64
    with tempfile.TemporaryDirectory() as directory:
      fake_bin = Path(directory)
      curl = fake_bin / "curl"
      curl.write_text(fake_curl, encoding="utf-8")
      curl.chmod(0o755)
      environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "GHCR_USERNAME": "fixture-user",
        "GHCR_TOKEN": "fixture-token",
        "FAKE_REGISTRY_DIGEST": digest,
      }
      command = [
        "bash", "scripts/inspect-ghcr-tag.sh",
        "ghcr.io/ratio1/r1-meshdb:v1.0.0",
      ]
      for status, expected_code, expected_output in (
        ("200", 0, digest),
        ("404", 0, "absent"),
        ("500", 1, ""),
      ):
        result = subprocess.run(
          command,
          cwd=ROOT,
          env={**environment, "FAKE_REGISTRY_STATUS": status},
          text=True,
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, expected_code, result.stderr)
        self.assertEqual(result.stdout.strip(), expected_output)
      result = subprocess.run(
        command,
        cwd=ROOT,
        env={
          **environment,
          "FAKE_REGISTRY_STATUS": "200",
          "FAKE_CURL_TRANSPORT_FAILURE": "true",
        },
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
      )
      self.assertNotEqual(result.returncode, 0)

  def test_github_release_inspection_fails_closed(self):
    fake_curl = r'''#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
if [[ "${FAKE_CURL_TRANSPORT_FAILURE:-false}" == "true" ]]; then
  exit 7
fi
output="$(sed -n 's/^output = "\(.*\)"$/\1/p' <<< "${config}")"
if [[ "${FAKE_GITHUB_STATUS}" == "200" ]]; then
  printf '{"tag_name":"%s","draft":%s}\n' \
    "${FAKE_GITHUB_TAG}" "${FAKE_GITHUB_DRAFT}" > "${output}"
else
  printf '{"message":"fixture"}\n' > "${output}"
fi
printf '%s' "${FAKE_GITHUB_STATUS}"
'''
    tag = "v1.0.0"
    with tempfile.TemporaryDirectory() as directory:
      fake_bin = Path(directory)
      curl = fake_bin / "curl"
      curl.write_text(fake_curl, encoding="utf-8")
      curl.chmod(0o755)
      environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "GH_TOKEN": "fixture-token",
        "FAKE_GITHUB_TAG": tag,
        "FAKE_GITHUB_DRAFT": "false",
      }
      command = ["bash", "scripts/inspect-github-release.sh", tag]
      for status, draft, expected_code, expected_output in (
        ("200", "true", 0, "draft"),
        ("200", "false", 0, "published"),
        ("404", "false", 0, "missing"),
        ("500", "false", 1, ""),
      ):
        result = subprocess.run(
          command,
          cwd=ROOT,
          env={
            **environment,
            "FAKE_GITHUB_STATUS": status,
            "FAKE_GITHUB_DRAFT": draft,
          },
          text=True,
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, expected_code, result.stderr)
        self.assertEqual(result.stdout.strip(), expected_output)
      result = subprocess.run(
        command,
        cwd=ROOT,
        env={
          **environment,
          "FAKE_GITHUB_STATUS": "200",
          "FAKE_CURL_TRANSPORT_FAILURE": "true",
        },
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
      )
      self.assertNotEqual(result.returncode, 0)
      for environment_override in (
        {"FAKE_GITHUB_STATUS": "200", "FAKE_GITHUB_TAG": "v1.0.9"},
        {"FAKE_GITHUB_STATUS": "200", "FAKE_GITHUB_DRAFT": "null"},
      ):
        result = subprocess.run(
          command,
          cwd=ROOT,
          env={**environment, **environment_override},
          text=True,
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)

  def test_scheduled_vex_scan_uses_the_release_revision(self):
    workflow = read(".github/workflows/security.yml")
    self.assertIn('git checkout --detach "${tag_commit}"', workflow)
    self.assertLess(
      workflow.index('git checkout --detach "${tag_commit}"'),
      workflow.index("python3 scripts/verify-security-vex.py"),
    )
    self.assertLess(
      workflow.index('git checkout --detach "${tag_commit}"'),
      workflow.index("TRIVY_VEX: security/openvex.json"),
    )

  def test_runtime_supervision_overlay_is_scratch_compatible(self):
    dockerfile = read("tests/runtime-supervision/Dockerfile")
    self.assertNotIn("apt-get", dockerfile)
    self.assertNotRegex(
      dockerfile.split("FROM ${BASE_IMAGE} AS candidate", 1)[1],
      r"(?m)^RUN\s",
    )
    self.assertNotIn("/bin/mv", dockerfile)
    self.assertIn("/cockroach/cockroach-real", dockerfile)
    self.assertIn("r1-test-tcp-proxy", dockerfile)
    for utility in ("cp", "cut", "dd", "od", "readlink", "sed", "touch", "wc"):
      self.assertIn(f"/usr/bin/{utility}", dockerfile)
    self.assertNotIn("socat", read("tests/runtime-supervision/cockroach-test-wrapper.sh"))
    self.assertNotIn("socat", read("tests/runtime-supervision/cloudflared-test-stub.sh"))
    for wrapper in ("rm", "df", "sync"):
      wrapper_text = read(f"tests/runtime-supervision/{wrapper}-test-stub.sh")
      self.assertIn(f"exec /usr/bin/{wrapper}", wrapper_text)
      self.assertNotIn(f"exec /bin/{wrapper}", wrapper_text)
    self.assertNotRegex(
      read("tests/runtime-supervision/cockroach-test-wrapper.sh"),
      r"(?m)^\s*mv\s",
    )
    self.assertIn(
      "-e TEST_CRDB_START_MODE=listen_block",
      read("scripts/runtime-supervision-smoke.sh"),
    )
    supervision = read("scripts/runtime-supervision-smoke.sh")
    self.assertEqual(
      supervision.count("-e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=30"),
      5,
      "only process-observation cases should receive the wider local harness budget",
    )
    self.assertIn(
      'start_case "${timeout_case}" -e TEST_CRDB_INIT_MODE=block',
      supervision,
    )
    self.assertIn(
      'assert_failed_cleanly "${resistant_timeout_case}" "initializing R1 MeshDB cluster if needed" 137 30',
      supervision,
    )
    self.assertNotIn(
      'wait_for_command "${timeout_case}" "/cockroach/cockroach init "',
      supervision,
    )
    self.assertNotIn(
      'wait_for_command "${sql_timeout_case}" "/cockroach/cockroach sql "',
      supervision,
    )
    self.assertNotIn(
      'wait_for_file "${ddl_timeout_case}" /tmp/runtime-supervision-readiness-complete',
      supervision,
    )
    recovery = read("scripts/store-recovery-regression.sh")
    self.assertIn(
      'CRDB_TEST_RECOVERY_HANDLER_TIMEOUT_SECONDS:-10',
      recovery,
    )
    self.assertIn('timeout_elapsed_ms="$(marker_elapsed_millis', recovery)
    self.assertIn('startup_scan_timeout_elapsed_ms="$(marker_elapsed_millis', recovery)
    self.assertNotRegex(recovery, r"(?m)^timeout_started_ms=")
    self.assertNotRegex(recovery, r"(?m)^startup_scan_timeout_started_ms=")
    self.assertIn("TEST_DF_BLOCK_STARTED_FILE", recovery)
    self.assertIn("TEST_DF_BLOCK_TERM_FILE", recovery)
    self.assertIn("TEST_TAIL_BLOCK_STARTED_FILE", recovery)
    self.assertIn("TEST_TAIL_BLOCK_TERM_FILE", recovery)
    self.assertIn("TEST_CLOUDFLARED_ACCESS_BLOCK_STARTED_FILE", supervision)
    self.assertIn("TEST_CLOUDFLARED_ACCESS_BLOCK_TERM_FILE", supervision)
    self.assertNotIn("peer_listener_timeout_overall_elapsed_ms", supervision)
    self.assertIn(
      "TEST_CLOUDFLARED_ACCESS_BLOCK_STARTED_FILE",
      read("tests/runtime-supervision/cloudflared-test-stub.sh"),
    )
    self.assertIn(
      "TEST_DF_BLOCK_STARTED_FILE",
      read("tests/runtime-supervision/df-test-stub.sh"),
    )
    self.assertIn(
      'chmod 644 "${path}"',
      read("tests/runtime-supervision/df-test-stub.sh"),
    )
    self.assertIn('real_fixture_volume="deeploy-crdb-real-corrupt-fixture-', recovery)
    self.assertIn('docker volume create --label "${test_label}"', recovery)
    self.assertIn('-v "${real_fixture_volume}:/store"', recovery)
    self.assertIn('echo "real corrupt-store fixture workload failed"', recovery)
    self.assertIn("for batch_start in $(seq 1 1000 19001)", recovery)
    self.assertIn("timeout --signal=TERM --kill-after=10s 5m", recovery)
    self.assertNotIn("generate_series(1, 20000)", recovery)
    self.assertIn("debug compact /store", recovery)
    self.assertIn("debug pebble sstable layout", recovery)
    self.assertIn("debug pebble sstable check", recovery)
    self.assertIn("fixture_corruption_offset=$((fixture_data_start + fixture_data_size / 2))", recovery)
    self.assertIn("crdb_internal.compact_engine_span", recovery)
    self.assertIn("IFS=, read -r fixture_node_id fixture_store_id", recovery)
    self.assertNotIn(") FROM crdb_internal.kv_store_status", recovery)
    self.assertNotIn("seek=100000", recovery)
    self.assertIn(
      "TEST_TAIL_BLOCK_STARTED_FILE",
      read("tests/runtime-supervision/tail-test-stub.sh"),
    )
    self.assertRegex(
      recovery,
      r'(?s)create_case "\$\{client_case\}".*?TEST_CRDB_START_MODE=listen_block.*?'
      r'TEST_CRDB_INIT_MODE=corruption_exit',
    )

  def test_cloudflare_cleanup_preserves_non_secret_recovery_state(self):
    testbed = read("testbed/run-real-cloudflare-cluster.sh")
    self.assertIn("cloudflare-cleanup-state.json", testbed)
    self.assertIn("find \"${allocation_dir}\" -maxdepth 1 -name '*.token' -delete", testbed)
    self.assertIn("cleanup state preserved", testbed)

    heredocs = re.findall(r"<<'PY'\n(.*?)\nPY(?:\n|$)", testbed, flags=re.DOTALL)
    self.assertTrue(heredocs)
    for index, source in enumerate(heredocs, start=1):
      compile(source, f"run-real-cloudflare-cluster.sh:heredoc-{index}", "exec")

    function = re.search(
      r"(?ms)^preserve_cleanup_state\(\) \{\n.*?^\}",
      testbed,
    )
    self.assertIsNotNone(function)
    with tempfile.TemporaryDirectory() as tmp:
      allocation = Path(tmp) / "allocation"
      evidence = Path(tmp) / "evidence"
      allocation.mkdir()
      (allocation / "state.json").write_text('{"schemaVersion": 1}\n', encoding="utf-8")
      (allocation / "node-1.token").write_text("secret-token", encoding="utf-8")
      subprocess.run(
        [
          "bash",
          "-c",
          "set -euo pipefail\n"
          "allocation_dir=$1\n"
          "evidence_dir=$2\n"
          f"{function.group(0)}\n"
          "preserve_cleanup_state\n",
          "bash",
          str(allocation),
          str(evidence),
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
      )
      preserved = evidence / "cloudflare-cleanup-state.json"
      self.assertEqual(preserved.read_text(encoding="utf-8"), '{"schemaVersion": 1}\n')
      self.assertEqual(preserved.stat().st_mode & 0o777, 0o600)
      self.assertFalse((allocation / "node-1.token").exists())

    self.assertIn('run_id="${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"', testbed)
    self.assertNotIn('${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}', testbed)
    self.assertNotIn('prefix="${prefix:0:40}"', testbed)

  def test_failed_release_has_exact_attempt_cloudflare_recovery(self):
    release = read(".github/workflows/release.yml")
    cleanup = read(".github/workflows/cloudflare-cleanup.yml")
    runbook = read("RELEASE.md")

    self.assertIn("${{ github.run_id }}-${{ github.run_attempt }}", release)
    self.assertIn("workflow_run:", cleanup)
    self.assertIn("workflows: [Release signed image]", cleanup)
    self.assertIn("workflow_dispatch:", cleanup)
    self.assertIn("run_id:", cleanup)
    self.assertIn("run_attempt:", cleanup)
    self.assertIn("environment: release", cleanup)
    self.assertIn("actions: read", cleanup)
    self.assertIn("contents: read", cleanup)
    self.assertNotIn("packages: write", cleanup)
    self.assertNotIn("contents: write", cleanup)
    self.assertNotIn("id-token: write", cleanup)
    self.assertIn("scripts/cloudflare_cleanup_recovery.py", cleanup)
    self.assertIn("cleanup-prefix", cleanup)
    self.assertIn("github.event.workflow_run.id", cleanup)
    self.assertIn("github.event.workflow_run.run_attempt", cleanup)
    for secret in ("CF_ACCOUNT_ID", "CF_ZONE_ID", "CF_API_TOKEN", "CF_BASE_DOMAIN"):
      self.assertIn("${{ secrets." + secret + " }}", cleanup)
    self.assertIn("Cloudflare cleanup recovery", runbook)
    self.assertRegex(runbook, r"Recover\s+ephemeral Cloudflare resources")
    self.assertIn("run ID", runbook)
    self.assertIn("run attempt", runbook)
    self.assertIn("seven days", runbook)
    self.assertNotIn("in the release evidence", runbook)
    self.assertNotIn("cloudflare_ephemeral_tunnels.py cleanup", runbook)

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
      "tests/local-transport/tcp-proxy.go",
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
    self.assertIn("password_cleanup_complete=false", testbed)
    self.assertIn("password_cleanup_deadline=$((SECONDS + 30))", testbed)
    self.assertIn("while true; do", testbed)
    self.assertIn(
      'if ! password_file="$(find /tmp -xdev -type f -name database-password -print -quit)"; then',
      testbed,
    )
    self.assertIn("database bootstrap password cleanup scan failed", testbed)
    self.assertIn("database bootstrap password file was not removed after bounded wait", testbed)
    self.assertIn('if ! certificate_file="$(find /tmp -xdev -type f', testbed)
    self.assertIn("staged certificate cleanup scan failed", testbed)
    self.assertIn('if [[ -n "$certificate_file" ]]; then', testbed)
    direct_test = read("scripts/direct-engine-three-node-smoke.sh")
    self.assertIn("--max-offset=500ms", direct_test)
    self.assertIn("generate_series(1, 10000)", direct_test)
    self.assertIn("array_length(voting_replicas, 1) < 3", direct_test)
    self.assertIn("array_length(learner_replicas, 1) > 0", direct_test)
    self.assertNotIn("ranges.underreplicated", direct_test)
    self.assertIn("timeout --kill-after=2s 20s", direct_test)
    self.assertIn("timeout --kill-after=2s 20s", testbed)
    entrypoint = read("entrypoint.sh")
    self.assertIn("GRPC_ENFORCE_ALPN_ENABLED=false", entrypoint)
    self.assertIn("export GRPC_ENFORCE_ALPN_ENABLED", entrypoint)
    for script in (
      direct_test,
      testbed,
      read("testbed/run-rolling-upgrade.sh"),
      read("testbed/run-real-cloudflare-cluster.sh"),
    ):
      self.assertIn("docker volume create", script)
      self.assertIn("docker volume rm", script)
    local_runner = read("testbed/run-local-cluster.sh")
    self.assertIn("base_binary_hash", local_runner)
    self.assertIn("base_entrypoint_hash", local_runner)
    local_transport = read("tests/local-transport/Dockerfile")
    self.assertNotIn("apt-get", local_transport)
    self.assertIn("r1-test-tcp-proxy", local_transport)

  def test_process_environment_scans_tolerate_process_exit(self):
    guarded_read = 'if ! values="$(tr "\\000" "\\n" 2>/dev/null < "$environment")"; then'
    for path in (
      "scripts/entrypoint-multinode-smoke.sh",
      "testbed/run-rolling-upgrade.sh",
      "testbed/run-real-cloudflare-cluster.sh",
    ):
      script = read(path)
      self.assertIn(guarded_read, script, path)
      self.assertIn('if [[ -e "$environment" ]]; then', script, path)
      self.assertIn("process environment scan failed", script, path)
      self.assertNotIn('[[ -r "$environment" ]] || continue', script, path)

  def test_real_cloudflare_replication_wait_is_bounded_and_diagnostic(self):
    testbed = read("testbed/run-real-cloudflare-cluster.sh")
    replication_start = testbed.index("replication_ready=false")
    replication_end = testbed.index(
      'count="$(docker exec -e "PGPASSWORD=${db_password}"',
      replication_start,
    )
    replication_block = testbed[replication_start:replication_end]
    self.assertIn("replication_deadline=$(( $(date +%s) + 600 ))", testbed)
    self.assertIn('replication_incomplete="not-started"', testbed)
    self.assertIn("printf 'replication_incomplete=%s\\n'", testbed)
    self.assertIn("replication-query.err", testbed)
    self.assertIn("range replication diagnostics", testbed)
    self.assertIn("/cockroach/cockroach-data/logs", testbed)
    self.assertIn('docker exec "${nodes[0]}"', replication_block)
    self.assertIn("--host=roach1:26257", replication_block)
    self.assertNotIn('${nodes[1]}', replication_block)
    self.assertNotIn("--host=roach2:26257", replication_block)
    self.assertIn('replication_incomplete="query-error"\n    break', replication_block)

  def test_generated_parser_outputs_are_declared(self):
    generated = set(read("source/generated-files.txt").splitlines())
    self.assertIn("pkg/sql/parser/sql.go", generated)
    self.assertIn("pkg/sql/plpgsql/parser/plpgsql.go", generated)

  def test_declared_source_changes_have_in_file_license_notices(self):
    overrides = json.loads(read("source/ratio1-engine-overrides.json"))
    notice = "Modified by Ratio1 in 2026; see RATIO1_PATCHES.md."
    for record in overrides["modifiedUpstreamFiles"]:
      self.assertIn(notice, read(record["path"]), record["path"])
    for backport in overrides["dependencyCompatibilityBackports"]:
      for record in backport["files"]:
        self.assertIn(notice, read(record["path"]), record["path"])
    for backport in overrides["securityBackports"]:
      for record in backport["files"]:
        content = read(record["path"])
        if record["changeType"] == "modified-upstream":
          self.assertIn(notice, content, record["path"])
        else:
          self.assertIn("Copyright 2026 Ratio1", content, record["path"])
          self.assertIn("Licensed under the Apache License, Version 2.0", content, record["path"])

  def test_minimal_runtime_excludes_unneeded_vulnerable_tools(self):
    packages = {line.split("=", 1)[0] for line in read("source/runtime-packages.txt").splitlines()}
    self.assertTrue({"util-linux", "libtinfo6"} <= packages)
    self.assertFalse({
      "gzip", "libacl1", "libattr1", "libblkid1", "libmount1", "mount",
      "ncurses-bin", "perl-base", "zlib1g",
    } & packages)
    assembler = read("scripts/assemble-runtime-rootfs.sh")
    for path in ("/usr/bin/blkid", "/usr/bin/findmnt", "/usr/bin/infocmp", "/usr/bin/mount", "/usr/bin/mv"):
      self.assertNotIn(path, assembler)
    self.assertIn("r1-atomic-replace", read("entrypoint.sh"))
    self.assertIn("r1-atomic-replace", read("Dockerfile"))


if __name__ == "__main__":
  unittest.main()
