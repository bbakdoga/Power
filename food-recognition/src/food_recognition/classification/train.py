"""Crop classifier training (MobileNetV3 via timm).

Each training example is one food box cropped from a photo. unknown_food crops
are negatives: their target is the uniform distribution over the 45 classes,
which teaches the model to be unsure on food it does not know, so the
reject threshold in configs/classification.yaml works at inference time.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from ..detection.train import preflight


def train(config: dict[str, Any], dataset_version: str, root: Path) -> Path:
    preflight(config, dataset_version, root)
    import numpy as np
    import torch
    import torch.nn.functional as F
    from torch.utils.data import DataLoader, WeightedRandomSampler

    from ..config import load_yaml
    from ..dataset.taxonomy import load_taxonomy
    from ..training import common
    from ..training.data import class_balanced_weights, crops_from, load_frozen
    from .dataset import CropDataset

    seed = int(config.get("seed", 1337))
    common.seed_torch(seed)
    dataset_cfg = load_yaml(root / "configs/dataset.yaml")
    taxonomy = load_taxonomy(root / dataset_cfg["paths"]["taxonomy"])
    labels = taxonomy.classifier_labels()
    model_cfg, train_cfg = config["model"], config["train"]
    data_cfg = config.get("data") or {}

    frozen = load_frozen(root, dataset_version, root / dataset_cfg["paths"]["raw_dir"], sources=data_cfg.get("sources"))
    use_unknown = bool(train_cfg.get("use_unknown_as_negative", True))
    train_crops = crops_from(frozen.splits["train"], taxonomy, include_unknown=use_unknown)
    val_crops = crops_from(frozen.splits["val"], taxonomy, include_unknown=True)
    if not train_crops or not val_crops:
        raise RuntimeError(f"no crops to train on: {frozen.counts()}")

    size = int(model_cfg.get("input_size", 224))
    padding = float(model_cfg.get("crop_padding", 0.10))
    augment = train_cfg.get("augment") or {}
    train_ds = CropDataset(train_crops, size, padding, train=True, randaugment=bool(augment.get("randaugment")))
    val_ds = CropDataset(val_crops, size, padding, train=False)

    workers = int(os.environ.get("SLURM_CPUS_PER_TASK", min(8, os.cpu_count() or 1)))
    generator = torch.Generator().manual_seed(seed)
    if train_cfg.get("class_balanced_sampling", True):
        weights = class_balanced_weights([c.label for c in train_crops], len(labels))
        sampler = WeightedRandomSampler(weights, num_samples=len(train_crops), replacement=True, generator=generator)
        train_dl = DataLoader(train_ds, batch_size=train_cfg["batch_size"], sampler=sampler, num_workers=workers,
                              worker_init_fn=common.worker_seed, drop_last=True, pin_memory=torch.cuda.is_available(),
                              persistent_workers=workers > 0)
    else:
        train_dl = DataLoader(train_ds, batch_size=train_cfg["batch_size"], shuffle=True, generator=generator,
                              num_workers=workers, worker_init_fn=common.worker_seed, drop_last=True,
                              pin_memory=torch.cuda.is_available(), persistent_workers=workers > 0)
    val_dl = DataLoader(val_ds, batch_size=train_cfg["batch_size"], num_workers=workers, pin_memory=torch.cuda.is_available())

    import timm

    dev = common.device()
    model = timm.create_model(model_cfg["architecture"], pretrained=False, num_classes=len(labels), drop_rate=0.2)
    init = common.init_weights_path(config, "classification", root)
    if init is not None:
        state = torch.load(init, map_location="cpu", weights_only=True)
        loaded, skipped = common.load_matching(model, state["model"])
        print(f"initialised from {init}: {loaded} tensors loaded, {skipped} new (head)")
    model.to(dev)

    epochs = int(train_cfg["epochs"])
    steps_per_epoch = len(train_dl)
    total = epochs * steps_per_epoch
    warmup = int(train_cfg.get("warmup_epochs", 3)) * steps_per_epoch
    base_lr = float(train_cfg["lr"]) * train_cfg["batch_size"] / 128
    optimizer = torch.optim.AdamW(model.parameters(), lr=base_lr, weight_decay=float(train_cfg.get("weight_decay", 0.05)))
    amp = common.amp_dtype(dev) if train_cfg.get("mixed_precision", True) else None
    scaler = torch.amp.GradScaler("cuda", enabled=amp == torch.float16)
    smoothing = float(train_cfg.get("label_smoothing", 0.1))
    unknown_weight = float(train_cfg.get("unknown_loss_weight", 0.5))
    mix_alpha = {"mixup": float(augment.get("mixup", 0.0)), "cutmix": float(augment.get("cutmix", 0.0))}
    rng = np.random.default_rng(seed)

    out = common.run_dir(root, config, "classification", dataset_version)
    print(f"run folder {out}\ncrops: train {len(train_crops)}, val {len(val_crops)}; device {dev}, amp {amp}")
    timer = common.Timer()
    history: list[dict[str, Any]] = []
    best_top1, best_epoch, step = -1.0, -1, 0
    num_classes = len(labels)

    for epoch in range(epochs):
        model.train()
        running = 0.0
        for images, targets in train_dl:
            images, targets = images.to(dev, non_blocking=True), targets.to(dev, non_blocking=True)
            soft = _soft_targets(targets, num_classes, smoothing)
            sample_weight = torch.where(targets < 0, unknown_weight, 1.0)
            images, soft, sample_weight = _mix(images, soft, sample_weight, mix_alpha, rng)
            for group in optimizer.param_groups:
                group["lr"] = common.cosine_lr(step, total, base_lr, warmup)
            with torch.autocast(dev.type, dtype=amp or torch.float32, enabled=amp is not None):
                logits = model(images)
            loss = (torch.sum(-soft * F.log_softmax(logits.float(), dim=1), dim=1) * sample_weight).mean()
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            scaler.step(optimizer)
            scaler.update()
            running += float(loss.detach())
            step += 1

        metrics = _evaluate(model, val_dl, dev, labels, config)
        row = {"epoch": epoch + 1, "train_loss": running / max(steps_per_epoch, 1), "val_top1": metrics["top1_accuracy"],
               "val_top3": metrics["top3_accuracy"], "val_macro_f1": metrics["macro_f1"],
               "unknown_rejected": metrics.get("unknown_rejected_rate"), "hours": timer.hours()}
        history.append(row)
        print(" ".join(f"{k}={v:.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in row.items()), flush=True)
        extra = {"labels": labels, "config": config, "dataset_version": dataset_version, "epoch": epoch + 1}
        common.save_checkpoint(out / "last.pt", model, extra)
        if metrics["top1_accuracy"] > best_top1:
            best_top1, best_epoch = metrics["top1_accuracy"], epoch + 1
            common.save_checkpoint(out / "best.pt", model, extra)
            common.write_json(out / "val_metrics_best.json", metrics)
        common.write_json(out / "history.json", history)

    summary = {"kind": "classification", "experiment": config.get("experiment"), "dataset_version": dataset_version,
               "best_epoch": best_epoch, "best_val_top1": best_top1, "gpu_hours": timer.hours(),
               "crops": {"train": len(train_crops), "val": len(val_crops)}, "init": str(init) if init else "scratch",
               "environment": common.environment(),
               "note": "Validation split only. Test-set numbers come from `food-rec evaluate`, never from training."}
    common.write_json(out / "summary.json", summary)
    print(f"done: best val top-1 {best_top1:.4f} at epoch {best_epoch}; {out}")
    return out


def _soft_targets(targets: Any, num_classes: int, smoothing: float) -> Any:
    import torch

    soft = torch.full((targets.shape[0], num_classes), smoothing / num_classes, device=targets.device)
    known = targets >= 0
    soft[known, targets[known]] += 1.0 - smoothing
    soft[~known] = 1.0 / num_classes          # unknown food: no class should win
    return soft


def _mix(images: Any, soft: Any, weight: Any, alpha: dict[str, float], rng: Any) -> tuple[Any, Any, Any]:
    """MixUp or CutMix on the whole batch (soft targets make unknown crops mix naturally)."""
    import torch

    choices = [k for k, v in alpha.items() if v > 0]
    if not choices or rng.random() < 0.5:
        return images, soft, weight
    kind = choices[int(rng.integers(len(choices)))]
    lam = float(rng.beta(alpha[kind], alpha[kind]))
    perm = torch.randperm(images.shape[0], device=images.device)
    if kind == "mixup":
        images = lam * images + (1 - lam) * images[perm]
    else:
        h, w = images.shape[2:]
        cut_h, cut_w = int(h * (1 - lam) ** 0.5), int(w * (1 - lam) ** 0.5)
        cy, cx = int(rng.integers(h)), int(rng.integers(w))
        y0, y1 = max(cy - cut_h // 2, 0), min(cy + cut_h // 2, h)
        x0, x1 = max(cx - cut_w // 2, 0), min(cx + cut_w // 2, w)
        images = images.clone()
        images[:, :, y0:y1, x0:x1] = images[perm, :, y0:y1, x0:x1]
        lam = 1 - (y1 - y0) * (x1 - x0) / (h * w)
    return images, lam * soft + (1 - lam) * soft[perm], lam * weight + (1 - lam) * weight[perm]


def predict(model: Any, loader: Any, dev: Any) -> tuple[Any, Any]:
    """Softmax scores [N, C] and targets [N] (-1 = unknown_food) for every crop in the loader."""
    import numpy as np
    import torch

    model.eval()
    scores, targets = [], []
    with torch.no_grad():
        for images, target in loader:
            logits = model(images.to(dev, non_blocking=True)).float()
            scores.append(torch.softmax(logits, dim=1).cpu().numpy())
            targets.append(target.numpy())
    return np.concatenate(scores), np.concatenate(targets)


def metrics_from(all_scores: Any, all_targets: Any, labels: list[str], config: dict[str, Any]) -> dict[str, Any]:
    """Closed-set metrics on known foods, plus how well unknown food is told apart (open-set)."""
    from ..evaluation.classification_metrics import classification_report, open_set_metrics, rejection_curve

    known = all_targets >= 0
    metrics: dict[str, Any] = classification_report(all_targets[known], all_scores[known], labels)
    metrics["rejection_curve"] = rejection_curve(all_targets[known], all_scores[known], [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
    reject_below = float((config.get("inference") or {}).get("reject_below", 0.4))
    if (~known).any():
        metrics["unknown_rejected_rate"] = float((all_scores[~known].max(axis=1) < reject_below).mean())
        metrics["unknown_crops"] = int((~known).sum())
        metrics["open_set"] = open_set_metrics(all_scores[known].max(axis=1), all_scores[~known].max(axis=1))
    metrics["known_accepted_rate"] = float((all_scores[known].max(axis=1) >= reject_below).mean())
    return metrics


def _evaluate(model: Any, loader: Any, dev: Any, labels: list[str], config: dict[str, Any]) -> dict[str, Any]:
    scores, targets = predict(model, loader, dev)
    return metrics_from(scores, targets, labels, config)
