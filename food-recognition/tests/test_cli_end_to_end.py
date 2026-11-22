"""Runs the documented workflow on a tiny synthetic dataset in a temporary project root."""

from __future__ import annotations

import json
import shutil

import pytest

from food_recognition.cli import main
from food_recognition.dataset.manifest import load_manifest

from .conftest import ROOT, make_image

SOURCES = """
sources:
  - {source_id: kitchen, source_type: owned, license: owned, commercial_use: true, redistribution: true}
  - {source_id: phone_eval, source_type: owned, license: owned, commercial_use: true, redistribution: true,
     pinned_split: test}
  - {source_id: scraped, source_type: open_dataset, license: unknown, commercial_use: false, redistribution: false}
"""


@pytest.fixture
def project(tmp_path, monkeypatch):
    for folder in ("configs", "licenses"):
        shutil.copytree(ROOT / folder, tmp_path / folder)
    (tmp_path / "data" / "manifests").mkdir(parents=True)
    (tmp_path / "data" / "manifests" / "sources.yaml").write_text(SOURCES)
    dataset_cfg = (tmp_path / "configs" / "dataset.yaml").read_text()
    dataset_cfg = dataset_cfg.replace("min_instances_per_class: 50", "min_instances_per_class: 1")
    dataset_cfg = dataset_cfg.replace("min_image_side: 224", "min_image_side: 64")
    (tmp_path / "configs" / "dataset.yaml").write_text(dataset_cfg)
    monkeypatch.setenv("FOOD_REC_ROOT", str(tmp_path))
    return tmp_path


def annotate_everything(project):
    """Stand-in for Label Studio: one box per imported image, categories by name."""
    records, _ = load_manifest(project / "data/manifests/images.jsonl")
    images, annotations = [], []
    for n, record in enumerate(records, start=1):
        images.append({"id": n, "file_name": record.file, "width": 320, "height": 240})
        annotations.append({"id": n, "image_id": n, "category_id": n % 2, "bbox": [20, 20, 120, 90]})
    export = {"images": images, "annotations": annotations,
              "categories": [{"id": 0, "name": "Salmon"}, {"id": 1, "name": "white_rice"}]}
    path = project / "export.json"
    path.write_text(json.dumps(export))
    return path


def tiny_configs(project):
    """One-epoch CPU versions of the real configs, so the test exercises the real training loops."""
    import yaml

    paths = {}
    for kind in ("detection", "classification"):
        cfg = yaml.safe_load((project / f"configs/{kind}.yaml").read_text())
        cfg["train"].update({"epochs": 1, "batch_size": 4, "warmup_epochs": 0, "eval_every": 1, "mixed_precision": False})
        cfg["model"]["input_size"] = [64, 64] if kind == "detection" else 64
        paths[kind] = project / f"tiny_{kind}.yaml"
        paths[kind].write_text(yaml.safe_dump(cfg))
    return paths


def test_full_workflow(project, tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("SLURM_CPUS_PER_TASK", "0")
    inbox = tmp_path / "inbox"
    for i in range(20):
        make_image(inbox / "meals" / f"{i}.png", seed=i)
    for i in range(4):
        make_image(inbox / "eval" / f"{i}.png", seed=100 + i)
    make_image(inbox / "meals" / "copy.png", seed=0)  # exact duplicate, skipped on import

    assert main(["check-taxonomy"]) == 0
    assert main(["import", "--folder", str(inbox / "meals"), "--source-id", "kitchen", "--group-id", "week1"]) == 0
    assert "skipped 1 duplicates" in capsys.readouterr().out
    assert main(["import", "--folder", str(inbox / "eval"), "--source-id", "phone_eval"]) == 0
    assert main(["import", "--folder", str(inbox / "meals"), "--source-id", "scraped"]) == 1   # refused

    # give each kitchen photo its own group so the split has something to balance
    manifest = project / "data/manifests/images.jsonl"
    lines = [json.loads(line) for line in manifest.read_text().splitlines()]
    for n, rec in enumerate(lines):
        if rec["source_id"] == "kitchen":
            rec["group_id"] = f"meal{n}"
    manifest.write_text("".join(json.dumps(r) + "\n" for r in lines))

    assert main(["normalize", "--input", str(annotate_everything(project))]) == 0
    assert main(["validate"]) == 0
    assert main(["split"]) == 0
    splits = json.loads((project / "data/splits/splits.json").read_text())
    eval_files = {r["file"] for r in lines if r["source_id"] == "phone_eval"}
    assert eval_files <= set(splits["splits"]["test"])
    assert main(["report"]) == 0
    assert "## Boxes per class" in (project / "reports/dataset_report.md").read_text()
    assert main(["freeze", "--version", "v0.0.1"]) == 0
    with pytest.raises(FileExistsError):
        main(["freeze", "--version", "v0.0.1"])
    assert main(["check-licenses"]) == 0
    assert main(["labelstudio-config"]) == 0

    capsys.readouterr()
    pytest.importorskip("torch")
    pytest.importorskip("timm")
    tiny = tiny_configs(project)
    assert main(["train-detector", "--dataset-version", "v0.0.1", "--config", str(tiny["detection"])]) == 0
    assert main(["train-classifier", "--dataset-version", "v0.0.1", "--config", str(tiny["classification"])]) == 0
    runs = sorted((project / "models/runs").glob("*/*/summary.json"))
    assert len(runs) == 2
    assert {json.loads(r.read_text())["kind"] for r in runs} == {"detection", "classification"}
    assert main(["train-classifier", "--dataset-version", "v9.9.9"]) == 1
    assert "not frozen" in capsys.readouterr().out

    # editing annotations after freezing is caught before training
    annotations = project / "data/annotations/instances.json"
    annotations.write_text(annotations.read_text().replace('"iscrowd": 0', '"iscrowd": 1', 1))
    assert main(["train-detector", "--dataset-version", "v0.0.1"]) == 1
    assert "changed since it was frozen" in capsys.readouterr().out


def test_validate_fails_on_rights_problem(project, tmp_path):
    inbox = tmp_path / "inbox"
    for i in range(3):
        make_image(inbox / f"{i}.png", seed=i)
    assert main(["import", "--folder", str(inbox), "--source-id", "kitchen"]) == 0
    assert main(["normalize", "--input", str(annotate_everything(project))]) == 0
    manifest = project / "data/manifests/images.jsonl"
    manifest.write_text(manifest.read_text().replace('"commercial_use": true', '"commercial_use": false', 1))
    assert main(["validate"]) == 1
    report = json.loads((project / "reports/validation.json").read_text())
    assert "rights_not_commercial" in report["summary"]["issue_counts"]


def test_licence_gate_blocks_needs_review_weights(project):
    cfg = project / "configs/detection.yaml"
    cfg.write_text(cfg.read_text().replace("pretrained: null", "pretrained: yolox_coco_weights"))
    assert main(["check-licenses"]) == 1
