"""Leakage-safe train/val/test splits.

Images are split by group (photo session, meal, or source), never one by one.
Near-duplicate photos are merged into one group first, so a slightly different
shot of the same plate can never sit in train while its twin is in test.
Sources can be pinned to a split, e.g. a held-out phone-photo test set.
"""

from __future__ import annotations

import json
import random
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from .images import hamming
from .issues import Issue
from .manifest import ImageRecord, Source

SPLIT_NAMES = ("train", "val", "test")


class _UnionFind:
    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, item: str) -> str:
        self.parent.setdefault(item, item)
        root = item
        while self.parent[root] != root:
            root = self.parent[root]
        while self.parent[item] != root:  # path compression
            self.parent[item], item = root, self.parent[item]
        return root

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[max(ra, rb)] = min(ra, rb)  # deterministic root


@dataclass
class SplitResult:
    assignment: dict[str, str]          # file -> split
    group_of: dict[str, str]            # file -> merged group id

    def files(self, split: str) -> list[str]:
        return sorted(f for f, s in self.assignment.items() if s == split)

    def counts(self) -> dict[str, int]:
        return {name: len(self.files(name)) for name in SPLIT_NAMES}

    def save(self, directory: str | Path, meta: dict[str, object] | None = None) -> Path:
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "splits.json"
        payload = {"meta": meta or {}, "counts": self.counts(),
                   "splits": {name: self.files(name) for name in SPLIT_NAMES},
                   "groups": dict(sorted(self.group_of.items()))}
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return path


def merge_groups(records: list[ImageRecord], near_duplicates: list[tuple[str, str, int]] | None = None,
                 sha256_by_file: dict[str, str] | None = None) -> dict[str, str]:
    """Return file -> group id after merging groups linked by (near) duplicates."""
    uf = _UnionFind()
    for record in records:
        uf.union(f"file:{record.file}", f"group:{record.split_group}")
    sha_by_file = dict(sha256_by_file or {})
    for record in records:
        sha_by_file.setdefault(record.file, record.sha256)
    first_with_hash: dict[str, str] = {}
    for file_name, digest in sorted(sha_by_file.items()):
        if digest in first_with_hash:
            uf.union(f"file:{file_name}", f"file:{first_with_hash[digest]}")
        else:
            first_with_hash[digest] = file_name
    for a, b, _ in near_duplicates or []:
        uf.union(f"file:{a}", f"file:{b}")
    groups: dict[str, str] = {}
    for record in records:
        root = uf.find(f"file:{record.file}")
        groups[record.file] = root.split(":", 1)[1]
    return groups


def split_by_group(records: list[ImageRecord], sources: dict[str, Source], ratios: dict[str, float], seed: int,
                   near_duplicates: list[tuple[str, str, int]] | None = None) -> tuple[SplitResult, list[Issue]]:
    """Deterministically assign whole groups to splits, approximating `ratios` by image count."""
    issues: list[Issue] = []
    total_ratio = sum(ratios.get(n, 0.0) for n in SPLIT_NAMES)
    if abs(total_ratio - 1.0) > 1e-6:
        raise ValueError(f"split ratios must sum to 1, got {total_ratio}")

    group_of = merge_groups(records, near_duplicates)
    members: dict[str, list[ImageRecord]] = defaultdict(list)
    for record in records:
        members[group_of[record.file]].append(record)

    assignment: dict[str, str] = {}
    free_groups: list[str] = []
    for group_id in sorted(members):
        pins: set[str] = {str(sources[r.source_id].pinned_split) for r in members[group_id]
                          if r.source_id in sources and sources[r.source_id].pinned_split}
        if len(pins) > 1:
            issues.append(Issue("error", "split_conflicting_pins",
                                f"group {group_id} links images pinned to {sorted(pins)}; they are near duplicates",
                                members[group_id][0].file))
            pins = {"test"} if "test" in pins else {sorted(pins)[0]}
        if pins:
            split = pins.pop()
            for record in members[group_id]:
                assignment[record.file] = split
        else:
            free_groups.append(group_id)

    rng = random.Random(seed)
    rng.shuffle(free_groups)
    # Largest groups first so the greedy fill stays close to the target ratios.
    free_groups.sort(key=lambda g: len(members[g]), reverse=True)
    total = len(records)
    filled = {name: sum(1 for s in assignment.values() if s == name) for name in SPLIT_NAMES}
    for group_id in free_groups:
        size = len(members[group_id])
        deficits = {name: ratios.get(name, 0.0) * total - filled[name] for name in SPLIT_NAMES if ratios.get(name, 0.0) > 0}
        split = max(deficits, key=lambda n: (deficits[n], -SPLIT_NAMES.index(n)))
        for record in members[group_id]:
            assignment[record.file] = split
        filled[split] += size
    return SplitResult(assignment=assignment, group_of=group_of), issues


def check_leakage(assignment: dict[str, str], records: list[ImageRecord],
                  dhashes: dict[str, int] | None = None, max_hamming: int = 4) -> list[Issue]:
    """Report any group, exact duplicate or near duplicate that spans two splits."""
    issues: list[Issue] = []
    by_file = {r.file: r for r in records}

    for label, key in (("group", lambda r: r.split_group), ("sha256", lambda r: r.sha256)):
        seen: dict[str, tuple[str, str]] = {}
        for file_name in sorted(assignment):
            record = by_file.get(file_name)
            if record is None:
                continue
            k = key(record)
            split = assignment[file_name]
            if k in seen and seen[k][0] != split:
                issues.append(Issue("error", f"leak_{label}",
                                    f"{label} {k[:16]} is in {seen[k][0]} ({seen[k][1]}) and {split}", file_name))
            seen.setdefault(k, (split, file_name))

    if dhashes:
        items = sorted((f, h) for f, h in dhashes.items() if f in assignment)
        for i, (fa, ha) in enumerate(items):
            for fb, hb in items[i + 1:]:
                if assignment[fa] != assignment[fb] and hamming(ha, hb) <= max_hamming:
                    issues.append(Issue("error", "leak_near_duplicate",
                                        f"near duplicate {fb} is in {assignment[fb]}, this is in {assignment[fa]}", fa))
    return issues


def load_split(path: str | Path) -> dict[str, str]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return {f: name for name, files in data["splits"].items() for f in files}
