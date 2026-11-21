#!/usr/bin/env python3
"""Download Open Images files by id from Google's public bucket (no login).

    python scripts/download_openimages.py data/external/openimages_ids.txt data/external/openimages_images --split train

Skips files that are already present, so it can be re-run after an interruption.
"""

from __future__ import annotations

import argparse
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BUCKET = "https://open-images-dataset.s3.amazonaws.com"


def fetch(image_id: str, split: str, out_dir: Path) -> str:
    dest = out_dir / f"{image_id}.jpg"
    if dest.exists() and dest.stat().st_size > 0:
        return "exists"
    tmp = dest.with_suffix(".part")
    try:
        with urllib.request.urlopen(f"{BUCKET}/{split}/{image_id}.jpg", timeout=60) as response:
            tmp.write_bytes(response.read())
        tmp.rename(dest)
        return "ok"
    except (urllib.error.URLError, TimeoutError) as exc:
        tmp.unlink(missing_ok=True)
        return f"failed: {exc}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ids_file")
    parser.add_argument("out_dir")
    parser.add_argument("--split", default="train", choices=["train", "validation", "test"])
    parser.add_argument("--workers", type=int, default=16)
    args = parser.parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ids = [line.strip() for line in Path(args.ids_file).read_text().splitlines() if line.strip()]
    failed = 0
    with ThreadPoolExecutor(args.workers) as pool:
        for n, (image_id, result) in enumerate(zip(ids, pool.map(lambda i: fetch(i, args.split, out_dir), ids), strict=True), 1):
            if result.startswith("failed"):
                failed += 1
                print(f"{image_id}: {result}", file=sys.stderr)
            if n % 500 == 0:
                print(f"{n}/{len(ids)}")
    print(f"done: {len(ids) - failed} of {len(ids)} images in {out_dir}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
