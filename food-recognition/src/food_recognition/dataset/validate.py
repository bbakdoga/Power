"""Full dataset validation: annotations, image files, rights, duplicates and class balance."""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
from PIL import UnidentifiedImageError

from .coco import CocoDataset, validate_annotations
from .images import dhash, read_image_info, sha256_file
from .issues import Issue, errors, warnings
from .manifest import ImageRecord, Source, check_record_rights
from .taxonomy import Taxonomy


@dataclass
class ValidationSettings:
    allowed_image_formats: set[str] = field(default_factory=lambda: {"JPEG", "PNG", "HEIF", "WEBP"})
    min_image_side: int = 224
    max_image_side: int = 8192
    min_box_side: float = 8.0
    bbox_tolerance: float = 1.0
    near_duplicate_hamming: int = 4
    min_instances_per_class: int = 50
    max_imbalance_ratio: float = 20.0
    allow_images_without_boxes: bool = True
    allowed_licenses: set[str] = field(default_factory=set)
    require_commercial_use: bool = True
    require_review_for_source_types: set[str] = field(default_factory=lambda: {"user_correction"})

    @classmethod
    def from_config(cls, cfg: dict[str, Any]) -> ValidationSettings:
        v = cfg.get("validation", {})
        r = cfg.get("rights", {})
        return cls(
            allowed_image_formats=set(v.get("allowed_image_formats", ["JPEG", "PNG", "HEIF", "WEBP"])),
            min_image_side=int(v.get("min_image_side", 224)),
            max_image_side=int(v.get("max_image_side", 8192)),
            min_box_side=float(v.get("min_box_side", 8)),
            bbox_tolerance=float(v.get("bbox_tolerance", 1.0)),
            near_duplicate_hamming=int(v.get("near_duplicate_hamming", 4)),
            min_instances_per_class=int(v.get("min_instances_per_class", 50)),
            max_imbalance_ratio=float(v.get("max_imbalance_ratio", 20.0)),
            allow_images_without_boxes=bool(v.get("allow_images_without_boxes", True)),
            allowed_licenses=set(r.get("allowed_licenses", [])),
            require_commercial_use=bool(r.get("require_commercial_use", True)),
            require_review_for_source_types=set(r.get("require_review_for_source_types", ["user_correction"])),
        )


@dataclass
class ValidationResult:
    issues: list[Issue]
    class_counts: dict[str, int]
    image_count: int
    annotation_count: int
    exact_duplicates: list[list[str]]
    near_duplicates: list[tuple[str, str, int]]
    hashes: dict[str, str]          # file -> sha256
    dhashes: dict[str, int]         # file -> dHash

    @property
    def ok(self) -> bool:
        return not errors(self.issues)

    def summary(self) -> dict[str, Any]:
        codes = Counter(i.code for i in self.issues)
        return {
            "ok": self.ok,
            "images": self.image_count,
            "annotations": self.annotation_count,
            "errors": len(errors(self.issues)),
            "warnings": len(warnings(self.issues)),
            "issue_counts": dict(sorted(codes.items())),
            "class_counts": self.class_counts,
            "exact_duplicate_groups": len(self.exact_duplicates),
            "near_duplicate_pairs": len(self.near_duplicates),
        }


def find_near_duplicates(dhashes: dict[str, int], max_distance: int) -> list[tuple[str, str, int]]:
    """All pairs within max_distance bits. Vectorised O(n^2): ~30k images take seconds, not hours."""
    items = sorted(dhashes.items())
    if len(items) < 2:
        return []
    files = [f for f, _ in items]
    hashes = np.array([h for _, h in items], dtype=np.uint64)
    pairs: list[tuple[str, str, int]] = []
    for i in range(len(items) - 1):
        xor = np.bitwise_xor(hashes[i + 1:], hashes[i])
        distances = _popcount64(xor)
        for j in np.nonzero(distances <= max_distance)[0]:
            pairs.append((files[i], files[i + 1 + int(j)], int(distances[j])))
    return pairs


_BYTE_BITS = np.array([bin(b).count("1") for b in range(256)], dtype=np.uint8)


def _popcount64(values: np.ndarray) -> np.ndarray:
    """Bits set in each uint64 (works on every NumPy version we support)."""
    as_bytes = values.astype("<u8").view(np.uint8).reshape(-1, 8)
    return _BYTE_BITS[as_bytes].sum(axis=1, dtype=np.int64)


def class_balance_issues(counts: dict[str, int], taxonomy: Taxonomy, settings: ValidationSettings) -> list[Issue]:
    issues: list[Issue] = []
    active = [c.name for c in taxonomy.active]
    for name in active:
        n = counts.get(name, 0)
        if n < settings.min_instances_per_class:
            issues.append(Issue("warning", "class_underrepresented",
                                f"{name}: {n} boxes (< {settings.min_instances_per_class})", extra={"class": name, "count": n}))
    present = [counts[name] for name in active if counts.get(name, 0) > 0]
    if present and min(present) > 0 and max(present) / min(present) > settings.max_imbalance_ratio:
        issues.append(Issue("warning", "class_imbalance",
                            f"largest/smallest class ratio {max(present) / min(present):.1f} > {settings.max_imbalance_ratio}"))
    return issues


def validate_dataset(dataset: CocoDataset, taxonomy: Taxonomy, records: list[ImageRecord],
                     sources: dict[str, Source], raw_dir: str | Path,
                     settings: ValidationSettings, *, check_files: bool = True) -> ValidationResult:
    raw_dir = Path(raw_dir)
    issues: list[Issue] = list(validate_annotations(
        dataset, taxonomy, min_box_side=settings.min_box_side, bbox_tolerance=settings.bbox_tolerance,
        allow_images_without_boxes=settings.allow_images_without_boxes))

    # --- rights manifest ---------------------------------------------------
    by_file: dict[str, ImageRecord] = {}
    for record in records:
        if record.file in by_file:
            issues.append(Issue("error", "manifest_duplicate", "two manifest records for one file", record.file))
        by_file[record.file] = record
    for img in dataset.images:
        img_record = by_file.get(img.file_name)
        if img_record is None:
            issues.append(Issue("error", "manifest_missing", "image has no rights record in the manifest", img.file_name))
            continue
        issues.extend(check_record_rights(
            img_record, sources, allowed_licenses=settings.allowed_licenses,
            require_commercial_use=settings.require_commercial_use,
            require_review_for=settings.require_review_for_source_types))
    annotated_files = {img.file_name for img in dataset.images}
    for record in records:
        if record.file not in annotated_files:
            issues.append(Issue("warning", "manifest_unannotated", "in manifest but not in annotations", record.file))

    # --- image files ---------------------------------------------------------
    hashes: dict[str, str] = {}
    dhashes: dict[str, int] = {}
    if check_files:
        for img in dataset.images:
            path = raw_dir / img.file_name
            if not path.is_file():
                issues.append(Issue("error", "file_missing", f"{path} does not exist", img.file_name))
                continue
            try:
                info = read_image_info(path)
            except (UnidentifiedImageError, OSError, SyntaxError) as exc:
                issues.append(Issue("error", "file_unreadable", f"cannot decode: {exc}", img.file_name))
                continue
            if info.format not in settings.allowed_image_formats:
                issues.append(Issue("error", "file_bad_format", f"format {info.format}", img.file_name))
            if (info.width, info.height) != (img.width, img.height):
                issues.append(Issue("error", "file_size_mismatch",
                                    f"file is {info.width}x{info.height} (after EXIF rotation), annotations say "
                                    f"{img.width}x{img.height}", img.file_name))
            if min(info.width, info.height) < settings.min_image_side:
                issues.append(Issue("warning", "file_too_small", f"short side < {settings.min_image_side}px", img.file_name))
            if max(info.width, info.height) > settings.max_image_side:
                issues.append(Issue("warning", "file_too_large", f"long side > {settings.max_image_side}px", img.file_name))
            digest = sha256_file(path)
            hashes[img.file_name] = digest
            known = by_file.get(img.file_name)
            if known is not None and known.sha256 != digest:
                issues.append(Issue("error", "manifest_hash_mismatch",
                                    "file changed since import (sha256 differs from manifest)", img.file_name))
            dhashes[img.file_name] = dhash(path)

    groups: dict[str, list[str]] = defaultdict(list)
    for file_name, digest in hashes.items():
        groups[digest].append(file_name)
    exact = [sorted(files) for files in groups.values() if len(files) > 1]
    for files in exact:
        issues.append(Issue("error", "duplicate_exact", f"identical files: {', '.join(files)}", files[0]))
    near = find_near_duplicates(dhashes, settings.near_duplicate_hamming)
    exact_pairs = {(a, b) for files in exact for i, a in enumerate(files) for b in files[i + 1:]}
    near = [p for p in near if (p[0], p[1]) not in exact_pairs]
    for a, b, distance in near:
        issues.append(Issue("warning", "duplicate_near", f"near duplicate of {b} (dHash distance {distance})", a))

    # --- class balance -------------------------------------------------------
    names = {c.id: c.name for c in taxonomy.all_categories()}
    counts = Counter(names.get(a.category_id, f"id_{a.category_id}") for a in dataset.annotations)
    class_counts = {name: counts.get(name, 0) for name in [taxonomy.unknown.name, *[c.name for c in taxonomy.classes]]}
    issues.extend(class_balance_issues(class_counts, taxonomy, settings))

    return ValidationResult(issues=issues, class_counts=class_counts, image_count=len(dataset.images),
                            annotation_count=len(dataset.annotations), exact_duplicates=exact,
                            near_duplicates=near, hashes=hashes, dhashes=dhashes)
