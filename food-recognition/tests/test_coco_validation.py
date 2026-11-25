from __future__ import annotations

import copy

import pytest

from food_recognition.dataset.coco import CocoFormatError, normalize_categories, parse_coco, validate_annotations
from food_recognition.dataset.issues import errors


def base_coco(taxonomy):
    return {
        "images": [{"id": 1, "file_name": "a.jpg", "width": 640, "height": 480},
                   {"id": 2, "file_name": "b.jpg", "width": 640, "height": 480, "no_food": True}],
        "annotations": [{"id": 1, "image_id": 1, "category_id": 4, "bbox": [10, 20, 200, 150], "iscrowd": 0},
                        {"id": 2, "image_id": 1, "category_id": 13, "bbox": [300, 200, 250, 200], "iscrowd": 0,
                         "attributes": {"occluded": True}}],
        "categories": taxonomy.coco_categories(),
    }


def codes(issues):
    return {i.code for i in issues}


def test_valid_coco_has_no_errors(taxonomy):
    dataset, parse_issues = parse_coco(base_coco(taxonomy))
    assert parse_issues == []
    assert errors(validate_annotations(dataset, taxonomy)) == []
    assert dataset.class_counts() == {4: 1, 13: 1}


def test_missing_top_level_key_raises(taxonomy):
    data = base_coco(taxonomy)
    del data["annotations"]
    with pytest.raises(CocoFormatError):
        parse_coco(data)


@pytest.mark.parametrize("bbox, code", [
    ([10, 10, 0, 50], "bbox_empty"),
    ([600, 10, 100, 50], "bbox_out_of_bounds"),
    ([-5, 10, 50, 50], "bbox_out_of_bounds"),
    ([10, 10, "x", 50], "annotation_malformed"),
    ([10, 10, 50], "annotation_malformed"),
    ([10, 10, float("nan"), 50], "annotation_malformed"),
])
def test_bad_boxes_are_errors(taxonomy, bbox, code):
    data = base_coco(taxonomy)
    data["annotations"][0]["bbox"] = bbox
    dataset, parse_issues = parse_coco(data)
    issues = parse_issues + validate_annotations(dataset, taxonomy)
    assert code in codes(errors(issues))


def test_box_within_rounding_tolerance_is_ok(taxonomy):
    data = base_coco(taxonomy)
    data["annotations"][0]["bbox"] = [440.5, 10, 200, 100]  # 0.5 px past the right edge
    dataset, _ = parse_coco(data)
    assert "bbox_out_of_bounds" not in codes(validate_annotations(dataset, taxonomy))


def test_unknown_category_orphans_and_duplicates(taxonomy):
    data = base_coco(taxonomy)
    data["annotations"].append({"id": 3, "image_id": 1, "category_id": 999, "bbox": [1, 1, 50, 50]})
    data["annotations"].append({"id": 4, "image_id": 77, "category_id": 4, "bbox": [1, 1, 50, 50]})
    data["annotations"].append(copy.deepcopy(data["annotations"][0]))          # duplicate id
    data["images"].append({"id": 1, "file_name": "c.jpg", "width": 10, "height": 10})  # duplicate image id
    dataset, parse_issues = parse_coco(data)
    found = codes(parse_issues + validate_annotations(dataset, taxonomy))
    assert {"annotation_unknown_category", "annotation_orphan", "annotation_duplicate_id",
            "image_duplicate_id"} <= found


def test_no_food_and_unannotated_images(taxonomy):
    data = base_coco(taxonomy)
    data["annotations"].append({"id": 9, "image_id": 2, "category_id": 4, "bbox": [1, 1, 50, 50]})
    data["images"].append({"id": 3, "file_name": "c.jpg", "width": 640, "height": 480})
    dataset, _ = parse_coco(data)
    issues = validate_annotations(dataset, taxonomy, allow_images_without_boxes=False)
    assert {"no_food_with_boxes", "image_unannotated"} <= codes(errors(issues))


def test_category_list_must_match_taxonomy(taxonomy):
    data = base_coco(taxonomy)
    data["categories"] = [{"id": 4, "name": "Salmon"}]
    dataset, _ = parse_coco(data)
    assert "category_mismatch" in codes(validate_annotations(dataset, taxonomy))


def test_normalize_maps_label_studio_names(taxonomy):
    data = base_coco(taxonomy)
    data["categories"] = [{"id": 0, "name": "salmon"}, {"id": 1, "name": "White Rice"}]
    data["annotations"][0]["category_id"] = 0
    data["annotations"][1]["category_id"] = 1
    dataset, _ = parse_coco(data)
    normalized, issues = normalize_categories(dataset, taxonomy)
    assert issues == []
    assert [a.category_id for a in normalized.annotations] == [4, 13]
    assert errors(validate_annotations(normalized, taxonomy)) == []


def test_normalize_reports_unknown_labels(taxonomy):
    data = base_coco(taxonomy)
    data["categories"] = [{"id": 4, "name": "lasagna"}, {"id": 13, "name": "white_rice"}]
    dataset, _ = parse_coco(data)
    _, issues = normalize_categories(dataset, taxonomy)
    assert "category_unmapped" in codes(issues)
