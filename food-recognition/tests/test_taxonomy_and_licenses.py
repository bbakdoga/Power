from __future__ import annotations

from dataclasses import replace

from food_recognition.config import load_yaml
from food_recognition.dataset.labelstudio import labeling_config
from food_recognition.dataset.taxonomy import check_taxonomy
from food_recognition.licensing import LicenseError, assets_used_by, check_assets, load_assets, require_approved

from .conftest import ROOT


def test_taxonomy_size_and_uniqueness(taxonomy):
    assert 30 <= len(taxonomy.active) <= 50
    assert check_taxonomy(taxonomy) == []
    assert taxonomy.unknown.name == "unknown_food"
    assert taxonomy.unknown.name not in taxonomy.classifier_labels()


def test_taxonomy_detects_duplicates(taxonomy):
    broken = replace(taxonomy, classes=(*taxonomy.classes, replace(taxonomy.classes[0])))
    assert any("duplicate" in p for p in check_taxonomy(broken))


def test_coco_categories_cover_unknown(taxonomy):
    ids = [c["id"] for c in taxonomy.coco_categories()]
    assert ids[0] == 0 and ids == sorted(ids)


def test_labelstudio_config_lists_every_label(taxonomy):
    xml = labeling_config(taxonomy)
    for name in [taxonomy.unknown.name, *taxonomy.classifier_labels()]:
        assert f'value="{name}"' in xml


def test_shipped_training_configs_pass_licence_gate():
    registry = load_assets(ROOT / "licenses" / "assets.yaml")
    for name in ("detection", "classification"):
        cfg = load_yaml(ROOT / "configs" / f"{name}.yaml")
        assert check_assets(assets_used_by(cfg), registry) == [], name


def test_licence_gate_blocks_unapproved_assets():
    registry = load_assets(ROOT / "licenses" / "assets.yaml")
    assert registry["ultralytics_yolo"].status == "blocked"
    assert registry["food101"].status == "blocked"
    cfg = {"assets": ["yolox_code"], "model": {"pretrained": "imagenet_weights"}}
    try:
        require_approved(cfg, registry)
    except LicenseError as exc:
        assert "imagenet_weights" in str(exc)
    else:
        raise AssertionError("needs_review weights must be blocked")
    assert check_assets(["made_up"], registry) == ["made_up: not listed in licenses/assets.yaml"]

