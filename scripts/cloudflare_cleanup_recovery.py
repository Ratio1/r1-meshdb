#!/usr/bin/env python3
"""Validate a GitHub release attempt before Cloudflare recovery runs."""

# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


RELEASE_WORKFLOW = ".github/workflows/release.yml"
RELEASE_JOB = "release"
CLOUDFLARE_STEP = "Run unchanged candidate through real ephemeral Cloudflare tunnels"
FAILED_CONCLUSIONS = {"failure", "cancelled", "timed_out"}
TERMINAL_STEP_CONCLUSIONS = FAILED_CONCLUSIONS | {"success", "skipped"}


class RecoveryError(RuntimeError):
  pass


def positive_integer(value, label: str) -> int:
  text = str(value or "")
  if not re.fullmatch(r"[1-9][0-9]*", text):
    raise RecoveryError(f"{label} must be a positive integer")
  return int(text)


def nested_repository(document: dict, key: str) -> str | None:
  value = document.get(key)
  return value.get("full_name") if isinstance(value, dict) else None


def repository_matches(document: dict, key: str, expected: str) -> bool:
  actual = nested_repository(document, key)
  return isinstance(actual, str) and actual.lower() == expected.lower()


def resolve_cleanup_run(
  run: dict,
  jobs: dict,
  repository: str,
  requested_run_id,
  requested_attempt,
) -> dict:
  if not isinstance(run, dict) or not isinstance(jobs, dict):
    raise RecoveryError("GitHub cleanup metadata has an invalid shape")
  if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
    raise RecoveryError("GitHub repository is invalid")

  run_id = positive_integer(requested_run_id, "run id")
  if run.get("id") != run_id:
    raise RecoveryError("GitHub run id does not match the requested run")
  if run.get("path") != RELEASE_WORKFLOW:
    raise RecoveryError("GitHub run is not the release workflow")
  if run.get("event") != "workflow_dispatch" or run.get("head_branch") != "main":
    raise RecoveryError("GitHub run is not a manually dispatched main release")
  if not repository_matches(run, "repository", repository):
    raise RecoveryError("GitHub run belongs to a different repository")
  if not repository_matches(run, "head_repository", repository):
    raise RecoveryError("GitHub run source belongs to a different repository")

  latest_attempt = positive_integer(run.get("run_attempt"), "latest run attempt")
  attempt = (
    latest_attempt
    if requested_attempt is None or str(requested_attempt) == ""
    else positive_integer(requested_attempt, "run attempt")
  )
  if attempt > latest_attempt:
    raise RecoveryError("run attempt is newer than the GitHub run")
  if attempt == latest_attempt and (
    run.get("status") != "completed" or run.get("conclusion") not in FAILED_CONCLUSIONS
  ):
    raise RecoveryError("latest GitHub run attempt is not unsuccessfully completed")

  job_list = jobs.get("jobs")
  if not isinstance(job_list, list):
    raise RecoveryError("GitHub attempt jobs response is invalid")
  total_count = jobs.get("total_count")
  if (
    not isinstance(total_count, int)
    or isinstance(total_count, bool)
    or total_count != len(job_list)
    or total_count > 100
  ):
    raise RecoveryError("GitHub attempt jobs response is incomplete")
  release_jobs = [job for job in job_list if isinstance(job, dict) and job.get("name") == RELEASE_JOB]
  if len(release_jobs) != 1:
    raise RecoveryError("GitHub attempt did not contain exactly one release job")
  release_job = release_jobs[0]
  if release_job.get("status") != "completed" or release_job.get("conclusion") not in FAILED_CONCLUSIONS:
    raise RecoveryError("GitHub release job is not unsuccessfully completed")

  steps = release_job.get("steps")
  if not isinstance(steps, list):
    raise RecoveryError("GitHub release job steps response is invalid")
  cloudflare_steps = [
    step for step in steps
    if isinstance(step, dict) and step.get("name") == CLOUDFLARE_STEP
  ]
  if len(cloudflare_steps) > 1:
    raise RecoveryError("GitHub release job contained duplicate Cloudflare gates")
  cloudflare_step = cloudflare_steps[0] if cloudflare_steps else None
  if cloudflare_step is not None and (
    cloudflare_step.get("status") != "completed"
    or cloudflare_step.get("conclusion") not in TERMINAL_STEP_CONCLUSIONS
  ):
    raise RecoveryError("GitHub Cloudflare gate has an invalid terminal state")

  prefix = f"r1-sql-ci-{run_id}-{attempt}"
  return {
    "runId": run_id,
    "runAttempt": attempt,
    "prefix": prefix,
    "artifactPattern": f"r1-distributed-sql-cloudflare-cleanup-{run_id}-{attempt}",
    # A hard runner loss can omit step metadata. Exact-prefix discovery is a
    # safe no-op when allocation never started, so absence still needs a pass.
    "cleanupNeeded": (
      cloudflare_step is None or cloudflare_step.get("conclusion") in FAILED_CONCLUSIONS
    ),
  }


def write_outputs(path: Path, result: dict) -> None:
  values = {
    "run_id": result["runId"],
    "run_attempt": result["runAttempt"],
    "prefix": result["prefix"],
    "artifact_pattern": result["artifactPattern"],
    "cleanup_needed": str(result["cleanupNeeded"]).lower(),
  }
  with path.open("a", encoding="utf-8") as handle:
    for key, value in values.items():
      handle.write(f"{key}={value}\n")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--run-json", required=True, type=Path)
  parser.add_argument("--jobs-json", required=True, type=Path)
  parser.add_argument("--repository", required=True)
  parser.add_argument("--run-id", required=True)
  parser.add_argument("--run-attempt")
  parser.add_argument("--github-output", type=Path)
  args = parser.parse_args()
  try:
    run = json.loads(args.run_json.read_text(encoding="utf-8"))
    jobs = json.loads(args.jobs_json.read_text(encoding="utf-8"))
    result = resolve_cleanup_run(
      run,
      jobs,
      args.repository,
      args.run_id,
      args.run_attempt,
    )
    if args.github_output:
      write_outputs(args.github_output, result)
    else:
      print(json.dumps(result, sort_keys=True))
  except (RecoveryError, OSError, json.JSONDecodeError) as exc:
    print(f"Cloudflare recovery error: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc


if __name__ == "__main__":
  main()
