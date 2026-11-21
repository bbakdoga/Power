"""Import images we own or have permission to use, recording rights for each one."""

from __future__ import annotations

import shutil
from datetime import datetime, timezone
from pathlib import Path

from .images import sha256_file
from .manifest import ImageRecord, Source

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp"}


class ImportRefused(RuntimeError):
    """The source does not grant the rights we need."""


def import_folder(folder: str | Path, source: Source, raw_dir: str | Path, *, allowed_licenses: set[str],
                  existing_hashes: set[str], group_id: str | None = None,
                  attribution: str | None = None) -> tuple[list[ImageRecord], list[str]]:
    """Copy images into data/raw/<source_id>/ and return manifest records.

    Refuses the whole import if the source is not cleared for commercial use.
    Files already imported (same sha256) are skipped and returned as the
    second value.
    """
    if not source.commercial_use:
        raise ImportRefused(f"source {source.source_id} does not allow commercial use")
    if source.license not in allowed_licenses:
        raise ImportRefused(f"licence {source.license!r} of {source.source_id} is not in the allowed list")
    if source.source_type == "permission" and not source.permission_document:
        raise ImportRefused(f"source {source.source_id} needs a permission_document before importing")
    if source.source_type == "user_correction":
        raise ImportRefused("user corrections are imported with `food-rec import-corrections`, not here")
    if source.license.startswith("CC-BY") and not attribution:
        raise ImportRefused("CC BY images need --attribution")

    folder, raw_dir = Path(folder), Path(raw_dir)
    dest_dir = raw_dir / source.source_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    records: list[ImageRecord] = []
    skipped: list[str] = []
    seen = set(existing_hashes)
    for path in sorted(p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES):
        digest = sha256_file(path)
        if digest in seen:
            skipped.append(str(path))
            continue
        seen.add(digest)
        dest = dest_dir / f"{digest[:16]}{path.suffix.lower()}"
        shutil.copy2(path, dest)
        records.append(ImageRecord(
            file=str(dest.relative_to(raw_dir)), sha256=digest, source_id=source.source_id,
            source_type=source.source_type, license=source.license, commercial_use=source.commercial_use,
            redistribution=source.redistribution, consent_status="not_required", group_id=group_id,
            attribution=attribution, imported_at=now,
            review_status="approved" if source.source_type == "owned" else "unreviewed",
            reviewer="importer:owned" if source.source_type == "owned" else None,
            notes=f"original name: {path.name}",
        ))
    return records, skipped
