# Architecture and taxonomy proposal

## Two-stage pipeline

```
photo ──► FoodDetector (class-agnostic) ──► boxes ──► crop + 10% padding ──► FoodClassifier ──► top-3 + reject
                                                                                                  │
                                         user confirms each food ◄─────────────────────────────────┘
                                                    │
                                                    ▼
                                    USDA FoodData Central lookup (in the app)
```

| Stage | Model | Code licence | Params | Size (fp16) | Input |
|---|---|---|---:|---:|---|
| Detector | YOLOX-Tiny, 1 class ("food") | Apache-2.0 | ~5 M | ~10 MB | 416×416 |
| Classifier | MobileNetV3-Large 1.0 (timm) | Apache-2.0 | ~5.5 M | ~11 MB | 224×224 |

Combined target: about 20 MB float16, well under the 100 MB budget. Both
architectures are plain convolutions that convert cleanly to Core ML and run
on the Neural Engine on every iPhone that supports iOS 17 (A12 and newer).

### Why a class-agnostic detector

- Finding "where is a food" is easier to learn than "where is salmon", so the
  detector needs far fewer boxes per class.
- Adding or splitting a food later only retrains the small classifier.
- The classifier sees a tight crop, which helps with mixed plates.

### Why not Ultralytics YOLO

Ultralytics YOLOv5/v8/11 are AGPL-3.0. Shipping a model trained with it in a
closed-source app needs a paid enterprise licence. YOLOX gives similar
accuracy at this size under Apache-2.0.

### Unknown food and rejection

- Annotators label unrecognised or out-of-taxonomy food as `unknown_food`.
  The detector learns these as food; the classifier uses them as negatives.
- At inference the classifier returns the top three. If top-1 confidence is
  below `reject_below` (0.40 to start, tuned on the validation set with
  `rejection_curve`), the app shows "Unknown food" and lets the user search.
  If the top two are within `reject_margin`, the app asks the user to choose.
- Recognition outputs only a food label. Calories and nutrients always come
  from USDA FoodData Central after the user confirms.

## Pretrained weights: decision needed before training

Starting from pretrained weights matters a lot when we have only a few
thousand of our own photos. Almost every public checkpoint was trained on
ImageNet or COCO, whose image terms are non-commercial or mixed. Options:

1. **Pretrain our own backbones on Open Images V7 (recommended).** Google
   lists the images as CC BY 2.0 and the boxes as CC BY 4.0, both of which
   allow commercial use with attribution. Costs one or two days of GPU time on
   Pegasus. Many of our 45 foods are Open Images classes, so it also supplies
   extra food boxes.
2. **Use ImageNet/COCO checkpoints.** Fastest and most accurate start and
   common practice, but the training-data terms are non-commercial; only with
   a lawyer's sign-off.
3. **Train from scratch on our own photos only.** No third-party data, but it
   needs many thousands of labelled photos for usable accuracy.

**Decision (2026-11-21): option 1, Open Images pretraining.** `open_images_v7`
and `openimages_pretrain_own` are approved in `licenses/assets.yaml`. The
configs keep `pretrained: null` until those weights exist; ImageNet and COCO
checkpoints stay blocked by the licence gate.

## From-scratch comparison

Baris also wants a model trained with no pretrained weights at all, to compare
against the production path. `configs/experiments/` has a matched pair for
each model:

| Config | Starting weights | Schedule |
|---|---|---|
| `detection_openimages.yaml` / `classification_openimages.yaml` | our Open Images pretraining | normal |
| `detection_scratch.yaml` / `classification_scratch.yaml` | random | 2× epochs, stronger augmentation |

Rules that keep the comparison fair:

- Both runs use the same frozen dataset version, the same seed and the same
  held-out test split (including the pinned phone-photo set).
- Both produce evaluation records (`evaluation/records.py`) with the same
  metrics and condition slices, before and after Core ML compression.
- Report GPU hours for each run as well, since from-scratch costs more.
- Expect from-scratch to be clearly worse with only a few thousand photos; the
  size of that gap is the interesting result.

The from-scratch run uses no third-party data, so it is also the cleanest
possible licence story.

## Taxonomy v0.1.0 (45 foods + unknown)

Chosen for a fitness app: things people log daily, that look different
enough in a photo, and that map to a clear USDA FoodData Central search.

| Group | Foods |
|---|---|
| Protein (12) | grilled chicken, fried chicken, steak, salmon, white fish fillet, shrimp, fried egg, boiled egg, scrambled eggs, tofu, bacon, sausage |
| Grains and starches (11) | rice, fried rice, pasta, bread/toast, bagel, potato, french fries, sweet potato, oatmeal, pancakes, wrap/burrito |
| Vegetables (9) | broccoli, green salad, carrot, tomato, cucumber, avocado, green beans, corn, bell pepper |
| Fruit (6) | apple, banana, orange, strawberries, blueberries, grapes |
| Dairy and snacks (3) | yogurt, cheese, nuts |
| Dishes (4) | pizza, burger, sandwich, sushi |

Deliberately left out for now: drinks, sauces and dressings (hard to box,
better logged by hand), soups and stews (contents not visible), protein bars
and packaged food (barcode scanning is better), and look-alikes such as white
vs brown rice. The full list with ids is in `configs/taxonomy.yaml`.

## Data plan

- **Owned photos** first: Baris's own meals, friends with written permission.
  Aim for 150+ boxes per class before the first serious training run.
- **Held-out test set** pinned to `test`: everyday phone photos covering mixed
  plates, low light, odd angles and partly hidden food. Never trained on.
- **Open Images** food classes, only if option 1 above is approved, with a
  per-image licence and attribution record.
- **User corrections**, opt-in only, reviewed by a person before use.
