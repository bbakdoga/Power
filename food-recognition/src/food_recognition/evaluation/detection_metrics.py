"""COCO-style detection metrics: per-class AP, precision, recall, mAP@0.5 and mAP@0.5:0.95."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from ..detection.postprocess import box_iou

COCO_IOUS = [round(0.5 + 0.05 * i, 2) for i in range(10)]


@dataclass
class Detection:
    image_id: int
    category_id: int
    box: tuple[float, float, float, float]   # x1, y1, x2, y2
    score: float


@dataclass
class GroundTruth:
    image_id: int
    category_id: int
    box: tuple[float, float, float, float]


def average_precision(recall: np.ndarray, precision: np.ndarray) -> float:
    """101-point interpolated AP, as in pycocotools."""
    if recall.size == 0:
        return 0.0
    precision = np.concatenate([precision, [0.0]])
    for i in range(precision.size - 2, -1, -1):
        precision[i] = max(precision[i], precision[i + 1])
    points = np.linspace(0, 1, 101)
    idx = np.searchsorted(recall, points, side="left")
    return float(np.mean([precision[i] if i < recall.size else 0.0 for i in idx]))


def _match(dets: list[Detection], gts: list[GroundTruth], iou_threshold: float) -> tuple[np.ndarray, np.ndarray, int]:
    dets = sorted(dets, key=lambda d: -d.score)
    gts_by_image: dict[int, list[GroundTruth]] = {}
    for gt in gts:
        gts_by_image.setdefault(gt.image_id, []).append(gt)
    used = {img: np.zeros(len(items), dtype=bool) for img, items in gts_by_image.items()}
    tp = np.zeros(len(dets))
    for i, det in enumerate(dets):
        candidates = gts_by_image.get(det.image_id, [])
        if not candidates:
            continue
        ious = box_iou(np.array([det.box]), np.array([g.box for g in candidates]))[0]
        ious[used[det.image_id]] = -1
        best = int(np.argmax(ious))
        if ious[best] >= iou_threshold:
            tp[i] = 1
            used[det.image_id][best] = True
    scores = np.array([d.score for d in dets])
    return tp, scores, len(gts)


def evaluate_detections(dets: list[Detection], gts: list[GroundTruth], category_names: dict[int, str],
                        iou_thresholds: list[float] | None = None, score_threshold: float = 0.3) -> dict[str, Any]:
    iou_thresholds = iou_thresholds or COCO_IOUS
    per_class: dict[str, dict[str, float]] = {}
    for cat_id, name in sorted(category_names.items()):
        cat_dets = [d for d in dets if d.category_id == cat_id]
        cat_gts = [g for g in gts if g.category_id == cat_id]
        if not cat_gts:
            continue
        aps = []
        row: dict[str, float] = {"instances": float(len(cat_gts))}
        for t in iou_thresholds:
            tp, scores, n_gt = _match(cat_dets, cat_gts, t)
            cum_tp = np.cumsum(tp)
            cum_fp = np.cumsum(1 - tp)
            recall = cum_tp / max(n_gt, 1)
            precision = cum_tp / np.maximum(cum_tp + cum_fp, 1e-12)
            aps.append(average_precision(recall, precision))
            if abs(t - 0.5) < 1e-9:
                keep = scores >= score_threshold
                tp_at = float(tp[keep].sum())
                row["precision@0.5"] = tp_at / max(float(keep.sum()), 1.0)
                row["recall@0.5"] = tp_at / n_gt
                row["ap50"] = aps[-1]
        row["ap50_95"] = float(np.mean(aps))
        per_class[name] = row
    classes = list(per_class.values())
    return {
        "map50": float(np.mean([c.get("ap50", 0.0) for c in classes])) if classes else 0.0,
        "map50_95": float(np.mean([c["ap50_95"] for c in classes])) if classes else 0.0,
        "per_class": per_class,
        "iou_thresholds": iou_thresholds,
        "score_threshold": score_threshold,
    }
