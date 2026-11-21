"""YAML configuration loading. Paths in configs are relative to the project root."""

from __future__ import annotations

import os
import random
from pathlib import Path
from typing import Any

import numpy as np
import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def project_root() -> Path:
    """Return the food-recognition/ directory, overridable with FOOD_REC_ROOT."""
    override = os.environ.get("FOOD_REC_ROOT")
    return Path(override).resolve() if override else PROJECT_ROOT


def load_yaml(path: str | Path) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a YAML mapping at the top level")
    return data


def resolve(path: str | Path, root: Path | None = None) -> Path:
    candidate = Path(path)
    if candidate.is_absolute():
        return candidate
    return (root or project_root()) / candidate


def seed_everything(seed: int) -> None:
    """Seed every random generator the pipeline uses."""
    random.seed(seed)
    np.random.seed(seed)
    os.environ["PYTHONHASHSEED"] = str(seed)
    try:  # torch is optional (only the `train` extra installs it)
        import torch

        torch.manual_seed(seed)
        torch.cuda.manual_seed_all(seed)
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False
    except ImportError:
        pass
