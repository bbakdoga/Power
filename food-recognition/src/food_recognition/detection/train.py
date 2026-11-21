"""Detector training entry point.

Training is deliberately not implemented yet (phase 4). This module already
enforces the gates that must pass first: approved licences, a frozen dataset
version that still matches the files on disk.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ..config import resolve, seed_everything
from ..dataset.versioning import verify_frozen
from ..licensing import load_assets, require_approved


def preflight(config: dict[str, Any], dataset_version: str, root: Path) -> None:
    require_approved(config, load_assets(resolve("licenses/assets.yaml", root)))
    frozen = resolve(f"data/manifests/datasets/{dataset_version}.json", root)
    if not frozen.exists():
        raise FileNotFoundError(f"dataset version {dataset_version} is not frozen; run `food-rec freeze`")
    problems = verify_frozen(frozen, root)
    if problems:
        raise RuntimeError("dataset changed since it was frozen:\n  " + "\n  ".join(problems))
    seed_everything(int(config.get("seed", 1337)))


def train(config: dict[str, Any], dataset_version: str, root: Path) -> None:
    preflight(config, dataset_version, root)
    raise NotImplementedError(
        "Detector training lands in phase 4, after the pretrained-weights licence decision. "
        "Preflight checks passed.")
