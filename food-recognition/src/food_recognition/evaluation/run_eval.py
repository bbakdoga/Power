"""Score a finished training run on a held-out split of the dataset version it was trained on.

Training only ever reports validation numbers. This is where test-set numbers
come from: the same frozen dataset version (checked against the files on disk),
the run's own config and its best checkpoint. Results are written next to the
run as eval_<split>.json, with the checkpoint hash, so every number in a table
can be traced back to one file.
"""

from __future__ import annotations

import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _kind_and_version(state: dict[str, Any]) -> tuple[str, str]:
    if "labels" in state and "dataset_version" in state:
        return "classification", str(state["dataset_version"])
    if "class_names" in state and state.get("run_label"):
        return "detection", str(state["run_label"])
    raise ValueError("not a food detector or classifier checkpoint (pretraining runs are not evaluated on food data)")


def evaluate_run(run: Path, root: Path, *, split: str = "test", checkpoint: str = "best.pt") -> dict[str, Any]:
    import numpy as np
    import torch
    from torch.utils.data import DataLoader

    from ..config import load_yaml
    from ..detection.train import preflight
    from ..training import common
    from ..training.data import load_frozen

    if split == "train":
        raise ValueError("scoring on the training split is not a valid accuracy claim")
    path = run / checkpoint
    state = torch.load(path, map_location="cpu", weights_only=False)
    kind, version = _kind_and_version(state)
    config = state["config"]
    if not (root / "data/manifests/datasets" / f"{version}.json").exists():
        raise ValueError(f"{run}: dataset version {version!r} is not frozen here, so it can't be scored")
    preflight(config, version, root)

    dataset_cfg = load_yaml(root / "configs/dataset.yaml")
    frozen = load_frozen(root, version, root / dataset_cfg["paths"]["raw_dir"],
                         sources=(config.get("data") or {}).get("sources"))
    samples = frozen.splits.get(split) or []
    if not samples:
        raise ValueError(f"dataset {version} has no {split} images")
    dev = common.device()
    workers = int(os.environ.get("SLURM_CPUS_PER_TASK", min(8, os.cpu_count() or 1)))
    batch = int(config["train"]["batch_size"])

    if kind == "detection":
        from ..detection.dataset import DetectionDataset, collate
        from ..detection.postprocess import PostprocessConfig, postprocess
        from ..detection.train import _evaluate
        from ..detection.yolox import build
        from .detection_metrics import Detection, GroundTruth, evaluate_detections

        class_names = list(state["class_names"])
        model = build(config["model"]["architecture"], len(class_names))
        model.load_state_dict(state["model"])
        model.to(dev)
        class_of = {cid: 0 for s in samples for cid in s.category_ids}     # class-agnostic "food", as in training
        ds = DetectionDataset(samples, int(config["model"]["input_size"][0]), train=False, class_of=class_of)
        loader = DataLoader(ds, batch_size=batch, num_workers=workers, collate_fn=collate)
        post = config.get("postprocess") or {}
        eval_post = PostprocessConfig(confidence_threshold=0.01, max_detections=100, min_box_side=0,
                                      nms_iou_threshold=float(post.get("nms_iou_threshold", 0.5)))
        metrics = _evaluate(model, loader, dev, class_names, eval_post, np, torch, Detection, GroundTruth,
                            evaluate_detections, postprocess)
        counted = {"images": len(ds)}
    else:
        import timm

        from ..classification.dataset import CropDataset
        from ..classification.train import metrics_from, predict
        from ..dataset.taxonomy import load_taxonomy
        from ..training.data import crops_from

        labels = list(state["labels"])
        taxonomy = load_taxonomy(root / dataset_cfg["paths"]["taxonomy"])
        if taxonomy.classifier_labels() != labels:
            raise ValueError(f"{run}: the taxonomy changed since this model was trained")
        model_cfg = config["model"]
        classifier = timm.create_model(model_cfg["architecture"], pretrained=False, num_classes=len(labels))
        classifier.load_state_dict(state["model"])
        classifier.to(dev)
        crops = crops_from(samples, taxonomy, include_unknown=True)
        crop_ds = CropDataset(crops, int(model_cfg.get("input_size", 224)), float(model_cfg.get("crop_padding", 0.10)),
                              train=False)
        scores, targets = predict(classifier, DataLoader(crop_ds, batch_size=batch, num_workers=workers), dev)
        metrics = metrics_from(scores, targets, labels, config)
        counted = {"images": len(samples), "crops": len(crops)}

    result = {
        "kind": kind, "experiment": (config.get("experiment") or {}).get("name"), "run": str(run),
        "dataset_version": version, "split": split, "checkpoint": checkpoint,
        "checkpoint_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "trained_epochs": state.get("epoch"),
        **counted, "metrics": metrics, "environment": common.environment(),
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    common.write_json(run / f"eval_{split}.json", result)
    return result


def headline(result: dict[str, Any]) -> str:
    """One line per run for a comparison table."""
    m = result["metrics"]
    name = result.get("experiment") or Path(result["run"]).parent.name
    if result["kind"] == "detection":
        numbers = f"mAP50-95 {m['map50_95']:.3f}  mAP50 {m['map50']:.3f}"
    else:
        numbers = f"top-1 {m['top1_accuracy']:.3f}  top-3 {m['top3_accuracy']:.3f}  macro-F1 {m['macro_f1']:.3f}"
        if m.get("open_set"):
            numbers += f"  unknown AUROC {m['open_set']['auroc']:.3f}  FPR@95 {m['open_set']['fpr_at_95_tpr']:.3f}"
    return f"{name:28} {result['split']:5} {numbers}"
