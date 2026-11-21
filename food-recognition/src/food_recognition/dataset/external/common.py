"""Shared helpers for external dataset importers."""

from __future__ import annotations

import re
import shutil
import tarfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from ..images import sha256_file


@dataclass
class ImportStats:
    images_added: int = 0
    images_skipped_duplicate: int = 0
    images_skipped_license: int = 0
    images_skipped_missing: int = 0
    images_skipped_other: int = 0
    boxes_added: int = 0
    boxes_unknown_food: int = 0
    boxes_dropped: int = 0
    images_to_annotate: int = 0
    per_class: dict[str, int] = field(default_factory=dict)

    def count_class(self, name: str, n: int = 1) -> None:
        self.per_class[name] = self.per_class.get(name, 0) + n

    def lines(self) -> list[str]:
        out = [f"images added: {self.images_added}", f"boxes added: {self.boxes_added} "
               f"({self.boxes_unknown_food} as unknown_food, {self.boxes_dropped} dropped)"]
        for label, value in (("skipped, already imported", self.images_skipped_duplicate),
                             ("skipped, licence not allowed", self.images_skipped_license),
                             ("skipped, image file missing", self.images_skipped_missing),
                             ("skipped, other", self.images_skipped_other),
                             ("added without boxes, to annotate", self.images_to_annotate)):
            if value:
                out.append(f"{label}: {value}")
        if self.per_class:
            out.append("boxes per class: " + ", ".join(f"{k} {v}" for k, v in sorted(self.per_class.items())))
        return out


def copy_unique(src: Path, raw_dir: Path, source_id: str, known_hashes: set[str]) -> tuple[str, str] | None:
    """Copy src into data/raw/<source_id>/ named by content hash. None if already imported."""
    digest = sha256_file(src)
    if digest in known_hashes:
        return None
    known_hashes.add(digest)
    dest = raw_dir / source_id / f"{digest[:16]}{src.suffix.lower() or '.jpg'}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        shutil.copy2(src, dest)
    return str(dest.relative_to(raw_dir)), digest


def extract_archive(archive: Path, cache_dir: Path) -> Path:
    """Extract a .tar.gz or .zip once into cache_dir/<archive name> and return that folder."""
    target = cache_dir / re.sub(r"\.tar\.gz$|\.tgz$|\.tar$|\.zip$", "", archive.name)
    marker = target / ".extracted"
    if marker.exists():
        return target
    target.mkdir(parents=True, exist_ok=True)
    if archive.suffix.lower() == ".zip":  # e.g. a Kaggle download
        root = target.resolve()
        with zipfile.ZipFile(archive) as zf:
            for member in zf.namelist():
                if not (target / member).resolve().is_relative_to(root):
                    raise ValueError(f"unsafe path in {archive.name}: {member}")
            zf.extractall(target)
    else:
        with tarfile.open(archive) as tar:
            tar.extractall(target, filter="data")
    marker.touch()
    return target


def bbox_from_polygons(segmentation: list[list[float]]) -> tuple[float, float, float, float] | None:
    xs = [p for poly in segmentation for p in poly[0::2]]
    ys = [p for poly in segmentation for p in poly[1::2]]
    if not xs or not ys:
        return None
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)
