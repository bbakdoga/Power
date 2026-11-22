"""Training building blocks and the Open Images pretraining pipeline on tiny synthetic data."""

from __future__ import annotations

import csv
import shutil

import pytest
import yaml

from food_recognition.training.data import class_balanced_weights, padded_box

from .conftest import ROOT, make_image


def test_class_balanced_weights_give_each_class_equal_mass():
    labels = [0, 0, 0, 1, -1, -1]
    weights = class_balanced_weights(labels, num_classes=3, unknown_share=0.2)
    mass = {lab: sum(w for w, x in zip(weights, labels, strict=True) if x == lab) for lab in set(labels)}
    assert mass[0] == pytest.approx(mass[1]) == pytest.approx(0.4)
    assert mass[-1] == pytest.approx(0.2)


def test_padded_box_is_clipped_to_the_image():
    assert padded_box((0, 0, 100, 50), 0.1, 105, 60) == (0, 0, 105, 55)
    assert padded_box((50, 20, 10, 10), 0.0, 200, 200) == (50, 20, 60, 30)


def test_yolox_tiny_size_and_outputs():
    torch = pytest.importorskip("torch")
    from food_recognition.detection.yolox import build

    model = build("yolox_tiny", 1)
    params = sum(p.numel() for p in model.parameters()) / 1e6
    assert 4.9 < params < 5.2          # YOLOX-Tiny is ~5.06M parameters
    model.eval()
    out = model(torch.zeros(1, 3, 416, 416))
    assert out.shape == (1, (52 * 52 + 26 * 26 + 13 * 13), 6)


def _write_csv(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)


@pytest.fixture
def project(tmp_path, monkeypatch):
    for folder in ("configs", "licenses"):
        shutil.copytree(ROOT / folder, tmp_path / folder)
    monkeypatch.setenv("FOOD_REC_ROOT", str(tmp_path))
    monkeypatch.setenv("SLURM_CPUS_PER_TASK", "0")
    return tmp_path


def test_openimages_pretraining_pipeline(project, tmp_path):
    pytest.importorskip("torch")
    pytest.importorskip("timm")
    from food_recognition.cli import main
    from food_recognition.training.common import PRETRAINED_WEIGHTS

    csvs = tmp_path / "csv"
    csvs.mkdir()
    cc_by = "https://creativecommons.org/licenses/by/2.0/"
    ids = [f"{i:016x}" for i in range(12)]
    _write_csv(csvs / "classes.csv", ["LabelName", "DisplayName"], [["/m/a", "Apple"], ["/m/b", "Table"]])
    meta = [[i, "train", "u", "l", cc_by, "p", "someone", "t", "1", "md5", "x", "0"] for i in ids]
    meta.append(["ffffffffffffffff", "train", "u", "l", "https://example.com/other", "p", "a", "t", "1", "m", "x", "0"])
    _write_csv(csvs / "meta.csv", ["ImageID", "Subset", "OriginalURL", "OriginalLandingURL", "License", "AuthorProfileURL",
                                   "Author", "Title", "OriginalSize", "OriginalMD5", "Thumbnail300KURL", "Rotation"], meta)
    boxes = [[i, "xclick", "/m/a" if n % 2 else "/m/b", "1", "0.1", "0.6", "0.2", "0.7", "0", "0", "0", "0", "0"]
             for n, i in enumerate(ids + ["ffffffffffffffff"])]
    _write_csv(csvs / "boxes.csv", ["ImageID", "Source", "LabelName", "Confidence", "XMin", "XMax", "YMin", "YMax",
                                    "IsOccluded", "IsTruncated", "IsGroupOf", "IsDepiction", "IsInside"], boxes)

    assert main(["select-openimages-pretrain", "--classes-csv", str(csvs / "classes.csv"), "--boxes-csv",
                 str(csvs / "boxes.csv"), "--metadata-csv", str(csvs / "meta.csv"), "--max-images", "100"]) == 0
    out = project / "data/pretrain/openimages"
    assert len((out / "ids.txt").read_text().split()) == 12          # the non-CC-BY photo is left out
    assert "someone" in (out / "attributions.tsv").read_text()
    for i in ids:
        make_image(out / "images" / f"{i}.jpg", seed=int(i, 16), size=(96, 80)).rename(out / "images" / f"{i}.jpg")

    for kind, name in (("detection", "detector"), ("classification", "classifier")):
        cfg = yaml.safe_load((project / f"configs/pretrain/{kind}_openimages.yaml").read_text())
        cfg["train"].update({"epochs": 1, "batch_size": 4, "warmup_epochs": 0, "eval_every": 1, "mixed_precision": False})
        cfg["model"]["input_size"] = [64, 64] if kind == "detection" else 64
        tiny = project / f"tiny_{kind}.yaml"
        tiny.write_text(yaml.safe_dump(cfg))
        assert main([f"pretrain-{name}", "--config", str(tiny)]) == 0
        assert (project / PRETRAINED_WEIGHTS["openimages_pretrain_own"][kind]).exists()
    # A job that hit its time limit continues from resume.pt in the same run folder.
    run = next((project / "models/runs/detection-pretrain").glob("openimages-*"))
    (run / "summary.json").unlink()
    assert main(["pretrain-detector", "--config", str(project / "tiny_detection.yaml"), "--resume", str(run)]) == 0
    assert (run / "summary.json").exists()
