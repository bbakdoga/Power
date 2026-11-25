"""Markdown dataset report with class counts and example annotations."""

from __future__ import annotations

import random
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

from .coco import CocoDataset
from .issues import errors, warnings
from .taxonomy import Taxonomy
from .validate import ValidationResult

PALETTE = ["#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6", "#bcf60c"]


def draw_example(raw_dir: Path, dataset: CocoDataset, image_id: int, taxonomy: Taxonomy, out: Path,
                 max_side: int = 640) -> Path:
    img_meta = next(i for i in dataset.images if i.id == image_id)
    names = {c.id: c.name for c in taxonomy.all_categories()}
    with Image.open(raw_dir / img_meta.file_name) as src:
        img = ImageOps.exif_transpose(src).convert("RGB")
    draw = ImageDraw.Draw(img)
    width = max(2, round(max(img.size) / 300))
    for n, ann in enumerate(a for a in dataset.annotations if a.image_id == image_id):
        x, y, w, h = ann.bbox
        color = PALETTE[n % len(PALETTE)]
        draw.rectangle([x, y, x + w, y + h], outline=color, width=width)
        draw.text((x + 4, y + 4), names.get(ann.category_id, str(ann.category_id)), fill=color)
    img.thumbnail((max_side, max_side))
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "JPEG", quality=85)
    return out


def write_report(dataset: CocoDataset, taxonomy: Taxonomy, validation: ValidationResult, raw_dir: str | Path,
                 out_dir: str | Path, *, split_assignment: dict[str, str] | None = None,
                 examples: int = 8, seed: int = 1337) -> Path:
    raw_dir, out_dir = Path(raw_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    names = {c.id: c for c in taxonomy.all_categories()}
    lines = [
        "# Dataset report",
        "",
        f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} · taxonomy v{taxonomy.version}",
        "",
        f"- Images: **{validation.image_count}**",
        f"- Boxes: **{validation.annotation_count}**",
        f"- Validation: **{'passed' if validation.ok else 'FAILED'}** "
        f"({len(errors(validation.issues))} errors, {len(warnings(validation.issues))} warnings)",
        f"- Exact duplicate groups: {len(validation.exact_duplicates)} · near-duplicate pairs: {len(validation.near_duplicates)}",
        "",
    ]

    if split_assignment:
        file_to_id = {i.file_name: i.id for i in dataset.images}
        per_split: dict[str, Counter[int]] = {}
        image_counts: Counter[str] = Counter()
        id_to_split = {file_to_id[f]: s for f, s in split_assignment.items() if f in file_to_id}
        image_counts.update(id_to_split.values())
        for ann in dataset.annotations:
            ann_split = id_to_split.get(ann.image_id)
            if ann_split:
                per_split.setdefault(ann_split, Counter())[ann.category_id] += 1
        lines += ["## Splits", "", "| Split | Images | Boxes |", "|---|---:|---:|"]
        for split in ("train", "val", "test"):
            lines.append(f"| {split} | {image_counts.get(split, 0)} | {sum(per_split.get(split, Counter()).values())} |")
        lines.append("")
    else:
        per_split = {}

    lines += ["## Boxes per class", "", "| id | Class | Group | Total | Train | Val | Test |", "|---:|---|---|---:|---:|---:|---:|"]
    counts = validation.class_counts
    for cls in sorted(names.values(), key=lambda c: c.id):
        row = [str(cls.id), cls.name, cls.group, str(counts.get(cls.name, 0))]
        row += [str(per_split.get(s, Counter()).get(cls.id, 0)) if per_split else "–" for s in ("train", "val", "test")]
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    issue_counts = validation.summary()["issue_counts"]
    if issue_counts:
        lines += ["## Validation issues", "", "| Code | Count |", "|---|---:|"]
        lines += [f"| {code} | {n} |" for code, n in issue_counts.items()]
        lines.append("")

    annotated = sorted({a.image_id for a in dataset.annotations})
    if annotated and examples > 0:
        rng = random.Random(seed)
        chosen = rng.sample(annotated, min(examples, len(annotated)))
        lines += ["## Example annotations", ""]
        for image_id in chosen:
            try:
                path = draw_example(raw_dir, dataset, image_id, taxonomy, out_dir / "examples" / f"{image_id}.jpg")
            except (OSError, StopIteration):
                continue
            lines.append(f"![image {image_id}](examples/{path.name})")
        lines.append("")

    report_path = out_dir / "dataset_report.md"
    report_path.write_text("\n".join(lines), encoding="utf-8")
    return report_path
