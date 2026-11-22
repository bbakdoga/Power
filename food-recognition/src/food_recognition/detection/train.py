"""Detector training (YOLOX-Tiny, class-agnostic "food").

`preflight` gates every training run: approved licences, a frozen dataset
version that still matches the files on disk, and seeds. The same loop also
pretrains the detector on Open Images (many classes) via `fit`.
"""

from __future__ import annotations

import copy
import math
import os
from pathlib import Path
from typing import Any

from ..config import resolve, seed_everything
from ..dataset.versioning import verify_frozen
from ..licensing import load_assets, require_approved


def preflight(config: dict[str, Any], dataset_version: str, root: Path) -> None:
    require_approved(config, load_assets(resolve("licenses/assets.yaml", root)))
    frozen = resolve(f"data/manifests/datasets/{dataset_version}.json", root)
    if not frozen.exists():
        raise FileNotFoundError(f"dataset version {dataset_version} is not frozen; run `food-rec freeze`")
    problems = verify_frozen(frozen, root)
    if problems:
        raise RuntimeError("dataset changed since it was frozen:\n  " + "\n  ".join(problems))
    seed_everything(int(config.get("seed", 1337)))


def train(config: dict[str, Any], dataset_version: str, root: Path) -> Path:
    preflight(config, dataset_version, root)
    from ..config import load_yaml
    from ..training.data import load_frozen

    dataset_cfg = load_yaml(root / "configs/dataset.yaml")
    data_cfg = config.get("data") or {}
    frozen = load_frozen(root, dataset_version, root / dataset_cfg["paths"]["raw_dir"], sources=data_cfg.get("sources"))
    class_agnostic = {cid: 0 for s in frozen.splits["train"] + frozen.splits["val"] for cid in s.category_ids}
    return fit(config, frozen.splits["train"], frozen.splits["val"], class_of=class_agnostic, class_names=["food"],
               root=root, run_label=dataset_version, kind="detection")


class ModelEMA:
    """Exponential moving average of weights; YOLOX evaluates and exports the EMA model."""

    def __init__(self, model: Any, decay: float = 0.9998, tau: int = 2000) -> None:
        self.ema = copy.deepcopy(model).eval()
        for p in self.ema.parameters():
            p.requires_grad_(False)
        self.decay, self.tau, self.updates = decay, tau, 0

    def update(self, model: Any) -> None:
        import torch

        self.updates += 1
        d = self.decay * (1 - math.exp(-self.updates / self.tau))
        with torch.no_grad():
            state = model.state_dict()
            for k, v in self.ema.state_dict().items():
                if v.dtype.is_floating_point:
                    v.mul_(d).add_(state[k].detach(), alpha=1 - d)


def fit(config: dict[str, Any], train_samples: list[Any], val_samples: list[Any], *, class_of: dict[int, int],
        class_names: list[str], root: Path, run_label: str, kind: str, init_backbone_only: bool = False,
        resume: Path | None = None) -> Path:
    """Train a detector. `resume` continues a run folder from its resume.pt (for jobs hitting a time limit)."""
    import numpy as np
    import torch
    from torch.utils.data import DataLoader

    from ..evaluation.detection_metrics import Detection, GroundTruth, evaluate_detections
    from ..training import common
    from .dataset import DetectionDataset, collate
    from .loss import YOLOXLoss
    from .postprocess import PostprocessConfig, postprocess
    from .yolox import build

    seed = int(config.get("seed", 1337))
    common.seed_torch(seed, deterministic=False)   # cudnn determinism is very slow for detectors
    model_cfg, train_cfg = config["model"], config["train"]
    size = int(model_cfg["input_size"][0])
    num_classes = len(class_names)
    if not train_samples or not val_samples:
        raise RuntimeError(f"nothing to train on: {len(train_samples)} train, {len(val_samples)} val images")

    augment = train_cfg.get("augment") or {}
    train_ds = DetectionDataset(train_samples, size, train=True, augment=augment, class_of=class_of)
    val_ds = DetectionDataset(val_samples, size, train=False, class_of=class_of)
    workers = int(os.environ.get("SLURM_CPUS_PER_TASK", min(8, os.cpu_count() or 1)))
    batch = int(train_cfg["batch_size"])
    generator = torch.Generator().manual_seed(seed)
    train_dl = DataLoader(train_ds, batch_size=batch, shuffle=True, generator=generator, num_workers=workers,
                          collate_fn=collate, drop_last=True, worker_init_fn=common.worker_seed,
                          pin_memory=torch.cuda.is_available(), persistent_workers=False)
    val_dl = DataLoader(val_ds, batch_size=batch, num_workers=workers, collate_fn=collate, pin_memory=torch.cuda.is_available())

    dev = common.device()
    model = build(model_cfg["architecture"], num_classes)
    init = common.init_weights_path(config, "detection", root)
    if init is not None:
        state = torch.load(init, map_location="cpu", weights_only=True)["model"]
        if init_backbone_only:
            state = {k: v for k, v in state.items() if k.startswith("neck.backbone.")}
        loaded, new = common.load_matching(model, state)
        print(f"initialised from {init}: {loaded} tensors loaded, {new} new")
    model.to(dev)
    ema = ModelEMA(model)

    # SGD with no weight decay on norms and biases, as in YOLOX.
    decay: list[Any] = []
    no_decay: list[Any] = []
    for p in model.parameters():
        (no_decay if p.ndim <= 1 else decay).append(p)
    base_lr = float(train_cfg["lr"]) * batch / 64
    optimizer = torch.optim.SGD([{"params": decay, "weight_decay": float(train_cfg.get("weight_decay", 5e-4))},
                                 {"params": no_decay, "weight_decay": 0.0}], lr=base_lr, momentum=0.9, nesterov=True)
    epochs = int(train_cfg["epochs"])
    no_aug_epochs = min(int(train_cfg.get("no_aug_epochs", 15)), max(epochs // 5, 1))
    steps_per_epoch = len(train_dl)
    total, warmup = epochs * steps_per_epoch, int(train_cfg.get("warmup_epochs", 5)) * steps_per_epoch
    amp = common.amp_dtype(dev) if train_cfg.get("mixed_precision", True) else None
    scaler = torch.amp.GradScaler("cuda", enabled=amp == torch.float16)
    criterion = YOLOXLoss(num_classes)
    post = config.get("postprocess") or {}
    eval_post = PostprocessConfig(confidence_threshold=0.01, nms_iou_threshold=float(post.get("nms_iou_threshold", 0.5)),
                                  max_detections=100, min_box_side=0)

    if resume is None and train_cfg.get("auto_resume", True):
        resume = _unfinished_run(root, config, kind, run_label)
    out = resume if resume is not None else common.run_dir(root, config, kind, run_label)
    print(f"run folder {out}\nimages: train {len(train_ds)}, val {len(val_ds)}; classes {num_classes}; device {dev}, amp {amp}")
    timer = common.Timer()
    history: list[dict[str, Any]] = []
    best, best_epoch, step, start_epoch = -1.0, -1, 0, 0
    if resume is not None and (resume / "resume.pt").exists():
        state = torch.load(resume / "resume.pt", map_location="cpu", weights_only=False)
        model.load_state_dict(state["model"])
        ema.ema.load_state_dict(state["ema"])
        ema.updates = state["ema_updates"]
        optimizer.load_state_dict(state["optimizer"])
        scaler.load_state_dict(state["scaler"])
        best, best_epoch, step, start_epoch, history = (state["best"], state["best_epoch"], state["step"],
                                                         state["epoch"], state["history"])
        print(f"resuming {out} at epoch {start_epoch + 1}")
    eval_every = int(train_cfg.get("eval_every", 5))

    for epoch in range(start_epoch, epochs):
        late = epoch >= epochs - no_aug_epochs
        train_ds.mosaic_enabled = not late          # last epochs: no mosaic, add L1 loss (YOLOX recipe)
        model.train()
        sums: dict[str, float] = {}
        for images, targets in train_dl:
            images = images.to(dev, non_blocking=True)
            for group in optimizer.param_groups:
                group["lr"] = common.cosine_lr(step, total, base_lr, warmup)
            with torch.autocast(dev.type, dtype=amp or torch.float32, enabled=amp is not None):
                raw, grid = model(images)
            loss, parts = criterion(raw, grid, targets, use_l1=late)
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10.0)
            scaler.step(optimizer)
            scaler.update()
            ema.update(model)
            for k, v in {"loss": float(loss.detach()), **parts}.items():
                sums[k] = sums.get(k, 0.0) + v
            step += 1
        row: dict[str, Any] = {"epoch": epoch + 1, **{k: v / max(steps_per_epoch, 1) for k, v in sums.items()},
                               "hours": timer.hours()}
        if (epoch + 1) % eval_every == 0 or epoch + 1 == epochs:
            metrics = _evaluate(ema.ema, val_dl, dev, class_names, eval_post, np, torch, Detection, GroundTruth,
                                evaluate_detections, postprocess)
            row.update({"val_map50": metrics["map50"], "val_map50_95": metrics["map50_95"]})
            extra = {"class_names": class_names, "config": config, "run_label": run_label, "epoch": epoch + 1,
                     "input": "RGB 0..255, letterboxed with value 114"}
            if metrics["map50_95"] > best:
                best, best_epoch = metrics["map50_95"], epoch + 1
                common.save_checkpoint(out / "best.pt", ema.ema, extra)
                common.write_json(out / "val_metrics_best.json", metrics)
            common.save_checkpoint(out / "last.pt", ema.ema, extra)
        history.append(row)
        common.write_json(out / "history.json", history)
        torch.save({"model": model.state_dict(), "ema": ema.ema.state_dict(), "ema_updates": ema.updates,
                    "optimizer": optimizer.state_dict(), "scaler": scaler.state_dict(), "best": best,
                    "best_epoch": best_epoch, "step": step, "epoch": epoch + 1, "history": history},
                   out / "resume.tmp")
        (out / "resume.tmp").replace(out / "resume.pt")
        print(" ".join(f"{k}={v:.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in row.items()), flush=True)

    summary = {"kind": kind, "experiment": config.get("experiment"), "run_label": run_label, "best_epoch": best_epoch,
               "best_val_map50_95": best, "gpu_hours": timer.hours(), "images": {"train": len(train_ds), "val": len(val_ds)},
               "init": str(init) if init else "scratch", "environment": common.environment(),
               "note": "Validation split only. Test-set numbers come from `food-rec evaluate`, never from training."}
    common.write_json(out / "summary.json", summary)
    print(f"done: best val mAP50-95 {best:.4f} at epoch {best_epoch}; {out}")
    return out


def _unfinished_run(root: Path, config: dict[str, Any], kind: str, run_label: str) -> Path | None:
    """Newest run of this experiment that has a resume point but never finished (e.g. hit the time limit)."""
    name = (config.get("experiment") or {}).get("name") or kind
    runs = sorted((root / "models/runs" / name).glob(f"{run_label}-*"), reverse=True)
    for run in runs:
        if (run / "resume.pt").exists() and not (run / "summary.json").exists():
            print(f"found unfinished run {run}; continuing it")
            return run
    return None


def _evaluate(model: Any, loader: Any, dev: Any, class_names: list[str], post: Any, np: Any, torch: Any,
              Detection: Any, GroundTruth: Any, evaluate_detections: Any, postprocess: Any) -> dict[str, Any]:
    model.eval()
    dets, gts = [], []
    image_id = 0
    with torch.no_grad():
        for images, targets in loader:
            preds = model(images.to(dev, non_blocking=True)).float().cpu().numpy()
            for pred, target in zip(preds, targets, strict=True):
                boxes = np.concatenate([pred[:, :2] - pred[:, 2:4] / 2, pred[:, :2] + pred[:, 2:4] / 2], 1)
                cls_scores = pred[:, 5:]
                labels = cls_scores.argmax(1)
                scores = pred[:, 4] * cls_scores.max(1)
                top = np.argsort(-scores, kind="stable")[:1000]      # keeps NMS fast early in training
                boxes, labels, scores = boxes[top], labels[top], scores[top]
                for c in np.unique(labels):
                    mask = labels == c
                    kept_boxes, kept_scores = postprocess(boxes[mask], scores[mask], post)
                    for box, score in zip(kept_boxes, kept_scores, strict=True):
                        dets.append(Detection(image_id, int(c), tuple(float(v) for v in box), float(score)))
                for row in target.numpy():
                    cx, cy, w, h = row[1:]
                    gts.append(GroundTruth(image_id, int(row[0]), (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)))
                image_id += 1
    return evaluate_detections(dets, gts, dict(enumerate(class_names)), score_threshold=0.3)  # type: ignore[no-any-return]
