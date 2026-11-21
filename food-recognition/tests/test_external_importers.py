"""MyFoodRepo and Open Images importers on small synthetic copies of their real file layouts."""

from __future__ import annotations

import csv
import json
import shutil
import tarfile
from collections import Counter

import pytest

from food_recognition.cli import main
from food_recognition.config import load_yaml
from food_recognition.dataset.coco import CocoAnnotation, CocoDataset, CocoImage, load_coco, merge_datasets
from food_recognition.dataset.external import myfoodrepo, openimages
from food_recognition.dataset.manifest import load_manifest

from .conftest import ROOT, make_image

MFR_CATEGORIES = ["bread-wholemeal", "pizza-margherita-baked", "water", "salmon", "goat-cheese",
                  "fruit-salad", "leaf-salad-green", "hamburger-bread-meat-ketchup", "ratatouille", "egg-fried"]


def make_myfoodrepo(root, split="train", n=4, seed=0):
    folder = root / split
    images, annotations = [], []
    for i in range(n):
        name = f"{i:06d}.jpg"
        make_image(folder / "images" / name, seed=seed + i).rename(folder / "images" / name)
        images.append({"id": 100 + i, "file_name": name, "width": 320, "height": 240})
        annotations.append({"id": 1000 + i, "image_id": 100 + i, "category_id": i % len(MFR_CATEGORIES),
                            "segmentation": [[10, 10, 110, 10, 110, 90, 10, 90]], "area": 8000, "iscrowd": 0})
        annotations.append({"id": 2000 + i, "image_id": 100 + i, "category_id": 2,   # water: dropped
                            "bbox": [150, 20, 40, 60], "segmentation": [], "area": 2400, "iscrowd": 0})
    categories = [{"id": k, "name": name} for k, name in enumerate(MFR_CATEGORIES)]
    (folder / "annotations.json").write_text(json.dumps({"images": images, "annotations": annotations,
                                                         "categories": categories}))
    return folder


def test_myfoodrepo_mapping_proposal(taxonomy):
    cfg = load_yaml(ROOT / "configs/external/myfoodrepo.yaml")
    proposal = myfoodrepo.propose_mapping(Counter({n: 1 for n in MFR_CATEGORIES}), cfg, taxonomy)
    got = {k: v["class"] for k, v in proposal.items()}
    assert got == {
        "bread-wholemeal": "bread", "pizza-margherita-baked": "pizza", "water": "drop", "salmon": "salmon",
        "goat-cheese": "cheese", "fruit-salad": "unknown_food", "leaf-salad-green": "green_salad",
        "hamburger-bread-meat-ketchup": "burger", "ratatouille": "unknown_food", "egg-fried": "fried_egg",
    }


def test_open_images_mapping_names_exist():
    cfg = load_yaml(ROOT / "configs/external/open_images.yaml")
    assert len(cfg["classes"]) == 43   # all but grilled_chicken and white_fish


@pytest.fixture
def project(tmp_path, monkeypatch):
    for folder in ("configs", "licenses"):
        shutil.copytree(ROOT / folder, tmp_path / folder)
    (tmp_path / "data/manifests").mkdir(parents=True)
    shutil.copy(ROOT / "data/manifests/sources.example.yaml", tmp_path / "data/manifests/sources.yaml")
    monkeypatch.setenv("FOOD_REC_ROOT", str(tmp_path))
    return tmp_path


def test_myfoodrepo_end_to_end(project, tmp_path, capsys):
    downloads = tmp_path / "downloads"
    make_myfoodrepo(downloads / "src", "train", n=6)
    make_myfoodrepo(downloads / "src", "val", n=2, seed=50)
    archive = downloads / "train-v0.4.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(downloads / "src" / "train", arcname="train")

    assert main(["propose-mapping", str(archive), str(downloads / "src" / "val")]) == 0
    mapping = project / "configs/external/myfoodrepo_mapping_v0.4.yaml"
    assert main(["import-myfoodrepo", str(archive), str(downloads / "src" / "val")]) == 1   # not reviewed yet
    assert "has not been reviewed" in capsys.readouterr().out
    mapping.write_text(mapping.read_text().replace("reviewed: false", "reviewed: true"))

    assert main(["import-myfoodrepo", str(archive), str(downloads / "src" / "val")]) == 0
    out = capsys.readouterr().out
    assert "images added: 7" in out and "9 dropped" in out and "skipped, other: 1" in out  # water-only photo
    records, _ = load_manifest(project / "data/manifests/images.jsonl")
    assert {r.license for r in records} == {"CC-BY-4.0"} and all("Mohanty" in r.attribution for r in records)
    coco, _ = load_coco(project / "data/annotations/instances.json")
    assert len(coco.images) == 7 and len(coco.annotations) == 7
    assert coco.annotations[0].bbox == (10.0, 10.0, 100.0, 80.0)   # from the polygon

    assert main(["import-myfoodrepo", str(archive), str(downloads / "src" / "val")]) == 0   # idempotent
    assert "skipped, already imported: 7" in capsys.readouterr().out
    coco, _ = load_coco(project / "data/annotations/instances.json")
    assert len(coco.images) == 7

    cfg = (project / "configs/dataset.yaml").read_text().replace("min_image_side: 224", "min_image_side: 64")
    (project / "configs/dataset.yaml").write_text(cfg)
    assert main(["validate"]) == 0
    assert main(["attributions"]) == 0


def write_csv(path, header, rows):
    with open(path, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)
    return path


def test_open_images_end_to_end(project, tmp_path, capsys):
    oi = tmp_path / "oi"
    oi.mkdir()
    classes = write_csv(oi / "classes.csv", ["LabelName", "DisplayName"], [
        ["/m/pizza", "Pizza"], ["/m/doughnut", "Doughnut"], ["/m/steak", "Steak"], ["/m/car", "Car"],
        *[[f"/m/x{i}", name] for i, name in enumerate(sorted({
            n for spec in load_yaml(ROOT / "configs/external/open_images.yaml")["classes"].values()
            for n in spec.get("boxable", []) + spec.get("image_level", [])} - {"Pizza", "Steak"}))],
        *[[f"/m/o{i}", name] for i, name in enumerate(
            set(load_yaml(ROOT / "configs/external/open_images.yaml")["other_food_as_unknown"]) - {"Doughnut"})],
    ])
    box_header = ["ImageID", "Source", "LabelName", "Confidence", "XMin", "XMax", "YMin", "YMax",
                  "IsOccluded", "IsTruncated", "IsGroupOf", "IsDepiction", "IsInside"]
    boxes = write_csv(oi / "boxes.csv", box_header, [
        ["a1", "xclick", "/m/pizza", "1", "0.1", "0.5", "0.2", "0.6", "1", "0", "0", "0", "0"],
        ["a1", "xclick", "/m/doughnut", "1", "0.6", "0.9", "0.1", "0.4", "0", "0", "0", "0", "0"],
        ["a1", "xclick", "/m/car", "1", "0", "1", "0", "1", "0", "0", "0", "0", "0"],
        ["a2", "xclick", "/m/pizza", "1", "0.1", "0.5", "0.2", "0.6", "0", "0", "0", "0", "0"],   # NC licence
        ["a3", "xclick", "/m/pizza", "1", "0.1", "0.5", "0.2", "0.6", "0", "0", "0", "1", "0"],   # drawing
        ["a4", "xclick", "/m/doughnut", "1", "0.1", "0.5", "0.2", "0.6", "0", "0", "0", "0", "0"],  # no target class
        ["a5", "xclick", "/m/pizza", "1", "0.1", "0.5", "0.2", "0.6", "0", "0", "0", "0", "0"],   # rotated
    ])
    meta_header = ["ImageID", "Subset", "OriginalURL", "OriginalLandingURL", "License", "AuthorProfileURL",
                   "Author", "Title", "OriginalSize", "OriginalMD5", "Thumbnail300KURL", "Rotation"]
    by = openimages.CC_BY_20
    meta = write_csv(oi / "meta.csv", meta_header, [
        ["a1", "train", "https://x/a1.jpg", "https://flickr/a1", by, "https://flickr/u1", "Ann", "t", "1", "m", "", ""],
        ["a2", "train", "https://x/a2.jpg", "", "https://creativecommons.org/licenses/by-nc/2.0/", "", "B", "t", "1", "m", "", ""],
        ["a3", "train", "https://x/a3.jpg", "", by, "", "C", "t", "1", "m", "", ""],
        ["a4", "train", "https://x/a4.jpg", "", by, "", "D", "t", "1", "m", "", ""],
        ["a5", "train", "https://x/a5.jpg", "", by, "", "E", "t", "1", "m", "", "90"],
        ["b1", "train", "https://x/b1.jpg", "https://flickr/b1", by, "", "F", "t", "1", "m", "", "0"],
    ])
    labels = write_csv(oi / "labels.csv", ["ImageID", "Source", "LabelName", "Confidence"], [
        ["b1", "verification", "/m/steak", "1"], ["a4", "verification", "/m/steak", "0"]])

    assert main(["select-openimages", "--classes-csv", str(classes), "--boxes-csv", str(boxes),
                 "--metadata-csv", str(meta), "--labels-csv", str(labels)]) == 0
    assert "1 images with boxes, 1 to annotate; skipped 1 (licence) and 1 (rotated)" in capsys.readouterr().out
    ids = (project / "data/external/openimages_train_ids.txt").read_text().split()
    assert ids == ["a1", "b1"]

    images_dir = tmp_path / "oi_images"
    make_image(images_dir / "a1.jpg", seed=1, size=(400, 300))
    make_image(images_dir / "b1.jpg", seed=2, size=(400, 300))
    assert main(["import-openimages", "--classes-csv", str(classes), "--images-dir", str(images_dir)]) == 0
    out = capsys.readouterr().out
    assert "boxes added: 2 (1 as unknown_food" in out and "1 photos need boxes drawn" in out
    coco, _ = load_coco(project / "data/annotations/instances.json")
    pizza = next(a for a in coco.annotations if a.category_id == 42)
    assert pizza.bbox == pytest.approx((40.0, 60.0, 160.0, 120.0)) and pizza.attributes == {"occluded": True}
    records, _ = load_manifest(project / "data/manifests/images.jsonl")
    assert {r.license for r in records} == {"CC-BY-2.0"}
    assert any(r.attribution == "Ann, https://flickr/a1, via Open Images V7, CC BY 2.0" for r in records)
    todo = (project / "data/annotations/to_annotate_openimages.tsv").read_text()
    assert todo.strip().endswith("\tsteak")


def test_merge_keeps_imports_and_replaces_reannotated_images():
    base = CocoDataset([CocoImage(1, "a.jpg", 10, 10), CocoImage(2, "b.jpg", 10, 10)],
                       [CocoAnnotation(1, 1, 4, (0, 0, 5, 5)), CocoAnnotation(2, 2, 4, (0, 0, 5, 5))], [])
    incoming = CocoDataset([CocoImage(1, "b.jpg", 10, 10), CocoImage(2, "c.jpg", 10, 10)],
                           [CocoAnnotation(1, 1, 13, (1, 1, 5, 5)), CocoAnnotation(2, 2, 13, (1, 1, 5, 5))], [])
    merged, added, replaced = merge_datasets(base, incoming)
    assert (added, replaced) == (1, 1)
    assert sorted(i.file_name for i in merged.images) == ["a.jpg", "b.jpg", "c.jpg"]
    by_file = {i.file_name: i.id for i in merged.images}
    assert [a.category_id for a in merged.annotations if a.image_id == by_file["b.jpg"]] == [13]
    assert len({a.id for a in merged.annotations}) == len(merged.annotations) == 3
