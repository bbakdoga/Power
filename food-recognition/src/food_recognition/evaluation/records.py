"""Evaluation records. No accuracy number is reported without the dataset and method behind it."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REQUIRED_SLICES = ("mixed_plate", "low_light", "unusual_angle", "partially_visible")


@dataclass
class EvaluationRecord:
    model_name: str
    model_version: str
    model_sha256: str
    model_format: str                 # pytorch | coreml-fp16 | coreml-int8
    dataset_version: str
    split: str                        # test set used
    method: str                       # plain-language description of the protocol
    metrics: dict[str, Any]
    slices: dict[str, dict[str, Any]] = field(default_factory=dict)  # metrics per condition
    hardware: str | None = None       # e.g. "iPhone 15, iOS 26.6.1" for on-device runs
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    def problems(self) -> list[str]:
        out = []
        for key in ("model_version", "model_sha256", "dataset_version", "split", "method"):
            if not getattr(self, key):
                out.append(f"{key} is required")
        if self.split == "train":
            out.append("evaluating on the training split is not a valid accuracy claim")
        missing = [s for s in REQUIRED_SLICES if s not in self.slices]
        if missing:
            out.append(f"missing condition slices: {', '.join(missing)}")
        return out

    def save(self, directory: str | Path) -> Path:
        problems = self.problems()
        if problems:
            raise ValueError("incomplete evaluation record:\n  " + "\n  ".join(problems))
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{self.model_name}-{self.model_version}-{self.model_format}-{self.dataset_version}.json"
        path.write_text(json.dumps(asdict(self), indent=2) + "\n", encoding="utf-8")
        return path
