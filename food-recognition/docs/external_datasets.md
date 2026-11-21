# External datasets

Two public datasets are approved for training (see `licenses/assets.yaml`).
Both are imported from files you download yourself. The importers only read
local paths, and the raw downloads stay in the gitignored `data/external/`.

Before importing, copy the `myfoodrepo_v04` and `open_images_v7` entries
from `data/manifests/sources.example.yaml` into `data/manifests/sources.yaml`.

## MyFoodRepo / Food Recognition Benchmark v0.4 (CC BY 4.0)

About 24,000 real phone photos of meals, shared by app users who opted in,
with hand-drawn outlines that the importer turns into boxes.

1. Sign in at AIcrowd, open the Food Recognition Benchmark **Resources** tab and
   download `train-v0.4.tar.gz` and `val-v0.4.tar.gz`. Skip
   `test_images-v0.4.tar.gz`, which contains the same photos as `val`.
2. Propose the class mapping:
   ```bash
   food-rec propose-mapping ~/Downloads/train-v0.4.tar.gz ~/Downloads/val-v0.4.tar.gz
   ```
   This writes `configs/external/myfoodrepo_mapping_v0.4.yaml` with one line per
   MyFoodRepo category. Each line maps to one of our classes, to `unknown_food`
   (still food for the detector), or to `drop` (drinks, sauces and spreads,
   which are not boxed). The output also names any of our foods with no match.
3. Check every line, fix any that are wrong, set `reviewed: true` and commit
   the file. The importer refuses an unreviewed mapping.
4. Import:
   ```bash
   food-rec import-myfoodrepo ~/Downloads/train-v0.4.tar.gz ~/Downloads/val-v0.4.tar.gz
   ```
   Archives are extracted once into `data/external/`. Re-running the import is
   safe: photos that are already imported are skipped by content hash.

### Kaggle mirror (2022 release)

If the AIcrowd download fails, the Kaggle copy
`awsaf49/food-recognition-2022-dataset` holds the newer **2022 v2.0** release of
the same MyFoodRepo data. Download it as a `.zip` and pass `--release v2.0`:

```bash
food-rec propose-mapping --release v2.0 ~/Downloads/archive.zip
food-rec import-myfoodrepo --release v2.0 ~/Downloads/archive.zip
```

The importer finds every `annotations.json` inside, whatever the folder
names are, and skips test folders that have no labels. The credit recorded for
each photo names MyFoodRepo / AIcrowd, not the Kaggle uploader. This release
is its own entry in the licence register (`myfoodrepo_2022_v2`, approved
2026-11-21). Kaggle lists it as CC0, but we follow the original CC BY 4.0
terms, since a mirror cannot relicense the data.

## Open Images V7 (photos CC BY 2.0, boxes CC BY 4.0)

No login is needed. Download these CSVs from the
[Open Images download page](https://storage.googleapis.com/openimages/web/download_v7.html):

| File | What it holds |
|---|---|
| `oidv7-class-descriptions.csv` | class ids and names |
| `oidv6-train-annotations-bbox.csv` | boxes (about 2 GB) |
| `train-images-boxable-with-rotation.csv` | licence, author, URL and rotation for each photo |
| `oidv7-train-annotations-human-imagelabels.csv` | optional: photo-level labels for foods that have no boxes |

```bash
food-rec select-openimages --classes-csv oidv7-class-descriptions.csv \
  --boxes-csv oidv6-train-annotations-bbox.csv \
  --metadata-csv train-images-boxable-with-rotation.csv \
  --labels-csv oidv7-train-annotations-human-imagelabels.csv --max-per-class 1500
python scripts/download_openimages.py data/external/openimages_train_ids.txt data/external/openimages_images
food-rec import-openimages --classes-csv oidv7-class-descriptions.csv --images-dir data/external/openimages_images
```

What the importer does:

- Keeps only photos listed as CC BY 2.0. It records each photo's author and
  URL, and `food-rec attributions` lists them all.
- Skips drawings (`IsDepiction`) and photos that need rotating.
- Maps 24 of our foods from boxed classes. Boxes of other foods (doughnut,
  taco, "Egg" and similar) become `unknown_food`, so the detector still
  learns them. Our egg types come from the photo-level labels.
- Imports 19 more foods from photo-level labels without boxes. Those photos
  are listed in `data/annotations/to_annotate_openimages.tsv` for boxing in
  Label Studio, then merged back with `food-rec normalize --merge`.
- Open Images boxes are not exhaustive: a photo boxed for pizza may show a
  salad that nobody boxed. Validation does not catch this. Spot-check the
  examples in `reports/dataset_report.md` and box missing foods in Label
  Studio.

## After importing

```bash
food-rec validate && food-rec split && food-rec report
```

Our own phone photos (the `phone_eval` source pinned to `test`) stay the
final test set. Public photos are for training only.
