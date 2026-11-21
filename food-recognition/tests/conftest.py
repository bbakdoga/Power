from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np
import pytest
from PIL import Image

from food_recognition.config import project_root
from food_recognition.dataset.images import sha256_file
from food_recognition.dataset.manifest import ImageRecord, Source
from food_recognition.dataset.taxonomy import Taxonomy, load_taxonomy

ROOT = project_root()


@pytest.fixture(scope="session")
def taxonomy() -> Taxonomy:
    return load_taxonomy(ROOT / "configs" / "taxonomy.yaml")


def make_image(path: Path, seed: int, size: tuple[int, int] = (320, 240)) -> Path:
    """A random-noise image; different seeds give images that are not near duplicates."""
    rng = np.random.default_rng(seed)
    pixels = rng.integers(0, 255, size=(size[1], size[0], 3), dtype=np.uint8)
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(pixels).save(path, "PNG")
    return path


@pytest.fixture
def owned_source() -> dict[str, Source]:
    return {
        "owned": Source("owned", "owned", "owned", True, True),
        "evalset": Source("evalset", "owned", "owned", True, True, pinned_split="test"),
        "nc": Source("nc", "open_dataset", "CC-BY-NC-4.0", False, False),
    }


@pytest.fixture
def small_dataset(tmp_path: Path) -> Callable[..., dict[str, Any]]:
    """Build a tiny on-disk dataset: images, COCO dict and manifest records."""

    def build(n: int = 4, source_id: str = "owned") -> dict[str, Any]:
        raw = tmp_path / "raw"
        images, annotations, records = [], [], []
        for i in range(n):
            name = f"{source_id}/img_{i}.png"
            path = make_image(raw / name, seed=i)
            images.append({"id": i + 1, "file_name": name, "width": 320, "height": 240})
            annotations.append({"id": i + 1, "image_id": i + 1, "category_id": (i % 3) + 1,
                                "bbox": [10, 10, 100, 80], "iscrowd": 0})
            records.append(ImageRecord(file=name, sha256=sha256_file(path), source_id=source_id,
                                       source_type="owned", license="owned", commercial_use=True,
                                       redistribution=True, group_id=f"g{i}", review_status="approved",
                                       reviewer="test"))
        coco = {"images": images, "annotations": annotations, "categories": []}
        return {"raw": raw, "coco": coco, "records": records}

    return build


def write_json(path: Path, data: Any) -> Path:
    path.write_text(json.dumps(data), encoding="utf-8")
    return path
