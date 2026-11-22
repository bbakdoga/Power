"""Detector dataset: letterboxed images with boxes, plus mosaic, scale, flip and lighting augmentation."""

from __future__ import annotations

import random
from typing import Any

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

from ..classification.dataset import load_rgb
from ..training.data import Sample

PAD_VALUE = 114


def letterbox(image: Image.Image, size: int) -> tuple[Image.Image, float, tuple[int, int]]:
    """Resize keeping aspect ratio and pad to size x size. Returns the image, scale and (pad_x, pad_y)."""
    scale = min(size / image.width, size / image.height)
    new = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.Resampling.BILINEAR)
    canvas = Image.new("RGB", (size, size), (PAD_VALUE,) * 3)
    pad = ((size - new.width) // 2, (size - new.height) // 2)
    canvas.paste(new, pad)
    return canvas, scale, pad


def _xywh_to_xyxy(boxes: np.ndarray) -> np.ndarray:
    out = boxes.copy()
    out[:, 2:] = boxes[:, :2] + boxes[:, 2:]
    return out


class DetectionDataset(Dataset[tuple[torch.Tensor, torch.Tensor]]):
    """Targets are [N, 5] = (class, cx, cy, w, h) in input pixels.

    `class_of` maps a source category id to the detector class (always 0 for the
    class-agnostic food detector; Open Images pretraining uses many classes).
    """

    def __init__(self, samples: list[Sample], size: int, *, train: bool, augment: dict[str, Any] | None = None,
                 class_of: dict[int, int] | None = None, min_box_side: float = 2.0) -> None:
        self.samples, self.size, self.train = samples, size, train
        self.augment = augment or {}
        self.class_of = class_of
        self.min_box_side = min_box_side
        self.mosaic_enabled = train

    def __len__(self) -> int:
        return len(self.samples)

    def _load(self, index: int) -> tuple[Image.Image, np.ndarray, np.ndarray]:
        sample = self.samples[index]
        image = load_rgb(sample.path)
        boxes = np.array(sample.boxes, dtype=np.float32).reshape(-1, 4)
        classes = np.array([0 if self.class_of is None else self.class_of.get(c, -1) for c in sample.category_ids],
                           dtype=np.int64)
        keep = classes >= 0
        boxes, classes = boxes[keep], classes[keep]
        # Annotation sizes refer to the upright image; rescale if the stored file differs.
        if sample.width and sample.height and (image.width, image.height) != (sample.width, sample.height):
            boxes = boxes * np.array([image.width / sample.width, image.height / sample.height] * 2, dtype=np.float32)
        return image, _xywh_to_xyxy(boxes), classes

    def _single(self, index: int, size: int) -> tuple[Image.Image, np.ndarray, np.ndarray]:
        image, boxes, classes = self._load(index)
        image, scale, (px, py) = letterbox(image, size)
        boxes = boxes * scale + np.array([px, py, px, py], dtype=np.float32)
        return image, boxes, classes

    def _mosaic(self, index: int) -> tuple[Image.Image, np.ndarray, np.ndarray]:
        s = self.size
        canvas = Image.new("RGB", (2 * s, 2 * s), (PAD_VALUE,) * 3)
        cx, cy = int(random.uniform(0.5 * s, 1.5 * s)), int(random.uniform(0.5 * s, 1.5 * s))
        indices = [index] + [random.randrange(len(self.samples)) for _ in range(3)]
        all_boxes, all_classes = [], []
        for i, idx in enumerate(indices):
            image, boxes, classes = self._load(idx)
            scale = s / max(image.width, image.height)
            new_size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
            image = image.resize(new_size, Image.Resampling.BILINEAR)
            w, h = image.size
            x0, y0 = [(cx - w, cy - h), (cx, cy - h), (cx - w, cy), (cx, cy)][i]
            canvas.paste(image, (x0, y0))
            all_boxes.append(boxes * scale + np.array([x0, y0, x0, y0], dtype=np.float32))
            all_classes.append(classes)
        boxes = np.concatenate(all_boxes) if all_boxes else np.zeros((0, 4), np.float32)
        classes = np.concatenate(all_classes) if all_classes else np.zeros((0,), np.int64)
        # Random crop of size s around the centre point.
        ox, oy = int(random.uniform(max(0, cx - s), min(s, cx))), int(random.uniform(max(0, cy - s), min(s, cy)))
        image = canvas.crop((ox, oy, ox + s, oy + s))
        boxes = boxes - np.array([ox, oy, ox, oy], dtype=np.float32)
        return image, boxes, classes

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        aug = self.augment
        if self.train and self.mosaic_enabled and random.random() < float(aug.get("mosaic", 0.0)):
            image, boxes, classes = self._mosaic(index)
        else:
            image, boxes, classes = self._single(index, self.size)
        if self.train:
            image, boxes = self._scale_jitter(image, boxes, aug.get("scale", [0.5, 1.5]))
            if random.random() < float(aug.get("flip_lr", 0.5)):
                image = image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                boxes = boxes.copy()
                boxes[:, [0, 2]] = self.size - boxes[:, [2, 0]]
        array = np.asarray(image, dtype=np.float32)
        if self.train and aug.get("hsv", True):
            array = self._lighting(array, float(aug.get("low_light", 0.0)))
        boxes = boxes.copy()
        boxes[:, [0, 2]] = boxes[:, [0, 2]].clip(0, self.size)
        boxes[:, [1, 3]] = boxes[:, [1, 3]].clip(0, self.size)
        wh = boxes[:, 2:] - boxes[:, :2]
        keep = (wh >= self.min_box_side).all(1)
        boxes, classes, wh = boxes[keep], classes[keep], wh[keep]
        target = np.concatenate([classes[:, None].astype(np.float32), boxes[:, :2] + wh / 2, wh], 1)
        tensor = torch.from_numpy(np.ascontiguousarray(array.transpose(2, 0, 1)))  # 0..255 float, RGB
        return tensor, torch.from_numpy(target.reshape(-1, 5))

    def _scale_jitter(self, image: Image.Image, boxes: np.ndarray, scale_range: list[float]) -> tuple[Image.Image, np.ndarray]:
        scale = random.uniform(*scale_range)
        if abs(scale - 1) < 1e-3:
            return image, boxes
        s = self.size
        new = image.resize((max(1, round(s * scale)),) * 2, Image.Resampling.BILINEAR)
        canvas = Image.new("RGB", (s, s), (PAD_VALUE,) * 3)
        ox = int(random.uniform(min(0, s - new.width), max(0, s - new.width)))
        oy = int(random.uniform(min(0, s - new.height), max(0, s - new.height)))
        canvas.paste(new, (ox, oy))
        return canvas, boxes * scale + np.array([ox, oy, ox, oy], dtype=np.float32)

    @staticmethod
    def _lighting(array: np.ndarray, low_light: float) -> np.ndarray:
        gain = np.random.uniform(0.7, 1.3, 3).astype(np.float32)               # colour cast
        array = array * gain[None, None, :]
        if random.random() < low_light:
            array = array * random.uniform(0.25, 0.6) + np.random.normal(0, 4, array.shape).astype(np.float32)
        else:
            array = array * random.uniform(0.75, 1.25)
        return array.clip(0, 255)


def collate(batch: list[tuple[torch.Tensor, torch.Tensor]]) -> tuple[torch.Tensor, list[torch.Tensor]]:
    return torch.stack([b[0] for b in batch]), [b[1] for b in batch]
