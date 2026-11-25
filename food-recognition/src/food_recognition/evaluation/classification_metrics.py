"""Top-k accuracy, per-class precision/recall/F1 and confusion matrix (numpy only)."""

from __future__ import annotations

from typing import Any

import numpy as np


def confusion_matrix(y_true: np.ndarray, y_pred: np.ndarray, num_classes: int) -> np.ndarray:
    matrix = np.zeros((num_classes, num_classes), dtype=np.int64)
    np.add.at(matrix, (np.asarray(y_true, dtype=np.int64), np.asarray(y_pred, dtype=np.int64)), 1)
    return matrix


def top_k_accuracy(y_true: np.ndarray, scores: np.ndarray, k: int) -> float:
    scores = np.asarray(scores)
    y_true = np.asarray(y_true)
    if len(y_true) == 0:
        return float("nan")
    top = np.argsort(-scores, axis=1, kind="stable")[:, :k]
    return float(np.mean(np.any(top == y_true[:, None], axis=1)))


def classification_report(y_true: np.ndarray, scores: np.ndarray, labels: list[str]) -> dict[str, Any]:
    y_true = np.asarray(y_true, dtype=np.int64)
    scores = np.asarray(scores, dtype=np.float64)
    y_pred = np.argmax(scores, axis=1)
    cm = confusion_matrix(y_true, y_pred, len(labels))
    tp = np.diag(cm).astype(np.float64)
    predicted = cm.sum(axis=0).astype(np.float64)
    actual = cm.sum(axis=1).astype(np.float64)
    with np.errstate(divide="ignore", invalid="ignore"):
        precision = np.where(predicted > 0, tp / predicted, 0.0)
        recall = np.where(actual > 0, tp / actual, 0.0)
        f1 = np.where(precision + recall > 0, 2 * precision * recall / (precision + recall), 0.0)
    present = actual > 0
    per_class = {
        label: {"precision": float(precision[i]), "recall": float(recall[i]), "f1": float(f1[i]), "support": int(actual[i])}
        for i, label in enumerate(labels)
    }
    return {
        "top1_accuracy": top_k_accuracy(y_true, scores, 1),
        "top3_accuracy": top_k_accuracy(y_true, scores, min(3, len(labels))),
        "macro_precision": float(precision[present].mean()) if present.any() else 0.0,
        "macro_recall": float(recall[present].mean()) if present.any() else 0.0,
        "macro_f1": float(f1[present].mean()) if present.any() else 0.0,
        "per_class": per_class,
        "confusion_matrix": cm.tolist(),
        "labels": labels,
        "samples": int(len(y_true)),
    }


def rejection_curve(y_true: np.ndarray, scores: np.ndarray, thresholds: list[float]) -> list[dict[str, float]]:
    """Coverage vs accuracy-on-accepted for each threshold; used to pick reject_below."""
    y_true = np.asarray(y_true)
    scores = np.asarray(scores)
    confidence = scores.max(axis=1)
    correct = scores.argmax(axis=1) == y_true
    rows = []
    for t in thresholds:
        accepted = confidence >= t
        rows.append({"threshold": t, "coverage": float(accepted.mean()) if len(y_true) else 0.0,
                     "accuracy_on_accepted": float(correct[accepted].mean()) if accepted.any() else float("nan")})
    return rows


def open_set_metrics(known_confidence: np.ndarray, unknown_confidence: np.ndarray) -> dict[str, float]:
    """How well the top softmax score separates foods we know from unknown food.

    AUROC is the chance a random known crop scores higher than a random unknown
    one (0.5 = no separation). FPR@95TPR is the share of unknown crops still
    accepted at the threshold that keeps 95% of known crops (lower is better).
    """
    known = np.asarray(known_confidence, dtype=np.float64)
    unknown = np.asarray(unknown_confidence, dtype=np.float64)
    if len(known) == 0 or len(unknown) == 0:
        return {}
    values = np.concatenate([known, unknown])
    _, inverse, counts = np.unique(values, return_inverse=True, return_counts=True)
    average_rank = np.cumsum(counts) - (counts - 1) / 2.0          # 1-based ranks, ties averaged
    rank_sum = average_rank[inverse][: len(known)].sum()
    auroc = (rank_sum - len(known) * (len(known) + 1) / 2.0) / (len(known) * len(unknown))
    threshold = float(np.quantile(known, 0.05))
    return {"auroc": float(auroc), "fpr_at_95_tpr": float((unknown >= threshold).mean()),
            "threshold_at_95_tpr": threshold, "known": int(len(known)), "unknown": int(len(unknown))}
