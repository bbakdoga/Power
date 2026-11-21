from __future__ import annotations

import shutil
from dataclasses import replace

from food_recognition.dataset.coco import parse_coco
from food_recognition.dataset.images import dhash, hamming
from food_recognition.dataset.issues import errors
from food_recognition.dataset.manifest import check_record_rights, parse_records
from food_recognition.dataset.validate import ValidationSettings, validate_dataset

from .conftest import make_image

ALLOWED = {"owned", "permission-commercial", "CC-BY-2.0", "user-correction-consented"}


def settings(**overrides):
    return ValidationSettings(**{"allowed_licenses": ALLOWED, "min_instances_per_class": 1, **overrides})


def run(taxonomy, built, sources, **overrides):
    data = built["coco"]
    data["categories"] = taxonomy.coco_categories()
    dataset, _ = parse_coco(data)
    return validate_dataset(dataset, taxonomy, built["records"], sources, built["raw"], settings(**overrides))


def codes(result):
    return {i.code for i in result.issues}


def test_clean_dataset_passes(taxonomy, small_dataset, owned_source):
    result = run(taxonomy, small_dataset(), owned_source)
    assert result.ok, [i for i in result.issues if i.severity == "error"]
    assert result.image_count == 4 and result.annotation_count == 4
    assert result.class_counts["grilled_chicken"] == 2


def test_missing_and_corrupt_files(taxonomy, small_dataset, owned_source):
    built = small_dataset()
    (built["raw"] / built["coco"]["images"][0]["file_name"]).unlink()
    (built["raw"] / built["coco"]["images"][1]["file_name"]).write_bytes(b"not an image")
    found = codes(run(taxonomy, built, owned_source))
    assert {"file_missing", "file_unreadable"} <= found


def test_size_mismatch_and_hash_mismatch(taxonomy, small_dataset, owned_source):
    built = small_dataset()
    built["coco"]["images"][0]["width"] = 999
    built["coco"]["annotations"][0]["bbox"] = [1, 1, 20, 20]
    make_image(built["raw"] / built["coco"]["images"][1]["file_name"], seed=99)  # file replaced after import
    found = codes(run(taxonomy, built, owned_source))
    assert {"file_size_mismatch", "manifest_hash_mismatch"} <= found


def test_exact_and_near_duplicates(taxonomy, small_dataset, owned_source, tmp_path):
    built = small_dataset()
    raw = built["raw"]
    shutil.copy(raw / "owned/img_0.png", raw / "owned/img_1.png")
    built["records"][1].sha256 = built["records"][0].sha256
    from PIL import Image
    with Image.open(raw / "owned/img_2.png") as img:
        img.convert("RGB").save(raw / "owned/img_3.jpg", "JPEG", quality=70)  # recompressed copy
    built["coco"]["images"][3]["file_name"] = "owned/img_3.jpg"
    from food_recognition.dataset.images import sha256_file
    built["records"][3] = replace(built["records"][3], file="owned/img_3.jpg", sha256=sha256_file(raw / "owned/img_3.jpg"))
    result = run(taxonomy, built, owned_source)
    assert "duplicate_exact" in {i.code for i in errors(result.issues)}
    assert any({a, b} == {"owned/img_2.png", "owned/img_3.jpg"} for a, b, _ in result.near_duplicates)


def test_dhash_is_stable_under_resize(tmp_path):
    from PIL import Image
    original = make_image(tmp_path / "a.png", seed=5, size=(400, 300))
    with Image.open(original) as img:
        img.resize((200, 150)).save(tmp_path / "b.png")
    assert hamming(dhash(original), dhash(tmp_path / "b.png")) <= 4
    other = make_image(tmp_path / "c.png", seed=6, size=(400, 300))
    assert hamming(dhash(original), dhash(other)) > 4


def test_image_without_manifest_record_fails(taxonomy, small_dataset, owned_source):
    built = small_dataset()
    built["records"].pop(0)
    assert "manifest_missing" in codes(run(taxonomy, built, owned_source))


def test_class_balance_warnings(taxonomy, small_dataset, owned_source):
    result = run(taxonomy, small_dataset(), owned_source, min_instances_per_class=1)
    under = [i for i in result.issues if i.code == "class_underrepresented"]
    assert len(under) == len(taxonomy.active) - 3   # every class except the three used
    assert all(i.severity == "warning" for i in under)


def test_rights_rules(owned_source):
    base, _ = parse_records(['{"file": "x.jpg", "sha256": "0", "source_id": "owned", "source_type": "owned", '
                             '"license": "owned", "commercial_use": true, "redistribution": true, '
                             '"review_status": "approved", "reviewer": "b"}'])
    record = base[0]
    assert check_record_rights(record, owned_source, allowed_licenses=ALLOWED) == []

    def err(**changes):
        return {i.code for i in check_record_rights(replace(record, **changes), owned_source, allowed_licenses=ALLOWED)}

    assert "rights_license_not_allowed" in err(license="CC-BY-NC-4.0")
    assert "rights_not_commercial" in err(commercial_use=False)
    assert "rights_unknown_source" in err(source_id="mystery")
    assert "rights_source_not_commercial" in err(source_id="nc", source_type="open_dataset")
    assert "consent_withdrawn" in err(consent_status="withdrawn")
    assert "review_rejected" in err(review_status="rejected")
    assert "rights_missing_attribution" in err(license="CC-BY-2.0")


def test_unknown_manifest_fields_are_kept_as_extra():
    records, issues = parse_records(['{"file": "x.jpg", "sha256": "0", "source_id": "s", "source_type": "owned", '
                                     '"license": "owned", "commercial_use": true, "redistribution": true, "camera": "x"}',
                                     "not json"])
    assert records[0].extra == {"camera": "x"}
    assert [i.code for i in issues] == ["manifest_malformed"]
