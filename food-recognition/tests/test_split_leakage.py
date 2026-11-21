from __future__ import annotations

from dataclasses import replace

import pytest

from food_recognition.dataset.manifest import ImageRecord
from food_recognition.dataset.split import check_leakage, merge_groups, split_by_group

RATIOS = {"train": 0.8, "val": 0.1, "test": 0.1}


def records(n_groups: int, per_group: int, source: str = "owned") -> list[ImageRecord]:
    out = []
    for g in range(n_groups):
        for i in range(per_group):
            out.append(ImageRecord(file=f"{source}/g{g}_{i}.jpg", sha256=f"{source}{g}-{i}", source_id=source,
                                   source_type="owned", license="owned", commercial_use=True,
                                   redistribution=True, group_id=f"{source}-meal{g}"))
    return out


def test_groups_never_span_splits(owned_source):
    recs = records(50, 3)
    result, issues = split_by_group(recs, owned_source, RATIOS, seed=1)
    assert issues == []
    assert check_leakage(result.assignment, recs) == []
    for g in range(50):
        assert len({result.assignment[f"owned/g{g}_{i}.jpg"] for i in range(3)}) == 1


def test_split_is_deterministic_and_close_to_ratios(owned_source):
    recs = records(100, 2)
    a, _ = split_by_group(recs, owned_source, RATIOS, seed=7)
    b, _ = split_by_group(list(reversed(recs)), owned_source, RATIOS, seed=7)
    assert a.assignment == b.assignment
    counts = a.counts()
    assert counts == {"train": 160, "val": 20, "test": 20}
    c, _ = split_by_group(recs, owned_source, RATIOS, seed=8)
    assert c.assignment != a.assignment


def test_pinned_source_goes_to_test_only(owned_source):
    recs = records(30, 2) + records(5, 2, source="evalset")
    result, _ = split_by_group(recs, owned_source, RATIOS, seed=1)
    assert all(result.assignment[r.file] == "test" for r in recs if r.source_id == "evalset")


def test_near_duplicates_are_merged_into_one_group(owned_source):
    recs = records(40, 1)
    pairs = [(f"owned/g{i}_0.jpg", f"owned/g{i + 1}_0.jpg", 2) for i in range(0, 40, 2)]
    result, _ = split_by_group(recs, owned_source, RATIOS, seed=3, near_duplicates=pairs)
    for a, b, _ in pairs:
        assert result.assignment[a] == result.assignment[b]


def test_exact_duplicates_across_groups_are_merged():
    recs = records(2, 1)
    recs[1] = replace(recs[1], sha256=recs[0].sha256)
    groups = merge_groups(recs)
    assert groups[recs[0].file] == groups[recs[1].file]


def test_leakage_checker_catches_every_kind():
    recs = records(3, 2)
    assignment = {r.file: "train" for r in recs}
    assignment["owned/g0_1.jpg"] = "test"                   # same group, different split
    found = {i.code for i in check_leakage(assignment, recs)}
    assert "leak_group" in found

    recs2 = records(2, 1)
    recs2[1] = replace(recs2[1], sha256=recs2[0].sha256)
    found = {i.code for i in check_leakage({recs2[0].file: "train", recs2[1].file: "val"}, recs2)}
    assert "leak_sha256" in found

    recs3 = records(2, 1)
    dh = {recs3[0].file: 0b1010, recs3[1].file: 0b1011}
    found = {i.code for i in check_leakage({recs3[0].file: "train", recs3[1].file: "test"}, recs3, dh, 4)}
    assert "leak_near_duplicate" in found


def test_conflicting_pins_are_reported(owned_source):
    recs = records(1, 1) + records(1, 1, source="evalset")
    pinned = dict(owned_source)
    pinned["owned"] = replace(pinned["owned"], pinned_split="train")
    pair = [(recs[0].file, recs[1].file, 0)]
    _, issues = split_by_group(recs, pinned, RATIOS, seed=1, near_duplicates=pair)
    assert [i.code for i in issues] == ["split_conflicting_pins"]


def test_ratios_must_sum_to_one(owned_source):
    with pytest.raises(ValueError):
        split_by_group(records(2, 1), owned_source, {"train": 0.5, "val": 0.1, "test": 0.1}, seed=1)
