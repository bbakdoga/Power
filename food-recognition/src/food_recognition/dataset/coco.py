"""COCO JSON parsing, structural validation and category remapping.

Extra fields we use on top of standard COCO:

- image: ``no_food`` (bool) marks a deliberate negative photo with no food.
- annotation: ``attributes`` with optional ``occluded``, ``truncated``,
  ``uncertain`` (bools) and ``mixed_dish`` (bool). See docs/annotation_guidelines.md.
"""

from __future__ import annotations

import json
import math
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .issues import Issue, Severity
from .taxonomy import Taxonomy

ALLOWED_ATTRIBUTES = {"occluded", "truncated", "uncertain", "mixed_dish"}


@dataclass
class CocoImage:
    id: int
    file_name: str
    width: int
    height: int
    no_food: bool = False


@dataclass
class CocoAnnotation:
    id: int
    image_id: int
    category_id: int
    bbox: tuple[float, float, float, float]  # x, y, width, height in pixels
    iscrowd: int = 0
    attributes: dict[str, Any] = field(default_factory=dict)

    @property
    def area(self) -> float:
        return self.bbox[2] * self.bbox[3]


@dataclass
class CocoDataset:
    images: list[CocoImage]
    annotations: list[CocoAnnotation]
    categories: list[dict[str, Any]]
    info: dict[str, Any] = field(default_factory=dict)

    def annotations_by_image(self) -> dict[int, list[CocoAnnotation]]:
        grouped: dict[int, list[CocoAnnotation]] = {img.id: [] for img in self.images}
        for ann in self.annotations:
            grouped.setdefault(ann.image_id, []).append(ann)
        return grouped

    def class_counts(self) -> Counter[int]:
        return Counter(a.category_id for a in self.annotations)

    def to_dict(self) -> dict[str, Any]:
        return {
            "info": self.info,
            "images": [
                {"id": i.id, "file_name": i.file_name, "width": i.width, "height": i.height,
                 **({"no_food": True} if i.no_food else {})}
                for i in self.images
            ],
            "annotations": [
                {"id": a.id, "image_id": a.image_id, "category_id": a.category_id,
                 "bbox": list(a.bbox), "area": a.area, "iscrowd": a.iscrowd,
                 **({"attributes": a.attributes} if a.attributes else {})}
                for a in self.annotations
            ],
            "categories": self.categories,
        }

    def subset(self, file_names: set[str]) -> CocoDataset:
        images = [i for i in self.images if i.file_name in file_names]
        ids = {i.id for i in images}
        return CocoDataset(
            images=images,
            annotations=[a for a in self.annotations if a.image_id in ids],
            categories=self.categories,
            info=dict(self.info),
        )


class CocoFormatError(ValueError):
    """The file is not usable COCO JSON at all."""


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def parse_coco(data: dict[str, Any]) -> tuple[CocoDataset, list[Issue]]:
    """Parse COCO JSON, collecting structural problems instead of stopping at the first."""
    issues: list[Issue] = []
    for key in ("images", "annotations", "categories"):
        if not isinstance(data.get(key), list):
            raise CocoFormatError(f"COCO JSON needs a list under {key!r}")

    images: list[CocoImage] = []
    seen_image_ids: set[int] = set()
    seen_files: set[str] = set()
    for raw in data["images"]:
        try:
            img = CocoImage(
                id=int(raw["id"]), file_name=str(raw["file_name"]),
                width=int(raw["width"]), height=int(raw["height"]),
                no_food=bool(raw.get("no_food", False)),
            )
        except (KeyError, TypeError, ValueError) as exc:
            issues.append(Issue("error", "image_malformed", f"image entry {raw!r:.120}: {exc}"))
            continue
        if img.id in seen_image_ids:
            issues.append(Issue("error", "image_duplicate_id", f"image id {img.id} used twice", img.file_name))
            continue
        if img.file_name in seen_files:
            issues.append(Issue("error", "image_duplicate_file", "file listed twice", img.file_name))
            continue
        if img.width <= 0 or img.height <= 0:
            issues.append(Issue("error", "image_bad_size", f"size {img.width}x{img.height}", img.file_name))
        seen_image_ids.add(img.id)
        seen_files.add(img.file_name)
        images.append(img)

    annotations: list[CocoAnnotation] = []
    seen_ann_ids: set[int] = set()
    for raw in data["annotations"]:
        try:
            bbox_raw = raw["bbox"]
            if not (isinstance(bbox_raw, list) and len(bbox_raw) == 4 and all(_is_number(v) for v in bbox_raw)):
                raise ValueError(f"bbox must be four finite numbers, got {bbox_raw!r}")
            attributes = raw.get("attributes") or {}
            if not isinstance(attributes, dict):
                raise ValueError("attributes must be an object")
            ann = CocoAnnotation(
                id=int(raw["id"]), image_id=int(raw["image_id"]),
                category_id=int(raw["category_id"]),
                bbox=(float(bbox_raw[0]), float(bbox_raw[1]), float(bbox_raw[2]), float(bbox_raw[3])),
                iscrowd=int(raw.get("iscrowd", 0)), attributes=attributes,
            )
        except (KeyError, TypeError, ValueError) as exc:
            issues.append(Issue("error", "annotation_malformed", f"annotation {raw.get('id', '?')}: {exc}"))
            continue
        if ann.id in seen_ann_ids:
            issues.append(Issue("error", "annotation_duplicate_id", f"annotation id {ann.id} used twice"))
            continue
        seen_ann_ids.add(ann.id)
        annotations.append(ann)

    dataset = CocoDataset(images=images, annotations=annotations,
                          categories=list(data["categories"]), info=dict(data.get("info") or {}))
    return dataset, issues


def load_coco(path: str | Path) -> tuple[CocoDataset, list[Issue]]:
    with open(path, encoding="utf-8") as handle:
        try:
            data = json.load(handle)
        except json.JSONDecodeError as exc:
            raise CocoFormatError(f"{path}: not valid JSON ({exc})") from exc
    if not isinstance(data, dict):
        raise CocoFormatError(f"{path}: top level must be an object")
    return parse_coco(data)


def save_coco(dataset: CocoDataset, path: str | Path) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(dataset.to_dict(), handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def validate_annotations(dataset: CocoDataset, taxonomy: Taxonomy, *, min_box_side: float = 8.0,
                         bbox_tolerance: float = 1.0, allow_images_without_boxes: bool = True) -> list[Issue]:
    """Check categories, boxes and image references against the taxonomy."""
    issues: list[Issue] = []
    valid = taxonomy.by_id()
    images = {img.id: img for img in dataset.images}

    for cat in dataset.categories:
        known = valid.get(int(cat.get("id", -1)))
        if known is None or known.name != cat.get("name"):
            issues.append(Issue("error", "category_mismatch",
                                f"category {cat!r} does not match the taxonomy; run `food-rec normalize`"))

    for ann in dataset.annotations:
        img = images.get(ann.image_id)
        where = img.file_name if img else None
        if img is None:
            issues.append(Issue("error", "annotation_orphan", f"annotation {ann.id} points to missing image {ann.image_id}"))
            continue
        cls = valid.get(ann.category_id)
        if cls is None:
            issues.append(Issue("error", "annotation_unknown_category",
                                f"annotation {ann.id}: category {ann.category_id} not in taxonomy", where))
        elif cls.retired:
            issues.append(Issue("warning", "annotation_retired_category",
                                f"annotation {ann.id}: {cls.name} is retired", where))
        x, y, w, h = ann.bbox
        if w <= 0 or h <= 0:
            issues.append(Issue("error", "bbox_empty", f"annotation {ann.id}: width/height must be > 0", where))
            continue
        if x < -bbox_tolerance or y < -bbox_tolerance or x + w > img.width + bbox_tolerance or y + h > img.height + bbox_tolerance:
            issues.append(Issue("error", "bbox_out_of_bounds",
                                f"annotation {ann.id}: box {ann.bbox} outside {img.width}x{img.height}", where))
        if min(w, h) < min_box_side:
            issues.append(Issue("warning", "bbox_tiny", f"annotation {ann.id}: box side < {min_box_side}px", where))
        unknown_attrs = set(ann.attributes) - ALLOWED_ATTRIBUTES
        if unknown_attrs:
            issues.append(Issue("warning", "annotation_unknown_attribute",
                                f"annotation {ann.id}: unknown attributes {sorted(unknown_attrs)}", where))
        if ann.iscrowd:
            issues.append(Issue("warning", "annotation_crowd",
                                f"annotation {ann.id}: iscrowd boxes are ignored for training", where))

    by_image = dataset.annotations_by_image()
    for img in dataset.images:
        anns = by_image.get(img.id, [])
        if img.no_food and anns:
            issues.append(Issue("error", "no_food_with_boxes", "image is marked no_food but has boxes", img.file_name))
        if not anns and not img.no_food:
            severity: Severity = "warning" if allow_images_without_boxes else "error"
            issues.append(Issue(severity, "image_unannotated",
                                "no boxes and not marked no_food (unfinished annotation?)", img.file_name))
        exact: Counter[tuple[int, tuple[float, ...]]] = Counter((a.category_id, tuple(round(v, 1) for v in a.bbox)) for a in anns)
        for (cat_id, box), count in exact.items():
            if count > 1:
                issues.append(Issue("warning", "annotation_duplicate_box",
                                    f"category {cat_id} box {box} drawn {count} times", img.file_name))
    return issues


def normalize_categories(dataset: CocoDataset, taxonomy: Taxonomy) -> tuple[CocoDataset, list[Issue]]:
    """Map an export's categories (e.g. from Label Studio) onto taxonomy ids by name."""
    issues: list[Issue] = []
    by_name = taxonomy.by_name()
    old_to_new: dict[int, int] = {}
    for cat in dataset.categories:
        name = str(cat.get("name", "")).strip()
        target = by_name.get(name) or by_name.get(name.lower().replace(" ", "_").replace("-", "_"))
        if target is None:
            issues.append(Issue("error", "category_unmapped", f"label {name!r} is not in the taxonomy"))
            continue
        old_to_new[int(cat["id"])] = target.id
    annotations: list[CocoAnnotation] = []
    for ann in dataset.annotations:
        new_id = old_to_new.get(ann.category_id)
        if new_id is None:
            issues.append(Issue("error", "annotation_unmapped", f"annotation {ann.id} uses an unmapped label"))
            continue
        annotations.append(CocoAnnotation(ann.id, ann.image_id, new_id, ann.bbox, ann.iscrowd, dict(ann.attributes)))
    normalized = CocoDataset(images=list(dataset.images), annotations=annotations,
                             categories=taxonomy.coco_categories(),
                             info={**dataset.info, "taxonomy_version": taxonomy.version})
    return normalized, issues
