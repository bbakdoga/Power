"""Open Images V7 pretraining data (asset `openimages_pretrain_own`).

We pretrain both networks ourselves on general Open Images photos instead of
using ImageNet or COCO checkpoints, whose image terms are not clearly
commercial. Only photos Google lists as CC BY 2.0 are used; the box labels
are CC BY 4.0. Every selected photo's author and URL is written to
attributions.tsv.

Flow:
  1. `select_pretrain` picks a deterministic random subset of boxable train
     images (CC BY 2.0, not rotated) and writes selection.json + ids.txt.
  2. scripts/download_openimages.py ids.txt images/ --max-side 640
  3. `load_pretrain_samples` turns the selection plus the downloaded files
     into training samples (boxes in pixels, 600 boxable classes).
"""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
from typing import Any

from ..dataset.external.openimages import CC_BY_20, _flag, _rows, attribution
from .data import Sample


def _rank(image_id: str, seed: int) -> str:
    return hashlib.sha1(f"{seed}:{image_id}".encode()).hexdigest()


def select_pretrain(*, boxes_csv: Path, metadata_csv: Path, classes_csv: Path, out_dir: Path,
                    max_images: int, seed: int = 1337, val_fraction: float = 0.02) -> dict[str, Any]:
    names: dict[str, str] = {}
    with open(classes_csv, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            names[row["LabelName"]] = row["DisplayName"]

    eligible: dict[str, dict[str, str]] = {}
    skipped = {"license": 0, "rotation": 0}
    for row in _rows(metadata_csv):
        if row.get("License", "").strip() != CC_BY_20:
            skipped["license"] += 1
            continue
        rotation = (row.get("Rotation") or "").strip()
        if rotation and float(rotation) != 0.0:
            skipped["rotation"] += 1
            continue
        eligible[row["ImageID"]] = row
    chosen = set(sorted(eligible, key=lambda i: _rank(i, seed))[:max_images])

    boxes: dict[str, list[list[Any]]] = {}
    for row in _rows(boxes_csv):
        image_id = row["ImageID"]
        if image_id not in chosen or _flag(row, "IsDepiction"):
            continue
        boxes.setdefault(image_id, []).append([row["LabelName"], float(row["XMin"]), float(row["YMin"]),
                                               float(row["XMax"]), float(row["YMax"])])
    classes = sorted({b[0] for bs in boxes.values() for b in bs})
    index = {mid: i for i, mid in enumerate(classes)}
    ids = sorted(boxes, key=lambda i: _rank(i, seed + 1))
    n_val = max(1, int(len(ids) * val_fraction))
    val_ids = set(ids[:n_val])
    images = [{"id": i, "split": "val" if i in val_ids else "train",
               "boxes": [[index[b[0]], *b[1:]] for b in boxes[i]]} for i in sorted(ids)]

    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {"source": "Open Images V7 train, boxable, CC BY 2.0 only", "seed": seed,
               "classes": [{"mid": m, "name": names.get(m, m)} for m in classes], "images": images,
               "skipped": skipped}
    (out_dir / "selection.json").write_text(json.dumps(payload), encoding="utf-8")
    (out_dir / "ids.txt").write_text("".join(f"{i['id']}\n" for i in images), encoding="utf-8")
    with open(out_dir / "attributions.tsv", "w", encoding="utf-8") as handle:
        handle.write("image_id\tattribution\n")
        for item in images:
            image_id = str(item["id"])
            handle.write(f"{image_id}\t{attribution(eligible[image_id])}\n")
    return {"images": len(images), "val": n_val, "classes": len(classes), **skipped}


def load_pretrain_samples(out_dir: Path, images_dir: Path) -> tuple[dict[str, list[Sample]], list[str]]:
    """Samples with pixel boxes for the downloaded images. Image sizes are cached in sizes.json."""
    from PIL import Image

    selection = json.loads((out_dir / "selection.json").read_text(encoding="utf-8"))
    cache_path = out_dir / "sizes.json"
    sizes: dict[str, list[int]] = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    splits: dict[str, list[Sample]] = {"train": [], "val": []}
    changed = False
    for item in selection["images"]:
        path = images_dir / f"{item['id']}.jpg"
        if not path.exists():
            continue
        if item["id"] not in sizes:
            with Image.open(path) as img:
                sizes[item["id"]] = [img.width, img.height]
            changed = True
        w, h = sizes[item["id"]]
        boxes = [(x0 * w, y0 * h, (x1 - x0) * w, (y1 - y0) * h) for _, x0, y0, x1, y1 in item["boxes"]]
        splits[item["split"]].append(Sample(path, w, h, boxes, [b[0] for b in item["boxes"]], "open_images_v7"))
    if changed:
        cache_path.write_text(json.dumps(sizes), encoding="utf-8")
    return splits, [c["name"] for c in selection["classes"]]
