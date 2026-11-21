"""Opt-in user corrections from the app.

Format and rules are in docs/user_corrections.md. In short:
- the app only uploads a scan after the user explicitly opts in;
- each bundle carries the consent version, the time, the boxes and the labels
  the user confirmed; it carries no account id, name, location or device id;
- ingested corrections are `unreviewed` and live in a staging manifest;
- only corrections a person approves are promoted into the training manifest.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from PIL import Image, ImageOps

from .issues import Issue
from .manifest import ImageRecord
from .taxonomy import Taxonomy

SCHEMA_VERSION = "1"
CORRECTIONS_SOURCE_ID = "user_corrections"
FORBIDDEN_KEYS = {"user_id", "account_id", "email", "name", "location", "gps", "latitude", "longitude",
                  "device_id", "idfa", "idfv", "ip"}


@dataclass(frozen=True)
class ReviewDecision:
    scan_id: str
    decision: str          # approved | rejected
    reviewer: str
    reviewed_at: str
    notes: str | None = None


def _walk_keys(value: Any) -> set[str]:
    keys: set[str] = set()
    if isinstance(value, dict):
        for k, v in value.items():
            keys.add(str(k).lower())
            keys |= _walk_keys(v)
    elif isinstance(value, list):
        for item in value:
            keys |= _walk_keys(item)
    return keys


def validate_correction(bundle: dict[str, Any], taxonomy: Taxonomy, accepted_consent_versions: set[str]) -> list[Issue]:
    issues: list[Issue] = []
    scan = str(bundle.get("scan_id", "?"))
    if bundle.get("schema_version") != SCHEMA_VERSION:
        issues.append(Issue("error", "correction_schema", f"schema_version must be {SCHEMA_VERSION}", scan))
    consent = bundle.get("consent") or {}
    if consent.get("granted") is not True:
        issues.append(Issue("error", "correction_no_consent", "consent.granted is not true; discard", scan))
    if consent.get("version") not in accepted_consent_versions:
        issues.append(Issue("error", "correction_consent_version",
                            f"consent version {consent.get('version')!r} is not accepted", scan))
    if consent.get("scope") != "model-training":
        issues.append(Issue("error", "correction_consent_scope", "consent.scope must be model-training", scan))
    for key in ("granted_at",):
        if not consent.get(key):
            issues.append(Issue("error", "correction_missing_field", f"consent.{key} is required", scan))
    for key in ("scan_id", "image_sha256", "image_width", "image_height", "submitted_at", "regions"):
        if key not in bundle:
            issues.append(Issue("error", "correction_missing_field", f"{key} is required", scan))
    leaked = _walk_keys(bundle) & FORBIDDEN_KEYS
    if leaked:
        issues.append(Issue("error", "correction_personal_data", f"bundle contains personal fields {sorted(leaked)}", scan))

    labels = taxonomy.by_name()
    width, height = bundle.get("image_width", 0), bundle.get("image_height", 0)
    for n, region in enumerate(bundle.get("regions") or []):
        label = region.get("confirmed_label")
        if label not in labels:
            issues.append(Issue("error", "correction_bad_label", f"region {n}: {label!r} not in taxonomy", scan))
        bbox = region.get("bbox")
        if not (isinstance(bbox, list) and len(bbox) == 4):
            issues.append(Issue("error", "correction_bad_bbox", f"region {n}: bbox must be [x, y, w, h]", scan))
            continue
        x, y, w, h = bbox
        if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > width + 1 or y + h > height + 1:
            issues.append(Issue("error", "correction_bad_bbox", f"region {n}: box {bbox} outside image", scan))
        if "calories" in region or "nutrients" in region:
            issues.append(Issue("warning", "correction_nutrition_ignored", "nutrition fields are ignored", scan))
    return issues


def correction_to_record(bundle: dict[str, Any], file: str) -> ImageRecord:
    consent = bundle["consent"]
    return ImageRecord(
        file=file, sha256=bundle["image_sha256"], source_id=CORRECTIONS_SOURCE_ID, source_type="user_correction",
        license="user-correction-consented", commercial_use=True, redistribution=False,
        consent_status="granted", consent_version=consent["version"], group_id=f"scan:{bundle['scan_id']}",
        captured_at=bundle.get("captured_at"), imported_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        review_status="unreviewed", reviewer=None,
        extra={"scan_id": bundle["scan_id"], "consent_granted_at": consent["granted_at"],
               "app_version": bundle.get("app_version"), "model_version": bundle.get("model_version")},
    )


def promote_reviewed(pending: list[ImageRecord], decisions: list[ReviewDecision]) -> tuple[list[ImageRecord], list[str]]:
    """Return records a reviewer approved (ready for the training manifest) and scan ids still waiting.

    Nothing is promoted without an explicit `approved` decision from a named reviewer.
    """
    by_scan = {d.scan_id: d for d in decisions}
    promoted: list[ImageRecord] = []
    waiting: list[str] = []
    for record in pending:
        scan_id = record.extra.get("scan_id", "")
        decision = by_scan.get(scan_id)
        if decision is None or not decision.reviewer:
            waiting.append(scan_id)
            continue
        if decision.decision != "approved" or record.consent_status != "granted":
            continue
        promoted.append(ImageRecord(**{**record.__dict__, "review_status": "approved", "reviewer": decision.reviewer,
                                       "extra": {**record.extra, "reviewed_at": decision.reviewed_at}}))
    return promoted, waiting


def strip_metadata(src: str, dst: str) -> None:
    """Re-encode an image upright without EXIF (removes GPS, device and time tags)."""
    with Image.open(src) as img:
        clean = ImageOps.exif_transpose(img).convert("RGB")
    clean.save(dst, "JPEG", quality=92)
