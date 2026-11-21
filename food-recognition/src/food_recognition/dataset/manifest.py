"""Per-image rights and consent manifest (JSON Lines) and the source registry.

Every image used for training has exactly one record saying where it came from,
under which licence, whether commercial use and redistribution are allowed, and
(for user corrections) which consent version the user agreed to.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Literal

from ..config import load_yaml
from .issues import Issue

SourceType = Literal["owned", "permission", "open_dataset", "user_correction"]
ConsentStatus = Literal["not_required", "granted", "withdrawn"]
ReviewStatus = Literal["unreviewed", "approved", "rejected"]

SOURCE_TYPES = {"owned", "permission", "open_dataset", "user_correction"}
CONSENT_STATUSES = {"not_required", "granted", "withdrawn"}
REVIEW_STATUSES = {"unreviewed", "approved", "rejected"}
SPLITS = {"train", "val", "test"}


@dataclass
class Source:
    source_id: str
    source_type: str
    license: str
    commercial_use: bool
    redistribution: bool
    description: str = ""
    contact: str | None = None
    permission_document: str | None = None
    pinned_split: str | None = None


@dataclass
class ImageRecord:
    file: str                      # path relative to data/raw
    sha256: str
    source_id: str
    source_type: str
    license: str
    commercial_use: bool
    redistribution: bool
    consent_status: str = "not_required"
    consent_version: str | None = None
    group_id: str | None = None
    attribution: str | None = None
    captured_at: str | None = None
    imported_at: str | None = None
    review_status: str = "unreviewed"
    reviewer: str | None = None
    notes: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def split_group(self) -> str:
        return self.group_id or self.source_id

    def to_json(self) -> str:
        data = asdict(self)
        if not data["extra"]:
            data.pop("extra")
        return json.dumps(data, ensure_ascii=False, sort_keys=True)


_RECORD_FIELDS = {f for f in ImageRecord.__dataclass_fields__}


def load_sources(path: str | Path) -> dict[str, Source]:
    raw = load_yaml(path).get("sources", []) or []
    sources: dict[str, Source] = {}
    for entry in raw:
        src = Source(**entry)
        if src.source_id in sources:
            raise ValueError(f"source {src.source_id} listed twice in {path}")
        sources[src.source_id] = src
    return sources


def parse_records(lines: Iterable[str]) -> tuple[list[ImageRecord], list[Issue]]:
    records: list[ImageRecord] = []
    issues: list[Issue] = []
    for number, line in enumerate(lines, start=1):
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            known = {k: v for k, v in data.items() if k in _RECORD_FIELDS}
            unknown = {k: v for k, v in data.items() if k not in _RECORD_FIELDS}
            if unknown:
                known["extra"] = {**known.get("extra", {}), **unknown}
            records.append(ImageRecord(**known))
        except (json.JSONDecodeError, TypeError) as exc:
            issues.append(Issue("error", "manifest_malformed", f"line {number}: {exc}"))
    return records, issues


def load_manifest(path: str | Path) -> tuple[list[ImageRecord], list[Issue]]:
    with open(path, encoding="utf-8") as handle:
        return parse_records(handle)


def append_records(path: str | Path, records: Iterable[ImageRecord]) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        for record in records:
            handle.write(record.to_json() + "\n")


def write_manifest(path: str | Path, records: Iterable[ImageRecord]) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(record.to_json() + "\n")


def check_record_rights(record: ImageRecord, sources: dict[str, Source], *, allowed_licenses: set[str],
                        require_commercial_use: bool = True,
                        require_review_for: set[str] | None = None) -> list[Issue]:
    """Rights and consent rules for one image. Any error keeps it out of training."""
    issues: list[Issue] = []
    where = record.file
    require_review_for = require_review_for if require_review_for is not None else {"user_correction"}

    source = sources.get(record.source_id)
    if source is None:
        issues.append(Issue("error", "rights_unknown_source", f"source {record.source_id!r} is not in sources.yaml", where))
    else:
        if source.source_type != record.source_type:
            issues.append(Issue("error", "rights_source_type_mismatch",
                                f"record says {record.source_type}, source says {source.source_type}", where))
        if require_commercial_use and not source.commercial_use:
            issues.append(Issue("error", "rights_source_not_commercial", "source does not allow commercial use", where))
        if source.source_type == "permission" and not source.permission_document:
            issues.append(Issue("error", "rights_missing_permission",
                                "permission source has no permission_document on file", where))

    if record.source_type not in SOURCE_TYPES:
        issues.append(Issue("error", "rights_bad_source_type", f"unknown source_type {record.source_type!r}", where))
    if record.license not in allowed_licenses:
        issues.append(Issue("error", "rights_license_not_allowed",
                            f"licence {record.license!r} is not in the allowed list", where))
    if require_commercial_use and record.commercial_use is not True:
        issues.append(Issue("error", "rights_not_commercial", "commercial_use is not true", where))
    if record.license.startswith("CC-BY") and not record.attribution:
        issues.append(Issue("error", "rights_missing_attribution", "CC BY images need an attribution string", where))

    if record.consent_status not in CONSENT_STATUSES:
        issues.append(Issue("error", "consent_bad_status", f"unknown consent_status {record.consent_status!r}", where))
    elif record.consent_status == "withdrawn":
        issues.append(Issue("error", "consent_withdrawn", "consent was withdrawn; remove this image", where))
    if record.source_type == "user_correction":
        if record.consent_status != "granted":
            issues.append(Issue("error", "consent_missing", "user corrections need consent_status granted", where))
        if not record.consent_version:
            issues.append(Issue("error", "consent_version_missing", "user corrections need consent_version", where))

    if record.review_status not in REVIEW_STATUSES:
        issues.append(Issue("error", "review_bad_status", f"unknown review_status {record.review_status!r}", where))
    elif record.review_status == "rejected":
        issues.append(Issue("error", "review_rejected", "image was rejected in review", where))
    elif record.source_type in require_review_for and record.review_status != "approved":
        issues.append(Issue("error", "review_required", f"{record.source_type} images must be reviewed first", where))
    if record.review_status == "approved" and not record.reviewer:
        issues.append(Issue("warning", "review_no_reviewer", "approved without a reviewer name", where))
    return issues
