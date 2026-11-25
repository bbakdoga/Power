"""Versioned dataset manifests: freeze exactly which files, labels and rights went into a model."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def file_digest(path: str | Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def freeze_dataset(version: str, *, annotations: Path, manifest: Path, splits: Path, taxonomy: Path,
                   validation_summary: dict[str, Any], out_dir: Path, notes: str = "") -> Path:
    """Write data/manifests/datasets/<version>.json. Refuses to overwrite or to freeze a failing dataset."""
    if not validation_summary.get("ok"):
        raise ValueError("refusing to freeze a dataset that fails validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{version}.json"
    if path.exists():
        raise FileExistsError(f"{path} already exists; dataset versions are immutable")
    payload = {
        "dataset_version": version,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": {
            "annotations": {"path": str(annotations), "sha256": file_digest(annotations)},
            "manifest": {"path": str(manifest), "sha256": file_digest(manifest)},
            "splits": {"path": str(splits), "sha256": file_digest(splits)},
            "taxonomy": {"path": str(taxonomy), "sha256": file_digest(taxonomy)},
        },
        "validation": validation_summary,
        "notes": notes,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def verify_frozen(path: Path, root: Path) -> list[str]:
    """Return mismatches between a frozen manifest and the files on disk."""
    data = json.loads(path.read_text(encoding="utf-8"))
    problems = []
    for name, entry in data["files"].items():
        target = Path(entry["path"])
        target = target if target.is_absolute() else root / target
        if not target.exists():
            problems.append(f"{name}: {target} is missing")
        elif file_digest(target) != entry["sha256"]:
            problems.append(f"{name}: {target} changed since {data['dataset_version']} was frozen")
    return problems
