"""Food taxonomy loading and checks."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from ..config import load_yaml

NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


@dataclass(frozen=True)
class FoodClass:
    id: int
    name: str
    display_name: str
    group: str
    fdc_query: str | None = None
    open_images_candidate: str | None = None
    retired: bool = False


@dataclass(frozen=True)
class Taxonomy:
    version: str
    unknown: FoodClass
    classes: tuple[FoodClass, ...]

    @property
    def active(self) -> tuple[FoodClass, ...]:
        return tuple(c for c in self.classes if not c.retired)

    def all_categories(self) -> tuple[FoodClass, ...]:
        """Every label an annotation may use: unknown_food plus all classes."""
        return (self.unknown, *self.classes)

    def by_id(self) -> dict[int, FoodClass]:
        return {c.id: c for c in self.all_categories()}

    def by_name(self) -> dict[str, FoodClass]:
        return {c.name: c for c in self.all_categories()}

    def classifier_labels(self) -> list[str]:
        """Positive classes the classifier predicts, ordered by id."""
        return [c.name for c in sorted(self.active, key=lambda c: c.id)]

    def coco_categories(self) -> list[dict[str, object]]:
        return [
            {"id": c.id, "name": c.name, "supercategory": c.group}
            for c in sorted(self.all_categories(), key=lambda c: c.id)
        ]


def load_taxonomy(path: str | Path) -> Taxonomy:
    data = load_yaml(path)
    unknown_raw = data["unknown"]
    unknown = FoodClass(
        id=int(unknown_raw["id"]),
        name=unknown_raw["name"],
        display_name=unknown_raw["display_name"],
        group="unknown",
    )
    classes = tuple(
        FoodClass(
            id=int(c["id"]),
            name=c["name"],
            display_name=c["display_name"],
            group=c["group"],
            fdc_query=c.get("fdc_query"),
            open_images_candidate=c.get("open_images_candidate"),
            retired=bool(c.get("retired", False)),
        )
        for c in data["classes"]
    )
    taxonomy = Taxonomy(version=str(data["version"]), unknown=unknown, classes=classes)
    problems = check_taxonomy(taxonomy)
    if problems:
        raise ValueError(f"{path}: invalid taxonomy:\n  " + "\n  ".join(problems))
    return taxonomy


def check_taxonomy(taxonomy: Taxonomy, min_classes: int = 30, max_classes: int = 50) -> list[str]:
    problems: list[str] = []
    seen_ids: set[int] = set()
    seen_names: set[str] = set()
    for c in taxonomy.all_categories():
        if c.id in seen_ids:
            problems.append(f"duplicate id {c.id}")
        if c.name in seen_names:
            problems.append(f"duplicate name {c.name}")
        if not NAME_PATTERN.match(c.name):
            problems.append(f"name {c.name!r} must be snake_case")
        if c.id < 0:
            problems.append(f"{c.name}: negative id")
        seen_ids.add(c.id)
        seen_names.add(c.name)
    active = len(taxonomy.active)
    if not min_classes <= active <= max_classes:
        problems.append(f"{active} active classes; expected {min_classes}-{max_classes}")
    return problems
