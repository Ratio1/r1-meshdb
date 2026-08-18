#!/usr/bin/env python3
"""Generate and verify the exact license-file closure for vendored Go modules."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
VENDOR_ROOT = REPOSITORY_ROOT / "engine" / "vendor"
MODULES_FILE = VENDOR_ROOT / "modules.txt"
OUTPUT = REPOSITORY_ROOT / "source" / "vendor-license-manifest.json"
SPECIAL_LICENSE_PATHS = {
    "engine/vendor/github.com/mattn/go-localereader/README.md",
}
NOTICE_PREFIXES = ("authors", "copying", "licence", "license", "notice", "patents")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_notice(path: Path) -> bool:
    relative = path.relative_to(REPOSITORY_ROOT).as_posix()
    return path.name.lower().startswith(NOTICE_PREFIXES) or relative in SPECIAL_LICENSE_PATHS


def notice_paths() -> list[Path]:
    return sorted(path for path in VENDOR_ROOT.rglob("*") if path.is_file() and is_notice(path))


def module_roots() -> list[Path]:
    roots = []
    for line in MODULES_FILE.read_text(encoding="utf-8").splitlines():
        if not line.startswith("# ") or line.startswith("# ##"):
            continue
        module = line[2:].split()[0]
        root = VENDOR_ROOT / module
        if root.is_dir():
            roots.append(root)
    return sorted(set(roots))


def build_manifest() -> dict[str, object]:
    notices = notice_paths()
    uncovered = [
        root.relative_to(VENDOR_ROOT).as_posix()
        for root in module_roots()
        if not any(path == root or root in path.parents for path in notices)
    ]
    if uncovered:
        raise RuntimeError(
            "vendored modules without retained license evidence: " + ", ".join(uncovered)
        )
    return {
        "schemaVersion": 1,
        "description": "Exact license, notice, patent, and attribution files retained from the vendored Go dependency closure.",
        "files": [
            {
                "path": path.relative_to(REPOSITORY_ROOT).as_posix(),
                "sha256": sha256(path),
            }
            for path in notices
        ],
    }


def render(manifest: dict[str, object]) -> str:
    return json.dumps(manifest, indent=2, sort_keys=True) + "\n"


def copy_notices(manifest: dict[str, object], destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for record in manifest["files"]:
        source = REPOSITORY_ROOT / record["path"]
        relative = source.relative_to(VENDOR_ROOT)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--copy-to", type=Path)
    args = parser.parse_args()

    try:
        manifest = build_manifest()
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    rendered = render(manifest)

    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != rendered:
            print("vendor license manifest is stale; regenerate it", file=sys.stderr)
            return 1
    else:
        OUTPUT.write_text(rendered, encoding="utf-8")

    if args.copy_to:
        copy_notices(manifest, args.copy_to)
    print(f"verified {len(manifest['files'])} vendored license and notice files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
