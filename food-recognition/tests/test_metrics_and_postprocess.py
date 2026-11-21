from __future__ import annotations

import numpy as np
import pytest

from food_recognition.classification.postprocess import softmax, top_k_with_rejection
from food_recognition.detection.postprocess import PostprocessConfig, box_iou, nms, postprocess
from food_recognition.evaluation.classification_metrics import (
    classification_report,
    confusion_matrix,
    rejection_curve,
    top_k_accuracy,
)
from food_recognition.evaluation.detection_metrics import Detection, GroundTruth, evaluate_detections
from food_recognition.evaluation.records import EvaluationRecord
from food_recognition.export.coreml import check_parity, model_metadata


def test_iou_and_nms():
    boxes = np.array([[0, 0, 10, 10], [1, 1, 11, 11], [20, 20, 30, 30]], dtype=float)
    assert box_iou(boxes[:1], boxes[:1])[0, 0] == pytest.approx(1.0)
    assert box_iou(boxes[:1], boxes[2:])[0, 0] == 0.0
    keep = nms(boxes, np.array([0.9, 0.8, 0.7]), 0.5)
    assert keep.tolist() == [0, 2]


def test_postprocess_thresholds():
    boxes = np.array([[0, 0, 100, 100], [0, 0, 100, 100], [0, 0, 5, 5], [200, 200, 300, 300]], dtype=float)
    scores = np.array([0.9, 0.85, 0.95, 0.2])
    kept, kept_scores = postprocess(boxes, scores, PostprocessConfig(confidence_threshold=0.3, min_box_side=16))
    assert kept.tolist() == [[0, 0, 100, 100]] and kept_scores.tolist() == [0.9]


def test_top3_and_rejection():
    labels = ["a", "b", "c", "d"]
    r = top_k_with_rejection(np.array([0.7, 0.1, 0.15, 0.05]), labels)
    assert [p.label for p in r.top] == ["a", "c", "b"] and not r.rejected and not r.ambiguous
    r = top_k_with_rejection(np.array([0.3, 0.28, 0.22, 0.2]), labels)
    assert r.rejected and r.ambiguous
    assert softmax(np.array([1.0, 1.0])).tolist() == [0.5, 0.5]


def test_classification_report():
    y = np.array([0, 0, 1, 2])
    scores = np.array([[0.9, 0.05, 0.05], [0.2, 0.7, 0.1], [0.1, 0.8, 0.1], [0.5, 0.1, 0.4]])
    report = classification_report(y, scores, ["a", "b", "c"])
    assert report["top1_accuracy"] == pytest.approx(0.5)
    assert report["top3_accuracy"] == 1.0
    assert top_k_accuracy(y, scores, 2) == pytest.approx(1.0)
    assert report["confusion_matrix"] == [[1, 1, 0], [0, 1, 0], [1, 0, 0]]
    assert report["per_class"]["a"]["precision"] == pytest.approx(0.5)
    assert report["per_class"]["b"]["recall"] == 1.0
    assert confusion_matrix(y, y, 3).trace() == 4
    curve = rejection_curve(y, scores, [0.0, 0.85])
    assert curve[0]["coverage"] == 1.0 and curve[1]["coverage"] == 0.25


def test_detection_map_perfect_and_partial():
    gts = [GroundTruth(1, 1, (0, 0, 10, 10)), GroundTruth(1, 1, (20, 20, 30, 30)), GroundTruth(2, 1, (0, 0, 10, 10))]
    perfect = [Detection(g.image_id, g.category_id, g.box, 0.9) for g in gts]
    result = evaluate_detections(perfect, gts, {1: "food"})
    assert result["map50"] == pytest.approx(1.0) and result["map50_95"] == pytest.approx(1.0)
    partial = perfect[:2] + [Detection(2, 1, (50, 50, 60, 60), 0.95)]   # one miss, one false positive
    result = evaluate_detections(partial, gts, {1: "food"})
    row = result["per_class"]["food"]
    assert row["recall@0.5"] == pytest.approx(2 / 3)
    assert row["precision@0.5"] == pytest.approx(2 / 3)
    assert 0 < result["map50"] < 1


def test_evaluation_record_requires_dataset_and_method(tmp_path):
    record = EvaluationRecord("FoodClassifier", "0.1.0", "sha", "coreml-fp16", "", "test", "", {"top1": 0.9})
    problems = record.problems()
    assert any("dataset_version" in p for p in problems) and any("method" in p for p in problems)
    with pytest.raises(ValueError):
        record.save(tmp_path)
    ok = EvaluationRecord("FoodClassifier", "0.1.0", "sha", "coreml-fp16", "v0.1.0", "test", "held-out phone photos",
                          {"top1": 0.9}, slices={s: {} for s in ("mixed_plate", "low_light", "unusual_angle",
                                                                 "partially_visible")})
    assert ok.save(tmp_path).exists()


def test_parity_and_metadata():
    ref = np.array([[0.7, 0.3], [0.2, 0.8]])
    assert check_parity(ref, ref + 0.001, max_abs_diff=0.02, min_top1_agreement=0.99).passed
    assert not check_parity(ref, ref[:, ::-1], max_abs_diff=0.02, min_top1_agreement=0.99).passed
    meta = model_metadata(kind="classifier", labels=["a", "b"], model_version="0.1.0", dataset_version="v0.1.0",
                          taxonomy_version="0.1.0", author="Power", license_note="x")
    assert meta["com.power.food.labels"] == "a,b" and all(isinstance(v, str) for v in meta.values())
