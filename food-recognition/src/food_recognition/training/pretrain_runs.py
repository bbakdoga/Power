"""Open Images pretraining runs for both networks.

The finished best checkpoint is copied to the path that
`model.pretrained: openimages_pretrain_own` resolves to (see
training/common.py), so the fine-tuning configs pick it up automatically.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any

from ..config import resolve, seed_everything
from ..licensing import load_assets, require_approved
from .common import PRETRAINED_WEIGHTS


def _paths(config: dict[str, Any], root: Path) -> tuple[Path, Path]:
    data = config["data"]
    return resolve(data["selection_dir"], root), resolve(data["images_dir"], root)


def _register(run: Path, kind: str, root: Path) -> Path:
    target = root / PRETRAINED_WEIGHTS["openimages_pretrain_own"][kind]
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(run / "best.pt", target)
    print(f"registered {run / 'best.pt'} as {target}")
    return target


def pretrain_detector(config: dict[str, Any], root: Path, resume: Path | None = None) -> Path:
    require_approved(config, load_assets(resolve("licenses/assets.yaml", root)))
    seed_everything(int(config.get("seed", 1337)))
    from ..detection.train import fit
    from .openimages_pretrain import load_pretrain_samples

    selection_dir, images_dir = _paths(config, root)
    splits, names = load_pretrain_samples(selection_dir, images_dir)
    identity = {i: i for i in range(len(names))}
    run = fit(config, splits["train"], splits["val"], class_of=identity, class_names=names, root=root,
              run_label="openimages", kind="detection-pretrain", resume=resume)
    _register(run, "detection", root)
    return run


def pretrain_classifier(config: dict[str, Any], root: Path) -> Path:
    """Multi-label image classification over the Open Images boxable classes (whole images)."""
    require_approved(config, load_assets(resolve("licenses/assets.yaml", root)))
    seed = int(config.get("seed", 1337))
    seed_everything(seed)
    import numpy as np
    import timm
    import torch
    import torch.nn.functional as F
    from torch.utils.data import DataLoader, Dataset
    from torchvision.transforms import v2 as T

    from ..classification.dataset import MEAN, STD, load_rgb
    from . import common
    from .openimages_pretrain import load_pretrain_samples

    common.seed_torch(seed)
    selection_dir, images_dir = _paths(config, root)
    splits, names = load_pretrain_samples(selection_dir, images_dir)
    model_cfg, train_cfg = config["model"], config["train"]
    size, num_classes = int(model_cfg["input_size"]), len(names)

    class MultiLabel(Dataset[tuple[torch.Tensor, torch.Tensor]]):
        def __init__(self, samples: list[Any], train: bool) -> None:
            self.samples = samples
            steps: list[Any] = ([T.RandomResizedCrop(size, scale=(0.25, 1.0), antialias=True), T.RandomHorizontalFlip(),
                                 T.ColorJitter(0.4, 0.4, 0.4, 0.05)] if train else
                                [T.Resize(size, antialias=True), T.CenterCrop(size)])
            self.transform = T.Compose([T.PILToTensor(), *steps, T.ToDtype(torch.float32, scale=True), T.Normalize(MEAN, STD)])

        def __len__(self) -> int:
            return len(self.samples)

        def __getitem__(self, i: int) -> tuple[torch.Tensor, torch.Tensor]:
            sample = self.samples[i]
            target = torch.zeros(num_classes)
            target[list(set(sample.category_ids))] = 1.0
            return self.transform(load_rgb(sample.path)), target

    workers = int(os.environ.get("SLURM_CPUS_PER_TASK", min(8, os.cpu_count() or 1)))
    batch = int(train_cfg["batch_size"])
    cuda = torch.cuda.is_available()
    train_dl = DataLoader(MultiLabel(splits["train"], True), batch_size=batch, shuffle=True, num_workers=workers,
                          generator=torch.Generator().manual_seed(seed), drop_last=True, pin_memory=cuda,
                          worker_init_fn=common.worker_seed, persistent_workers=workers > 0)
    val_dl = DataLoader(MultiLabel(splits["val"], False), batch_size=batch, num_workers=workers, pin_memory=cuda)

    dev = common.device()
    model = timm.create_model(model_cfg["architecture"], pretrained=False, num_classes=num_classes, drop_rate=0.2).to(dev)
    epochs = int(train_cfg["epochs"])
    total, warmup = epochs * len(train_dl), int(train_cfg.get("warmup_epochs", 3)) * len(train_dl)
    base_lr = float(train_cfg["lr"]) * batch / 256
    optimizer = torch.optim.AdamW(model.parameters(), lr=base_lr, weight_decay=float(train_cfg.get("weight_decay", 0.05)))
    amp = common.amp_dtype(dev) if train_cfg.get("mixed_precision", True) else None
    scaler = torch.amp.GradScaler("cuda", enabled=amp == torch.float16)
    out = common.run_dir(root, config, "classification-pretrain", "openimages")
    print(f"run folder {out}\nimages: train {len(splits['train'])}, val {len(splits['val'])}; classes {num_classes}; device {dev}")
    timer, history, best, step = common.Timer(), [], -1.0, 0

    for epoch in range(epochs):
        model.train()
        running = 0.0
        for images, targets in train_dl:
            images, targets = images.to(dev, non_blocking=True), targets.to(dev, non_blocking=True)
            for group in optimizer.param_groups:
                group["lr"] = common.cosine_lr(step, total, base_lr, warmup)
            with torch.autocast(dev.type, dtype=amp or torch.float32, enabled=amp is not None):
                logits = model(images)
            loss = F.binary_cross_entropy_with_logits(logits.float(), targets)
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            running += float(loss.detach())
            step += 1
        model.eval()
        hits, count = 0, 0
        with torch.no_grad():
            for images, targets in val_dl:
                top = model(images.to(dev)).float().argmax(1).cpu()
                hits += int(targets[torch.arange(len(top)), top].sum())
                count += len(top)
        precision_at_1 = hits / max(count, 1)       # top prediction is one of the photo's labels
        history.append({"epoch": epoch + 1, "train_loss": running / max(len(train_dl), 1),
                        "val_precision_at_1": precision_at_1, "hours": timer.hours()})
        print(history[-1], flush=True)
        extra = {"class_names": names, "config": config, "epoch": epoch + 1}
        common.save_checkpoint(out / "last.pt", model, extra)
        if precision_at_1 > best:
            best = precision_at_1
            common.save_checkpoint(out / "best.pt", model, extra)
        common.write_json(out / "history.json", history)
    common.write_json(out / "summary.json", {"kind": "classification-pretrain", "best_val_precision_at_1": best,
                                             "gpu_hours": timer.hours(), "environment": common.environment(),
                                             "train_images": len(splits["train"]), "val_images": len(splits["val"]),
                                             "mean_labels_per_image": float(np.mean([len(set(s.category_ids))
                                                                                     for s in splits["val"]] or [0]))})
    _register(out, "classification", root)
    return out
