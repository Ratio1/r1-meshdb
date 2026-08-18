#!/usr/bin/env python3
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts.cloudflare_cleanup_recovery import RecoveryError, resolve_cleanup_run


REPOSITORY = "Ratio1/r1-meshdb"
RUN_ID = 12345
ATTEMPT = 2
STEP_NAME = "Run unchanged candidate through real ephemeral Cloudflare tunnels"


def source_run(**overrides):
  value = {
    "id": RUN_ID,
    "path": ".github/workflows/release.yml",
    "event": "workflow_dispatch",
    "head_branch": "main",
    "head_repository": {"full_name": REPOSITORY},
    "repository": {"full_name": REPOSITORY},
    "status": "completed",
    "conclusion": "failure",
    "run_attempt": ATTEMPT,
  }
  value.update(overrides)
  return value


def source_jobs(step_conclusion="failure", job_conclusion="failure"):
  return {
    "total_count": 1,
    "jobs": [{
      "name": "release",
      "status": "completed",
      "conclusion": job_conclusion,
      "steps": [{
        "name": STEP_NAME,
        "status": "completed",
        "conclusion": step_conclusion,
      }],
    }],
  }


class CloudflareCleanupRecoveryTests(unittest.TestCase):
  def test_resolves_automatic_main_push_release(self):
    result = resolve_cleanup_run(
      source_run(event="push"), source_jobs(), REPOSITORY, str(RUN_ID), str(ATTEMPT)
    )
    self.assertTrue(result["cleanupNeeded"])

  def test_resolves_exact_failed_attempt(self):
    result = resolve_cleanup_run(
      source_run(), source_jobs(), REPOSITORY, str(RUN_ID), str(ATTEMPT)
    )
    self.assertEqual(result["runId"], RUN_ID)
    self.assertEqual(result["runAttempt"], ATTEMPT)
    self.assertEqual(result["prefix"], "r1-meshdb-ci-12345-2")
    self.assertEqual(
      result["artifactPattern"],
      "r1-meshdb-cloudflare-cleanup-12345-2",
    )
    self.assertTrue(result["cleanupNeeded"])

  def test_omitted_attempt_selects_latest_completed_attempt(self):
    result = resolve_cleanup_run(source_run(), source_jobs(), REPOSITORY, str(RUN_ID), None)
    self.assertEqual(result["runAttempt"], ATTEMPT)

  def test_previous_failed_attempt_is_allowed_after_a_successful_rerun(self):
    run = source_run(conclusion="success", run_attempt=3)
    result = resolve_cleanup_run(run, source_jobs(), REPOSITORY, str(RUN_ID), "2")
    self.assertEqual(result["runAttempt"], 2)
    self.assertTrue(result["cleanupNeeded"])

  def test_previous_failed_attempt_is_allowed_while_a_rerun_is_active(self):
    run = source_run(status="in_progress", conclusion=None, run_attempt=3)
    result = resolve_cleanup_run(run, source_jobs(), REPOSITORY, str(RUN_ID), "2")
    self.assertEqual(result["runAttempt"], 2)
    self.assertTrue(result["cleanupNeeded"])

  def test_successful_or_skipped_transport_step_needs_no_recovery(self):
    for conclusion in ("success", "skipped"):
      with self.subTest(conclusion=conclusion):
        result = resolve_cleanup_run(
          source_run(), source_jobs(step_conclusion=conclusion), REPOSITORY, str(RUN_ID), "2"
        )
        self.assertFalse(result["cleanupNeeded"])

  def test_rejects_untrusted_or_inconsistent_source_run(self):
    invalid_runs = (
      source_run(path=".github/workflows/ci.yml"),
      source_run(event="pull_request"),
      source_run(head_branch="feature"),
      source_run(head_repository={"full_name": "attacker/fork"}),
      source_run(repository={"full_name": "attacker/fork"}),
      source_run(status="in_progress"),
      source_run(id=99999),
    )
    for run in invalid_runs:
      with self.subTest(run=run):
        with self.assertRaises(RecoveryError):
          resolve_cleanup_run(run, source_jobs(), REPOSITORY, str(RUN_ID), "2")

  def test_rejects_invalid_attempt_or_job_shape(self):
    cases = (
      ("0", source_jobs()),
      ("3", source_jobs()),
      ("not-a-number", source_jobs()),
      ("2", {"total_count": 0, "jobs": []}),
      ("2", {"total_count": 2, "jobs": source_jobs()["jobs"]}),
      ("2", source_jobs(job_conclusion="success")),
    )
    for attempt, jobs in cases:
      with self.subTest(attempt=attempt, jobs=jobs):
        with self.assertRaises(RecoveryError):
          resolve_cleanup_run(source_run(), jobs, REPOSITORY, str(RUN_ID), attempt)

  def test_missing_cloudflare_step_uses_safe_prefix_recovery(self):
    missing = source_jobs()
    missing["jobs"][0]["steps"] = []
    result = resolve_cleanup_run(source_run(), missing, REPOSITORY, str(RUN_ID), "2")
    self.assertTrue(result["cleanupNeeded"])

  def test_rejects_duplicate_cloudflare_step(self):
    duplicate = copy.deepcopy(source_jobs())
    duplicate["jobs"][0]["steps"].append(copy.deepcopy(duplicate["jobs"][0]["steps"][0]))
    with self.assertRaises(RecoveryError):
      resolve_cleanup_run(source_run(), duplicate, REPOSITORY, str(RUN_ID), "2")

  def test_cli_writes_only_validated_github_outputs(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      run_path = root / "run.json"
      jobs_path = root / "jobs.json"
      output_path = root / "github-output"
      run_path.write_text(json.dumps(source_run()), encoding="utf-8")
      jobs_path.write_text(json.dumps(source_jobs()), encoding="utf-8")
      subprocess.run(
        [
          sys.executable,
          "scripts/cloudflare_cleanup_recovery.py",
          "--run-json",
          str(run_path),
          "--jobs-json",
          str(jobs_path),
          "--repository",
          REPOSITORY,
          "--run-id",
          str(RUN_ID),
          "--run-attempt",
          str(ATTEMPT),
          "--github-output",
          str(output_path),
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
      )
      outputs = dict(
        line.split("=", 1)
        for line in output_path.read_text(encoding="utf-8").splitlines()
      )
      self.assertEqual(outputs["run_id"], str(RUN_ID))
      self.assertEqual(outputs["run_attempt"], str(ATTEMPT))
      self.assertEqual(outputs["prefix"], "r1-meshdb-ci-12345-2")
      self.assertEqual(outputs["cleanup_needed"], "true")


if __name__ == "__main__":
  unittest.main()
