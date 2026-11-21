"""MyFoodRepo / Food Recognition Benchmark (AIcrowd), CC BY 4.0.

Accepts the AIcrowd downloads (train-v0.4.tar.gz, val-v0.4.tar.gz) or a mirror
such as the Kaggle copy of the 2022 v2.0 release (a .zip). Any folder below the
given paths that holds an `annotations.json` (COCO with polygon masks) is a
split; its photos are in an `images/` folder next to it, or next to the JSON
itself. Splits without annotations (public test sets) are skipped.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..coco import CocoAnnotation, CocoDataset, CocoImage
from ..images import read_image_info
from ..manifest import ImageRecord
from ..taxonomy import Taxonomy
from .common import ImportStats, bbox_from_polygons, copy_unique, extract_archive

DROP = "drop"


def find_splits(paths: list[Path], cache_dir: Path) -> list[Path]:
    """Return folders that contain annotations.json, extracting archives first."""
    folders: list[Path] = []
    for path in paths:
        root = extract_archive(path, cache_dir) if path.is_file() else path
        folders += sorted(p.parent for p in root.rglob("annotations.json"))
    if not folders:
        raise FileNotFoundError("no annotations.json found; pass the downloaded .tar.gz files or their extracted folders")
    return folders


def load_split(folder: Path) -> dict[str, Any]:
    return json.loads((folder / "annotations.json").read_text(encoding="utf-8"))


def category_counts(folders: list[Path]) -> Counter[str]:
    counts: Counter[str] = Counter()
    for folder in folders:
        data = load_split(folder)
        names = {c["id"]: c["name"] for c in data["categories"]}
        counts.update(names[a["category_id"]] for a in data["annotations"] if a["category_id"] in names)
        for name in names.values():
            counts.setdefault(name, 0)
    return counts


def propose_mapping(counts: Counter[str], config: dict[str, Any], taxonomy: Taxonomy) -> dict[str, dict[str, Any]]:
    """Apply the drop list and class patterns (first match wins) to every source category."""
    valid = {c.name for c in taxonomy.active}
    patterns = config["patterns"]
    unknown_classes = set(patterns) - valid
    if unknown_classes:
        raise ValueError(f"patterns name classes not in the taxonomy: {sorted(unknown_classes)}")
    proposal: dict[str, dict[str, Any]] = {}
    for name in sorted(counts):
        lowered = name.lower()
        entry: dict[str, Any] = {"class": taxonomy.unknown.name, "rule": None, "boxes": counts[name]}
        drop_rule = next((p for p in config.get("drop", []) if re.search(p, lowered)), None)
        if drop_rule:
            entry.update({"class": DROP, "rule": f"drop: {drop_rule}"})
        else:
            for cls, pattern in patterns.items():
                if re.search(pattern, lowered):
                    entry.update({"class": cls, "rule": pattern})
                    break
        proposal[name] = entry
    return proposal


def write_mapping(proposal: dict[str, dict[str, Any]], path: Path, header: str) -> None:
    lines = [header.rstrip(), "", "reviewed: false   # set to true after checking every line", "mapping:"]
    width = max((len(n) for n in proposal), default=10) + 4
    for name, entry in proposal.items():
        key = json.dumps(name)
        note = f"  # {entry['boxes']} boxes" + (f"; rule {entry['rule']}" if entry["rule"] else "; no rule matched")
        lines.append(f"  {key + ':':<{width}} {entry['class']}{note}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def load_reviewed_mapping(path: Path, taxonomy: Taxonomy) -> dict[str, str]:
    import yaml

    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not data.get("reviewed"):
        raise ValueError(f"{path} has not been reviewed yet: check each line, then set `reviewed: true`")
    mapping: dict[str, str] = {str(k): str(v) for k, v in (data.get("mapping") or {}).items()}
    allowed = {c.name for c in taxonomy.all_categories()} | {DROP}
    bad = sorted({v for v in mapping.values() if v not in allowed})
    if bad:
        raise ValueError(f"{path}: unknown target classes {bad}")
    return mapping


def import_splits(folders: list[Path], mapping: dict[str, str], taxonomy: Taxonomy, raw_dir: Path, *,
                  source_id: str, attribution: str, known_hashes: set[str]) -> tuple[list[ImageRecord], CocoDataset, ImportStats]:
    stats = ImportStats()
    by_name = taxonomy.by_name()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    records: list[ImageRecord] = []
    images: list[CocoImage] = []
    annotations: list[CocoAnnotation] = []
    next_image = next_ann = 1
    for folder in folders:
        data = load_split(folder)
        if not data.get("annotations"):
            continue  # a public test split without labels
        split_name = folder.name
        cat_names = {c["id"]: c["name"] for c in data["categories"]}
        missing = sorted({n for n in cat_names.values() if n not in mapping})
        if missing:
            raise ValueError(f"mapping has no entry for {len(missing)} categories, e.g. {missing[:5]}; "
                             "re-run `food-rec propose-mapping`")
        anns_by_image: dict[int, list[dict[str, Any]]] = {}
        for ann in data["annotations"]:
            anns_by_image.setdefault(ann["image_id"], []).append(ann)
        image_dir = folder / "images" if (folder / "images").is_dir() else folder
        for img in data["images"]:
            src = image_dir / img["file_name"]
            if not src.is_file():
                stats.images_skipped_missing += 1
                continue
            info = read_image_info(src)
            if (info.width, info.height) != (int(img["width"]), int(img["height"])):
                stats.images_skipped_other += 1
                continue
            boxes: list[tuple[int, tuple[float, float, float, float]]] = []
            for ann in anns_by_image.get(img["id"], []):
                target = mapping[cat_names[ann["category_id"]]]
                if target == DROP:
                    stats.boxes_dropped += 1
                    continue
                bbox = tuple(ann["bbox"]) if ann.get("bbox") else bbox_from_polygons(ann.get("segmentation") or [])
                if not bbox or bbox[2] <= 0 or bbox[3] <= 0:
                    stats.boxes_dropped += 1
                    continue
                boxes.append((by_name[target].id, bbox))  # type: ignore[arg-type]
            if not boxes:
                stats.images_skipped_other += 1   # only drinks/sauces, nothing to learn from
                continue
            copied = copy_unique(src, raw_dir, source_id, known_hashes)
            if copied is None:
                stats.images_skipped_duplicate += 1
                continue
            rel, digest = copied
            images.append(CocoImage(next_image, rel, info.width, info.height))
            for cat_id, bbox in boxes:
                annotations.append(CocoAnnotation(next_ann, next_image, cat_id, bbox))
                next_ann += 1
                name = taxonomy.by_id()[cat_id].name
                stats.count_class(name)
                stats.boxes_added += 1
                stats.boxes_unknown_food += int(cat_id == taxonomy.unknown.id)
            records.append(ImageRecord(
                file=rel, sha256=digest, source_id=source_id, source_type="open_dataset", license="CC-BY-4.0",
                commercial_use=True, redistribution=True, group_id=f"myfoodrepo:{split_name}:{img['id']}",
                attribution=attribution, imported_at=now, review_status="approved",
                reviewer="importer:licence-checked",
                extra={"myfoodrepo_split": split_name, "myfoodrepo_image_id": img["id"],
                       "myfoodrepo_file": img["file_name"]}))
            stats.images_added += 1
            next_image += 1
    dataset = CocoDataset(images=images, annotations=annotations, categories=taxonomy.coco_categories(),
                          info={"source": source_id})
    return records, dataset, stats
