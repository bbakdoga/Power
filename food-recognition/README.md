# Food recognition for Power

Training pipeline for on-device food recognition in the Power iOS app. A
small detector finds every food in a photo, a classifier names each one and
returns its top three guesses, and both run offline on the iPhone with Core
ML. Recognition never produces calories: the app looks up USDA FoodData
Central after the user confirms each food.

**Status: phase 1 of 6.** Dataset tooling, validation, licence gate and
cluster scaffolding are ready. No model has been trained yet.

| Phase | Content | State |
|---|---|---|
| 1 | Taxonomy, architecture, dataset validation, licence manifest | ✅ |
| 2 | Import MyFoodRepo + Open Images (`docs/external_datasets.md`), collect and annotate owned photos | next |
| 3 | Pretrained-weights decision: Open Images pretraining | ✅ decided |
| 4 | Detector and classifier training on Pegasus | |
| 5 | Core ML export, fp16/int8, parity check, Swift example | |
| 6 | On-device benchmarks and held-out phone-photo evaluation | |

## Setup

```bash
cd food-recognition
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"          # validation tools and tests
pip install -e ".[heic]"         # optional: import HEIC photos straight from an iPhone
pip install -e ".[annotate]"     # optional: Label Studio
pip install -e ".[train,export]" # later: training and Core ML export
pytest
```

## Workflow

```bash
# 1. Register the source in data/manifests/sources.yaml (copy sources.example.yaml)
food-rec import --folder ~/Pictures/meals-2026-11 --source-id baris_kitchen_2026_11 --group-id 2026-11-20-dinner

# 1b. Public datasets: see docs/external_datasets.md (MyFoodRepo, Open Images)

# 2. Annotate (docs/annotation_guidelines.md), export COCO, map labels onto the taxonomy
food-rec labelstudio-config
food-rec normalize --merge --input ~/Downloads/result.json --strip-prefix "/data/local-files/?d=raw/"

# 3. Validate, split, report, freeze
food-rec validate            # annotations, files, rights, consent, duplicates, class balance
food-rec split               # leakage-safe split by source group
food-rec report              # reports/dataset_report.md with counts and example boxes
food-rec freeze --version v0.1.0

# 4. Licence gate and training (training is phase 4)
food-rec check-licenses
food-rec train-detector --dataset-version v0.1.0
food-rec train-classifier --dataset-version v0.1.0
```

Training on the Pegasus cluster: see [`cluster/README.md`](cluster/README.md).

## Layout

```
configs/          taxonomy, dataset rules, model, export configs (YAML)
data/raw/         photos (never committed)
data/annotations/ COCO JSON (never committed)
data/manifests/   per-image rights and consent records, sources, frozen dataset versions
data/splits/      train/val/test assignment
src/food_recognition/
  dataset/        taxonomy, COCO, manifest, validation, splits, report, import, corrections
  detection/      postprocessing (NMS) and training entry point
  classification/ top-3 + rejection and training entry point
  evaluation/     classification and detection metrics, evaluation records
  export/         Core ML metadata and parity checks
cluster/          SLURM / LSF job scripts with placeholders, no credentials
docs/             architecture, annotation guidelines, external datasets, user-correction format
licenses/         THIRD_PARTY.md and machine-readable assets.yaml
tests/
```

## Rules this project enforces

- Every image has a rights record; images without commercial rights fail validation.
- Every external asset must be `approved` in `licenses/assets.yaml` before training uses it.
- Splits are by group, and exact or near-duplicate photos never cross splits.
- User corrections need consent and a human review before they enter training.
- Accuracy is only reported as an evaluation record naming the model, dataset version, split and method.
- Photos, annotations, credentials and model files are gitignored.
