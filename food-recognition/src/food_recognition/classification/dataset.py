"""Torch dataset of food crops."""

from __future__ import annotations

from typing import Any

import torch
from PIL import Image, ImageOps
from torch.utils.data import Dataset
from torchvision.transforms import v2 as T

from ..training.data import Crop, padded_box

MEAN, STD = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)


def load_rgb(path: Any) -> Image.Image:
    with Image.open(path) as img:
        return ImageOps.exif_transpose(img).convert("RGB")


class CropDataset(Dataset[tuple[torch.Tensor, int]]):
    def __init__(self, crops: list[Crop], size: int, padding: float, *, train: bool, randaugment: bool = False) -> None:
        self.crops, self.padding = crops, padding
        if train:
            steps: list[Any] = [T.RandomResizedCrop(size, scale=(0.5, 1.0), ratio=(0.75, 1.33), antialias=True),
                                T.RandomHorizontalFlip(), T.RandomVerticalFlip(0.1)]
            if randaugment:
                steps.append(T.RandAugment(num_ops=2, magnitude=9))
            # Strong brightness range on purpose: users photograph food in dim restaurants.
            steps += [T.ColorJitter(brightness=(0.35, 1.3), contrast=0.3, saturation=0.3, hue=0.03)]
        else:
            steps = [T.Resize((size, size), antialias=True)]
        self.transform = T.Compose([T.PILToTensor(), *steps, T.ToDtype(torch.float32, scale=True), T.Normalize(MEAN, STD)])

    def __len__(self) -> int:
        return len(self.crops)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, int]:
        crop = self.crops[index]
        image = load_rgb(crop.path)
        image = image.crop(padded_box(crop.box, self.padding, image.width, image.height))
        return self.transform(image), crop.label
