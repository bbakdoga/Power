"""Training data from a frozen dataset version. Pure Python (no torch), so it is unit-testable anywhere.

A frozen version (data/manifests/datasets/<version>.json) pins the annotation
file, the rights manifest and the split. Training only ever reads through it,
so every model can be traced back to exactly the photos and labels it saw.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from ..dataset.coco import CocoAnnotation, load_coco
from ..dataset.manifest import load_manifest
from ..dataset.split import load_split
from ..dataset.taxonomy import Taxonomy


@dataclass
class Sample:
    """One image with its boxes; boxes are (x, y, w, h) in pixels of the stored file."""

    path: Path
    width: int
    height: int
    boxes: list[tuple[float, float, float, float]] = field(default_factory=list)
    category_ids: list[int] = field(default_factory=list)
    source_id: str = ""


@dataclass
class Crop:
    path: Path
    box: tuple[float, float, float, float]
    label: int            # classifier index, or -1 for unknown_food
    source_id: str = ""


@dataclass
class FrozenData:
    version: str
    splits: dict[str, list[Sample]]

    def counts(self) -> dict[str, int]:
        return {name: len(samples) for name, samples in self.splits.items()}


def _frozen_path(root: Path, version: str) -> Path:
    return root / "data/manifests/datasets" / f"{version}.json"


def load_frozen(root: Path, version: str, raw_dir: Path, *, sources: list[str] | None = None,
                skip_unreviewed_corrections: bool = True) -> FrozenData:
    """Load every split of a frozen dataset version.

    `sources` keeps only images from those source ids (used for Open Images
    pretraining). User corrections that were never reviewed are always left out.
    """
    meta = json.loads(_frozen_path(root, version).read_text(encoding="utf-8"))
    files = {name: (Path(e["path"]) if Path(e["path"]).is_absolute() else root / e["path"])
             for name, e in meta["files"].items()}
    coco, _ = load_coco(files["annotations"])
    assignment = load_split(files["splits"])
    records, _ = load_manifest(files["manifest"])
    by_file = {r.file: r for r in records}
    grouped = coco.annotations_by_image()

    splits: dict[str, list[Sample]] = {"train": [], "val": [], "test": []}
    for image in sorted(coco.images, key=lambda i: i.file_name):
        split = assignment.get(image.file_name)
        record = by_file.get(image.file_name)
        if split not in splits or record is None:
            continue
        if sources is not None and record.source_id not in sources:
            continue
        if skip_unreviewed_corrections and record.source_type == "user_correction" and record.review_status != "approved":
            continue
        anns: list[CocoAnnotation] = [a for a in grouped.get(image.id, []) if not a.iscrowd]
        splits[split].append(Sample(
            path=raw_dir / image.file_name, width=image.width, height=image.height,
            boxes=[tuple(a.bbox) for a in anns],  # type: ignore[misc]
            category_ids=[a.category_id for a in anns], source_id=record.source_id))
    return FrozenData(version, splits)


def crops_from(samples: list[Sample], taxonomy: Taxonomy, *, min_side: float = 16.0,
               include_unknown: bool = True) -> list[Crop]:
    """Turn boxes into classifier crops. unknown_food becomes label -1 (a negative example)."""
    index = {name: i for i, name in enumerate(taxonomy.classifier_labels())}
    id_to_name = {c.id: c.name for c in taxonomy.active}
    crops = []
    for sample in samples:
        for box, cat in zip(sample.boxes, sample.category_ids, strict=True):
            if min(box[2], box[3]) < min_side:
                continue
            if cat == taxonomy.unknown.id:
                if include_unknown:
                    crops.append(Crop(sample.path, box, -1, sample.source_id))
            elif cat in id_to_name:
                crops.append(Crop(sample.path, box, index[id_to_name[cat]], sample.source_id))
    return crops


def class_balanced_weights(labels: list[int], num_classes: int, unknown_share: float = 0.15) -> list[float]:
    """Sampling weights so each class is drawn about equally often; unknown crops get a fixed share."""
    counts = [0] * num_classes
    unknown = 0
    for label in labels:
        if label < 0:
            unknown += 1
        else:
            counts[label] += 1
    present = sum(1 for c in counts if c)
    known_share = 1.0 - (unknown_share if unknown else 0.0)
    weights = []
    for label in labels:
        if label < 0:
            weights.append(unknown_share / unknown)
        else:
            weights.append(known_share / (present * counts[label]))
    return weights


def padded_box(box: tuple[float, float, float, float], padding: float, width: int, height: int) -> tuple[int, int, int, int]:
    """Grow a box by `padding` of its size on every side and clip to the image; returns (x0, y0, x1, y1)."""
    x, y, w, h = box
    x0, y0 = max(0.0, x - w * padding), max(0.0, y - h * padding)
    x1, y1 = min(float(width), x + w * (1 + padding)), min(float(height), y + h * (1 + padding))
    return int(x0), int(y0), max(int(x0) + 1, int(round(x1))), max(int(y0) + 1, int(round(y1)))
