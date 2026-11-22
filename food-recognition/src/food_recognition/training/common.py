"""Shared torch helpers for the training loops: run folders, schedules, checkpoints, initial weights."""

from __future__ import annotations

import hashlib
import json
import math
import os
import platform
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import torch
import yaml

# Where `pretrained: <asset id>` looks for weights we produced ourselves.
PRETRAINED_WEIGHTS = {
    "openimages_pretrain_own": {
        "classification": "models/pretrain/classifier_backbone_openimages.pt",
        "detection": "models/pretrain/detector_backbone_openimages.pt",
    },
}


def device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def amp_dtype(dev: torch.device) -> torch.dtype | None:
    """bf16 where the GPU supports it, fp16 otherwise (e.g. V100), none on CPU."""
    if dev.type != "cuda":
        return None
    return torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16


def seed_torch(seed: int, deterministic: bool = True) -> None:
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    if deterministic:
        torch.backends.cudnn.benchmark = False
        torch.backends.cudnn.deterministic = True


def worker_seed(worker_id: int) -> None:
    import random

    import numpy as np

    seed = torch.initial_seed() % 2**32
    np.random.seed(seed)
    random.seed(seed)


def run_dir(root: Path, config: dict[str, Any], kind: str, dataset_version: str) -> Path:
    name = (config.get("experiment") or {}).get("name") or kind
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = root / "models/runs" / name / f"{dataset_version}-{stamp}"
    path.mkdir(parents=True, exist_ok=True)
    (path / "config.yaml").write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
    return path


def cosine_lr(step: int, total: int, base: float, warmup: int, floor: float = 0.05) -> float:
    if step < warmup:
        return base * (step + 1) / max(warmup, 1)
    progress = (step - warmup) / max(total - warmup, 1)
    return base * (floor + (1 - floor) * 0.5 * (1 + math.cos(math.pi * min(progress, 1.0))))


def init_weights_path(config: dict[str, Any], kind: str, root: Path) -> Path | None:
    """Resolve `model.pretrained`: null, an asset id we produce ourselves, or a checkpoint path."""
    ref = (config.get("model") or {}).get("pretrained")
    if not ref:
        return None
    if ref in PRETRAINED_WEIGHTS:
        path = root / PRETRAINED_WEIGHTS[ref][kind]
        if not path.exists():
            raise FileNotFoundError(
                f"{ref} weights not found at {path}. Run the Open Images pretraining first "
                f"(food-rec pretrain-{'classifier' if kind == 'classification' else 'detector'}).")
        return path
    path = Path(ref) if Path(ref).is_absolute() else root / ref
    if not path.exists():
        raise FileNotFoundError(f"pretrained weights {path} not found")
    return path


def load_matching(model: torch.nn.Module, state: dict[str, torch.Tensor]) -> tuple[int, int]:
    """Load every tensor whose name and shape match; returns (loaded, skipped)."""
    own = model.state_dict()
    keep = {k: v for k, v in state.items() if k in own and own[k].shape == v.shape}
    model.load_state_dict(keep, strict=False)
    return len(keep), len(own) - len(keep)


def save_checkpoint(path: Path, model: torch.nn.Module, extra: dict[str, Any]) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"model": model.state_dict(), **extra}, path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment() -> dict[str, Any]:
    info: dict[str, Any] = {"python": platform.python_version(), "torch": torch.__version__,
                            "host": platform.node(), "slurm_job": os.environ.get("SLURM_JOB_ID")}
    if torch.cuda.is_available():
        info["gpu"] = torch.cuda.get_device_name(0)
    return info


class Timer:
    def __init__(self) -> None:
        self.start = time.time()

    def hours(self) -> float:
        return (time.time() - self.start) / 3600


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, default=float) + "\n", encoding="utf-8")
