"""Classifier training entry point (phase 4). Shares the detector's preflight gates."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ..detection.train import preflight


def train(config: dict[str, Any], dataset_version: str, root: Path) -> None:
    preflight(config, dataset_version, root)
    raise NotImplementedError(
        "Classifier training lands in phase 4, after the pretrained-weights licence decision. "
        "Preflight checks passed.")
