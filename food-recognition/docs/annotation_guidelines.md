# Annotation guidelines

We use **Label Studio Community Edition** (Apache-2.0), running locally on the
Mac so photos never leave it.

## Setup

```bash
pip install -e ".[annotate]"
food-rec labelstudio-config            # writes configs/annotation/label_studio.xml
label-studio start --data-dir label-studio-data
```

1. Create a project and paste the contents of `configs/annotation/label_studio.xml`
   under **Settings › Labeling Interface › Code**.
2. Add `data/raw/` as **Local files** storage (Settings › Cloud Storage ›
   Local Files; set `LABEL_STUDIO_LOCAL_FILES_SERVING_ENABLED=true` and
   `LABEL_STUDIO_LOCAL_FILES_DOCUMENT_ROOT` to the absolute `data/` path).
3. When done, **Export › COCO**, then:
   ```bash
   food-rec normalize --input ~/Downloads/result.json --strip-prefix "/data/local-files/?d=raw/"
   food-rec validate
   ```

## Drawing boxes

- Draw **one box per separate food item or portion**. Two eggs side by side
  on one plate are two boxes; a pile of fries is one box.
- The box should touch the visible edges of the food. Leave out the plate,
  cutlery and shadow.
- Include every food you can see, even small ones at the edge of the photo.
  A food you skip teaches the model that it is background.
- Boxes smaller than about 16 px on the short side are not worth drawing;
  leave tiny crumbs and garnish out.

## Hard cases

| Case | Rule |
|---|---|
| **Overlapping foods** (salmon on rice) | Box each food separately around its visible part. Boxes may overlap. |
| **Partly hidden food** | Box only the visible part. If more than about a quarter is hidden, tick `occluded`. |
| **Cut off by the photo edge** | Box the visible part and tick `truncated`. |
| **Sauces, dressings, gravy** | Do not box on their own. If sauce covers a food, label the food under it. |
| **Garnish** (parsley, lemon wedge) | Skip it. |
| **Mixed dishes** where parts cannot be separated (stir-fry, casserole) | One box around the dish. If the dish is in the taxonomy (fried rice, sandwich, burger, pizza, sushi, wrap) use that label; otherwise `unknown_food` and tick `mixed_dish`. |
| **Salad with toppings** | One `green_salad` box. Box toppings separately only if they are clearly separate (a whole boiled egg on top). |
| **Several pieces of the same food** (grapes, nuts, sushi rolls) | One box around the group when they touch; separate boxes when they are clearly apart. |
| **Not sure what it is** | Label `unknown_food` and tick `uncertain`. Never guess a specific food. |
| **Food not in the list** | `unknown_food`. Note frequent ones so we can add them to the taxonomy. |
| **Photo has no food** | No boxes; tick `no_food`. |
| **Blurry, a screenshot, or shows a person's face or private details** | Tick `reject_image`; it is removed before training. |

## Rejection workflow

1. `unknown_food` and `uncertain` boxes are kept: they teach the detector
   that something is food and the classifier when to say "not sure".
2. A second person reviews every `uncertain` box. They either pick a label
   (and untick `uncertain`) or leave it as `unknown_food`.
3. Images ticked `reject_image` are dropped from the manifest
   (`review_status: rejected`) and the file is deleted from `data/raw/`.

## Quality checks

- Review 10% of each annotator's images.
- `food-rec validate` must pass with zero errors before `food-rec split`.
- Check `reports/dataset_report.md` example images after each batch.
