# Third-party licences

Every external model, weight file, dataset, tool and library the pipeline
uses or has considered. The machine-readable version is
[`assets.yaml`](assets.yaml); `food-rec check-licenses` enforces it.

**This is an engineering summary, not legal advice.** Items marked
*needs review* should be checked by Baris (and ideally a lawyer) before use.

## Summary

| Status | Meaning |
|---|---|
| ✅ approved | Licence allows commercial App Store distribution. |
| ⚠️ needs review | Possibly fine, but terms are mixed or indirect. Blocked by the licence gate until approved. |
| ⛔ blocked | Research-only, non-commercial, copyleft that would affect the app, or unknown. Do not use. |

## Python libraries

| Library | Licence | Used for | Status |
|---|---|---|---|
| NumPy | BSD-3-Clause | metrics, arrays | ✅ |
| Pillow | MIT-CMU (HPND) | image decoding | ✅ |
| PyYAML | MIT | configs | ✅ |
| pillow-heif (optional) | BSD-3-Clause; bundles libheif (LGPL-3.0) and codecs | reading iPhone HEIC photos during import | ✅ for training-time use only. Nothing from it ships in the app. |
| PyTorch | BSD-3-Clause | training | ✅ |
| torchvision | BSD-3-Clause | model code, transforms | ✅ (code only; see weights) |
| timm | Apache-2.0 | MobileNetV3 classifier code | ✅ (code only; see weights) |
| coremltools | BSD-3-Clause | Core ML export and compression | ✅ |
| Label Studio Community | Apache-2.0 | annotation tool, runs locally | ✅ |
| pytest, ruff, mypy | MIT | development only | ✅ |

None of these ship inside the iOS app. Only the exported `.mlpackage` files do.

## Model code

| Asset | Licence | Status | Notes |
|---|---|---|---|
| YOLOX (Megvii) | Apache-2.0 | ✅ | Detector architecture. Keep the Apache NOTICE if we copy code. |
| MobileNetV3 via timm | Apache-2.0 | ✅ | Classifier architecture. |
| Ultralytics YOLOv5/v8/11 | AGPL-3.0 or paid enterprise licence | ⛔ | AGPL would require publishing the app's source. Not used. |

## Pretrained weights

A model trained on a dataset can carry that dataset's restrictions. This is
legally unsettled, so weights inherit the most cautious reading of their
training data.

| Asset | Weight licence | Trained on | Status |
|---|---|---|---|
| YOLOX official checkpoints | Apache-2.0 | COCO 2017 (Flickr images, mixed licences including non-commercial) | ⚠️ |
| ImageNet-pretrained backbones (torchvision, timm) | BSD/Apache | ImageNet (terms: non-commercial research) | ⚠️ |
| DINOv2 | Apache-2.0 | LVD-142M (curated web images) | ⚠️ (also too large for phones as-is) |
| Our own Open Images pretraining | ours | Open Images V7 (CC BY 2.0 images, CC BY 4.0 boxes) | ✅ approved by Baris, 2026-11-21 |

## Datasets

| Dataset | Licence | Status | Notes |
|---|---|---|---|
| Photos Baris owns or has written commercial permission for | owned / permission | ✅ | Each image needs a manifest record. |
| Open Images V7 | Boxes CC BY 4.0; images listed by Google as CC BY 2.0 | ✅ approved by Baris, 2026-11-21 | Google does not verify each image's licence. We would keep each image's licence and author, and publish an attribution list. CC BY covers copyright, not people shown in photos; food-only crops reduce that concern. |
| Nutrition5k | CC BY 4.0 | ⚠️ | Commercial use allowed with attribution, but overhead cafeteria trays only; no boxes. |
| Food Recognition Benchmark / MyFoodRepo v0.4 | CC BY 4.0 (stated on each AIcrowd download, checked 2026-11-21) | ✅ approved by Baris, 2026-11-21 | Real phone photos shared by consenting app users, polygon masks converted to boxes. Credit: "MyFoodRepo / Food Recognition Benchmark v0.4 (Mohanty et al., 2022, Front. Nutr. 9:875143), AIcrowd, CC BY 4.0". `test_images-v0.4` duplicates `val` and is not imported. |
| Roboflow Universe food sets | Chosen by each uploader | ⛔ | Licence is self-declared; image origin usually unknown (often Food-101 or web scrapes). |
| MS COCO 2017 | Boxes CC BY 4.0; images mixed Flickr licences | ⚠️ | Only images under commercial-friendly licences could be considered. |
| Food-101 | Unclear; scraped from foodspotting.com | ⛔ | No clear commercial grant. |
| UEC FOOD-100 / 256 | Research use only | ⛔ | |
| ISIA Food-200 / 500 | Research use only | ⛔ | |
| FoodSeg103 | Images from Recipe1M (non-commercial) | ⛔ | |
| Opt-in user corrections | Consent under our own terms (`food-corrections-v1`) | ✅ after review | See docs/user_corrections.md. |
| USDA FoodData Central | Public domain (CC0 1.0) | ✅ | Nutrition lookup in the app after the user confirms. Not used for training. |

## Attribution

CC BY needs credit when the material is shared. The app ships only model
weights, not photos, but we credit the sources anyway: the app's About screen
should name "Open Images V7 (Google)" and "MyFoodRepo / Food Recognition
Benchmark (EPFL, AIcrowd)". `food-rec attributions` writes the full
per-photo list (author and URL for every Open Images photo) to
`reports/attributions.tsv`.

## Before adding anything new

1. Add an entry to `assets.yaml` with `status: needs_review`.
2. Write it up here: licence, what it was trained on, attribution needs.
3. Ask Baris. Only then change it to `approved`.
