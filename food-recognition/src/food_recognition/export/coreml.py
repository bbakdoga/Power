"""Core ML export helpers.

The conversion itself needs torch + coremltools (the `train` and `export`
extras) and lands in phase 5. Metadata and parity logic are here already so
they can be tested without either library.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np


def model_metadata(*, kind: str, labels: list[str], model_version: str, dataset_version: str,
                   taxonomy_version: str, author: str, license_note: str, extra: dict[str, Any] | None = None) -> dict[str, str]:
    """User-defined metadata stored in the .mlpackage (all values must be strings)."""
    if kind not in {"detector", "classifier"}:
        raise ValueError("kind must be detector or classifier")
    meta = {
        "com.power.food.kind": kind,
        "com.power.food.labels": ",".join(labels),
        "com.power.food.model_version": model_version,
        "com.power.food.dataset_version": dataset_version,
        "com.power.food.taxonomy_version": taxonomy_version,
        "com.power.food.author": author,
        "com.power.food.license": license_note,
        "com.power.food.nutrition": "none; look up USDA FoodData Central after the user confirms",
    }
    for key, value in (extra or {}).items():
        meta[f"com.power.food.{key}"] = str(value)
    return meta


@dataclass
class ParityResult:
    max_abs_diff: float
    mean_abs_diff: float
    top1_agreement: float
    passed: bool


def check_parity(reference: np.ndarray, candidate: np.ndarray, *, max_abs_diff: float,
                 min_top1_agreement: float) -> ParityResult:
    """Compare PyTorch outputs with Core ML outputs on the same inputs (N x C scores)."""
    reference = np.asarray(reference, dtype=np.float64)
    candidate = np.asarray(candidate, dtype=np.float64)
    if reference.shape != candidate.shape:
        raise ValueError(f"shape mismatch {reference.shape} vs {candidate.shape}")
    diff = np.abs(reference - candidate)
    agreement = float(np.mean(reference.argmax(axis=-1) == candidate.argmax(axis=-1))) if reference.ndim > 1 else 1.0
    worst = float(diff.max()) if diff.size else 0.0
    return ParityResult(max_abs_diff=worst, mean_abs_diff=float(diff.mean()) if diff.size else 0.0,
                        top1_agreement=agreement,
                        passed=worst <= max_abs_diff and agreement >= min_top1_agreement)


def export_detector(*_: Any, **__: Any) -> None:
    raise NotImplementedError("Core ML export lands in phase 5, after a trained checkpoint exists.")


def export_classifier(*_: Any, **__: Any) -> None:
    raise NotImplementedError("Core ML export lands in phase 5, after a trained checkpoint exists.")
