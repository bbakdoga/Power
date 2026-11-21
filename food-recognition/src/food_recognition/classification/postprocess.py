"""Top-k predictions with an unknown/rejection rule, mirrored in the Swift app."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Prediction:
    label: str
    confidence: float


@dataclass(frozen=True)
class ClassificationResult:
    top: list[Prediction]
    rejected: bool          # True -> show "Unknown food" and let the user pick
    ambiguous: bool         # True -> top two are too close; ask the user to choose


def softmax(logits: np.ndarray) -> np.ndarray:
    logits = np.asarray(logits, dtype=np.float64)
    shifted = logits - logits.max(axis=-1, keepdims=True)
    exp = np.exp(shifted)
    return exp / exp.sum(axis=-1, keepdims=True)


def top_k_with_rejection(probabilities: np.ndarray, labels: list[str], *, k: int = 3,
                         reject_below: float = 0.40, reject_margin: float = 0.05) -> ClassificationResult:
    probs = np.asarray(probabilities, dtype=np.float64).reshape(-1)
    if probs.shape[0] != len(labels):
        raise ValueError(f"{probs.shape[0]} scores for {len(labels)} labels")
    order = np.argsort(-probs, kind="stable")[:k]
    top = [Prediction(labels[i], float(probs[i])) for i in order]
    rejected = not top or top[0].confidence < reject_below
    ambiguous = len(top) > 1 and (top[0].confidence - top[1].confidence) < reject_margin
    return ClassificationResult(top=top, rejected=rejected, ambiguous=ambiguous)
