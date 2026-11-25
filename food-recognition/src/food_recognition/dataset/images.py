"""Image hashing and metadata helpers."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

try:  # HEIC support is optional
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:  # pragma: no cover - depends on optional extra
    pass


@dataclass(frozen=True)
class ImageInfo:
    width: int
    height: int
    format: str
    exif_rotated: bool


def sha256_file(path: str | Path, chunk_size: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_image_info(path: str | Path) -> ImageInfo:
    """Open and fully decode the image so truncated files are caught.

    Width and height are reported after applying the EXIF orientation, which is
    how annotation tools and phones display the photo.
    """
    with Image.open(path) as img:
        fmt = img.format or "UNKNOWN"
        img.load()
        orientation = img.getexif().get(0x0112, 1)
        rotated = orientation not in (None, 1)
        width, height = img.size
        if orientation in (5, 6, 7, 8):  # 90 or 270 degree rotations swap the sides
            width, height = height, width
        return ImageInfo(width=width, height=height, format=fmt, exif_rotated=rotated)


def dhash(path: str | Path, hash_size: int = 8) -> int:
    """Difference hash: robust to resizing and recompression, used for near duplicates."""
    with Image.open(path) as img:
        gray = ImageOps.exif_transpose(img).convert("L").resize((hash_size + 1, hash_size), Image.Resampling.LANCZOS)
        pixels = np.asarray(gray, dtype=np.int16)
    bits = 0
    for value in (pixels[:, :-1] > pixels[:, 1:]).flatten():
        bits = (bits << 1) | int(value)
    return bits


def hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()
