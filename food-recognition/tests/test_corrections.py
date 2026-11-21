from __future__ import annotations

import copy

from food_recognition.dataset.corrections import (
    ReviewDecision,
    correction_to_record,
    promote_reviewed,
    validate_correction,
)
from food_recognition.dataset.manifest import Source, check_record_rights

ACCEPTED = {"food-corrections-v1"}

BUNDLE = {
    "schema_version": "1",
    "scan_id": "scan-1",
    "image_sha256": "abc",
    "image_width": 1000,
    "image_height": 800,
    "captured_at": "2026-11-20T19:02:00Z",
    "submitted_at": "2026-11-20T19:03:10Z",
    "app_version": "1.4.0",
    "model_version": "0.1.0",
    "consent": {"granted": True, "version": "food-corrections-v1", "granted_at": "2026-11-20T19:03:05Z",
                "scope": "model-training"},
    "regions": [{"bbox": [10, 10, 300, 200], "confirmed_label": "salmon", "predicted": []}],
}


def codes(bundle, taxonomy):
    return {i.code for i in validate_correction(bundle, taxonomy, ACCEPTED)}


def test_valid_bundle(taxonomy):
    assert validate_correction(BUNDLE, taxonomy, ACCEPTED) == []


def test_consent_is_required(taxonomy):
    b = copy.deepcopy(BUNDLE)
    b["consent"]["granted"] = False
    assert "correction_no_consent" in codes(b, taxonomy)
    b = copy.deepcopy(BUNDLE)
    b["consent"]["version"] = "old"
    assert "correction_consent_version" in codes(b, taxonomy)


def test_personal_data_is_rejected(taxonomy):
    b = copy.deepcopy(BUNDLE)
    b["device"] = {"device_id": "XYZ"}
    b["location"] = [1, 2]
    assert "correction_personal_data" in codes(b, taxonomy)


def test_bad_label_and_box(taxonomy):
    b = copy.deepcopy(BUNDLE)
    b["regions"] = [{"bbox": [900, 10, 300, 200], "confirmed_label": "lasagna"}]
    assert {"correction_bad_label", "correction_bad_bbox"} <= codes(b, taxonomy)


def test_unreviewed_corrections_cannot_enter_training():
    record = correction_to_record(BUNDLE, "user_corrections/scan-1.jpg")
    assert record.review_status == "unreviewed"
    sources = {"user_corrections": Source("user_corrections", "user_correction", "user-correction-consented",
                                          True, False)}
    found = {i.code for i in check_record_rights(record, sources, allowed_licenses={"user-correction-consented"})}
    assert found == {"review_required"}


def test_only_approved_decisions_are_promoted():
    pending = []
    for scan in ("a", "b", "c", "d"):
        bundle = copy.deepcopy(BUNDLE)
        bundle["scan_id"] = scan
        pending.append(correction_to_record(bundle, f"user_corrections/{scan}.jpg"))
    decisions = [
        ReviewDecision("a", "approved", "baris", "2026-11-21T10:00:00Z"),
        ReviewDecision("b", "rejected", "baris", "2026-11-21T10:00:00Z"),
        ReviewDecision("c", "approved", "", "2026-11-21T10:00:00Z"),   # no reviewer -> not a decision
    ]
    promoted, waiting = promote_reviewed(pending, decisions)
    assert [r.extra["scan_id"] for r in promoted] == ["a"]
    assert promoted[0].review_status == "approved" and promoted[0].reviewer == "baris"
    assert sorted(waiting) == ["c", "d"]
