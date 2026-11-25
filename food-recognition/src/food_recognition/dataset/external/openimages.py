"""Open Images V7 importer (images CC BY 2.0, annotations CC BY 4.0).

Inputs are the official CSVs, downloaded once (no login needed):
  - oidv7-class-descriptions.csv                 class id -> name
  - <split>-annotations-bbox.csv                 boxes (oidv6-train-annotations-bbox.csv for train)
  - <split>-images-with-rotation.csv             licence, author, URL, rotation per image
  - oidv7-<split>-annotations-human-imagelabels.csv   (optional) photo-level labels
and the images themselves, fetched with scripts/download_openimages.py.

Two-step flow:
  1. `select_images` reads the CSVs and returns the image ids worth downloading
     (CC BY 2.0, not rotated, at least one of our foods, capped per class).
  2. `import_images` copies the downloaded files in, converts boxes to pixels,
     and writes rights records with each photo's author and URL.
"""

from __future__ import annotations

import csv
from collections import defaultdict
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..coco import CocoAnnotation, CocoDataset, CocoImage
from ..images import read_image_info
from ..manifest import ImageRecord
from ..taxonomy import Taxonomy
from .common import ImportStats, copy_unique

CC_BY_20 = "https://creativecommons.org/licenses/by/2.0/"


@dataclass
class ClassMap:
    box_targets: dict[str, int]          # Open Images MID -> our class id (0 = unknown_food)
    label_targets: dict[str, int]        # MID -> our class id, photo-level only
    names: dict[str, str]                # MID -> Open Images display name


def build_class_map(config: dict[str, Any], descriptions_csv: Path, taxonomy: Taxonomy) -> ClassMap:
    by_display: dict[str, str] = {}
    names: dict[str, str] = {}
    with open(descriptions_csv, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            by_display.setdefault(row["DisplayName"], row["LabelName"])
            names[row["LabelName"]] = row["DisplayName"]
    ours = taxonomy.by_name()
    box_targets: dict[str, int] = {}
    label_targets: dict[str, int] = {}
    missing: list[str] = []

    def mid(display: str) -> str | None:
        found = by_display.get(display)
        if found is None:
            missing.append(display)
        return found

    for display in config.get("other_food_as_unknown", []):
        if (m := mid(display)) is not None:
            box_targets[m] = taxonomy.unknown.id
    for cls, spec in config["classes"].items():
        if cls not in ours:
            raise ValueError(f"open_images.yaml maps to unknown class {cls}")
        for display in spec.get("boxable", []):
            if (m := mid(display)) is not None:
                box_targets[m] = ours[cls].id
        for display in spec.get("image_level", []):
            if (m := mid(display)) is not None:
                label_targets[m] = ours[cls].id
    if missing:
        raise ValueError(f"Open Images class names not found in {descriptions_csv.name}: {missing}")
    return ClassMap(box_targets=box_targets, label_targets=label_targets, names=names)


@dataclass
class BoxRow:
    mid: str
    xmin: float
    xmax: float
    ymin: float
    ymax: float
    occluded: bool
    truncated: bool
    group_of: bool


@dataclass
class Selection:
    boxes: dict[str, list[BoxRow]] = field(default_factory=dict)          # image id -> boxes
    to_annotate: dict[str, int] = field(default_factory=dict)             # image id -> suggested class id
    meta: dict[str, dict[str, str]] = field(default_factory=dict)         # image id -> metadata row
    skipped_license: int = 0
    skipped_rotation: int = 0

    def image_ids(self) -> list[str]:
        return sorted(set(self.boxes) | set(self.to_annotate))


def _flag(row: dict[str, str], key: str) -> bool:
    return row.get(key, "0").strip() == "1"


def _rows(path: Path) -> Iterator[dict[str, str]]:
    with open(path, newline="", encoding="utf-8") as handle:
        yield from csv.DictReader(handle)


def select_images(class_map: ClassMap, *, boxes_csv: Path, metadata_csv: Path, labels_csv: Path | None,
                  max_per_class: int, skip_depictions: bool = True) -> Selection:
    """Choose images to download. Deterministic: candidates are taken in image-id order."""
    candidate_boxes: dict[str, list[BoxRow]] = defaultdict(list)
    for row in _rows(boxes_csv):
        mid = row["LabelName"]
        if mid not in class_map.box_targets:
            continue
        if skip_depictions and _flag(row, "IsDepiction"):
            continue
        candidate_boxes[row["ImageID"]].append(BoxRow(
            mid, float(row["XMin"]), float(row["XMax"]), float(row["YMin"]), float(row["YMax"]),
            _flag(row, "IsOccluded"), _flag(row, "IsTruncated"), _flag(row, "IsGroupOf")))

    candidate_labels: dict[str, int] = {}
    if labels_csv is not None:
        for row in _rows(labels_csv):
            mid = row["LabelName"]
            if mid in class_map.label_targets and float(row.get("Confidence") or 0) >= 1.0:
                candidate_labels.setdefault(row["ImageID"], class_map.label_targets[mid])

    wanted = set(candidate_boxes) | set(candidate_labels)
    selection = Selection()
    for row in _rows(metadata_csv):
        image_id = row["ImageID"]
        if image_id not in wanted:
            continue
        if row.get("License", "").strip() != CC_BY_20:
            selection.skipped_license += 1
            continue
        rotation = (row.get("Rotation") or "").strip()
        if rotation and float(rotation) != 0.0:
            selection.skipped_rotation += 1
            continue
        selection.meta[image_id] = row

    per_class: dict[int, int] = defaultdict(int)
    for image_id in sorted(candidate_boxes):
        if image_id not in selection.meta:
            continue
        targets = {class_map.box_targets[b.mid] for b in candidate_boxes[image_id]} - {0}
        if not targets or all(per_class[t] >= max_per_class for t in targets):
            continue  # only other foods, or every class it would add is already full
        for t in targets:
            per_class[t] += 1
        selection.boxes[image_id] = candidate_boxes[image_id]
    for image_id in sorted(candidate_labels):
        target = candidate_labels[image_id]
        if image_id in selection.meta and image_id not in selection.boxes and per_class[target] < max_per_class:
            per_class[target] += 1
            selection.to_annotate[image_id] = target
    selection.meta = {k: v for k, v in selection.meta.items() if k in selection.boxes or k in selection.to_annotate}
    return selection


def attribution(meta: dict[str, str]) -> str:
    author = meta.get("Author") or "unknown author"
    url = meta.get("OriginalLandingURL") or meta.get("OriginalURL") or ""
    return f"{author}, {url}, via Open Images V7, CC BY 2.0"


ImportResult = tuple[list[ImageRecord], CocoDataset, list[tuple[str, str]], ImportStats]


def import_images(selection: Selection, class_map: ClassMap, taxonomy: Taxonomy, images_dir: Path, raw_dir: Path, *,
                  source_id: str, known_hashes: set[str]) -> ImportResult:
    """Copy downloaded images in. Returns records, boxed COCO data, (file, suggested class) to annotate, stats."""
    stats = ImportStats()
    stats.images_skipped_license = selection.skipped_license
    names = {c.id: c.name for c in taxonomy.all_categories()}
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    records: list[ImageRecord] = []
    images: list[CocoImage] = []
    annotations: list[CocoAnnotation] = []
    to_annotate: list[tuple[str, str]] = []
    next_image = next_ann = 1
    for image_id in selection.image_ids():
        src = images_dir / f"{image_id}.jpg"
        if not src.is_file():
            stats.images_skipped_missing += 1
            continue
        info = read_image_info(src)
        if info.exif_rotated:
            stats.images_skipped_other += 1
            continue
        copied = copy_unique(src, raw_dir, source_id, known_hashes)
        if copied is None:
            stats.images_skipped_duplicate += 1
            continue
        rel, digest = copied
        meta = selection.meta[image_id]
        records.append(ImageRecord(
            file=rel, sha256=digest, source_id=source_id, source_type="open_dataset", license="CC-BY-2.0",
            commercial_use=True, redistribution=True, group_id=f"openimages:{image_id}",
            attribution=attribution(meta), imported_at=now, review_status="approved",
            reviewer="importer:licence-checked",
            extra={"open_images_id": image_id, "original_url": meta.get("OriginalURL"),
                   "author_profile": meta.get("AuthorProfileURL"), "title": meta.get("Title")}))
        stats.images_added += 1
        if image_id in selection.to_annotate:
            to_annotate.append((rel, names[selection.to_annotate[image_id]]))
            stats.images_to_annotate += 1
            continue
        images.append(CocoImage(next_image, rel, info.width, info.height))
        for box in selection.boxes[image_id]:
            x1, x2 = box.xmin * info.width, box.xmax * info.width
            y1, y2 = box.ymin * info.height, box.ymax * info.height
            if x2 - x1 <= 0 or y2 - y1 <= 0:
                stats.boxes_dropped += 1
                continue
            cat_id = class_map.box_targets[box.mid]
            attrs = {k: True for k, v in (("occluded", box.occluded), ("truncated", box.truncated)) if v}
            annotations.append(CocoAnnotation(next_ann, next_image, cat_id, (x1, y1, x2 - x1, y2 - y1), attributes=attrs))
            next_ann += 1
            stats.boxes_added += 1
            stats.boxes_unknown_food += int(cat_id == taxonomy.unknown.id)
            stats.count_class(names[cat_id])
        next_image += 1
    dataset = CocoDataset(images=images, annotations=annotations, categories=taxonomy.coco_categories(),
                          info={"source": source_id})
    return records, dataset, to_annotate, stats


def save_selection(selection: Selection, path: Path) -> None:
    import json

    payload = {
        "boxes": {k: [b.__dict__ for b in v] for k, v in selection.boxes.items()},
        "to_annotate": selection.to_annotate,
        "meta": selection.meta,
        "skipped_license": selection.skipped_license,
        "skipped_rotation": selection.skipped_rotation,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def load_selection(path: Path) -> Selection:
    import json

    data = json.loads(path.read_text(encoding="utf-8"))
    return Selection(
        boxes={k: [BoxRow(**b) for b in v] for k, v in data["boxes"].items()},
        to_annotate={k: int(v) for k, v in data["to_annotate"].items()},
        meta=data["meta"], skipped_license=data["skipped_license"], skipped_rotation=data["skipped_rotation"])
