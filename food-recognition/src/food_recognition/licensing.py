"""Licence gate: every external asset a config uses must be approved."""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import load_yaml

VALID_STATUSES = {"approved", "needs_review", "blocked"}
VALID_KINDS = {"code", "weights", "dataset", "tool"}


@dataclass(frozen=True)
class Asset:
    id: str
    kind: str
    name: str
    license: str
    status: str
    url: str | None = None
    notes: str | None = None


class LicenseError(RuntimeError):
    """Raised when a config uses an asset that is not cleared for commercial use."""


def load_assets(path: str | Path) -> dict[str, Asset]:
    raw = load_yaml(path).get("assets", [])
    assets: dict[str, Asset] = {}
    for entry in raw:
        asset = Asset(
            id=entry["id"],
            kind=entry["kind"],
            name=entry["name"],
            license=str(entry["license"]),
            status=entry["status"],
            url=entry.get("url"),
            notes=entry.get("notes"),
        )
        if asset.status not in VALID_STATUSES:
            raise ValueError(f"asset {asset.id}: unknown status {asset.status!r}")
        if asset.kind not in VALID_KINDS:
            raise ValueError(f"asset {asset.id}: unknown kind {asset.kind!r}")
        if asset.id in assets:
            raise ValueError(f"asset {asset.id} is listed twice")
        assets[asset.id] = asset
    return assets


def assets_used_by(config: dict[str, Any]) -> list[str]:
    """Asset ids a training config depends on: `assets:` plus `model.pretrained`."""
    used = list(config.get("assets", []) or [])
    pretrained = (config.get("model") or {}).get("pretrained")
    if pretrained:
        used.append(pretrained)
    return used


def check_assets(asset_ids: Iterable[str], registry: dict[str, Asset]) -> list[str]:
    """Return one problem string per asset that is unknown or not approved."""
    problems: list[str] = []
    for asset_id in asset_ids:
        asset = registry.get(asset_id)
        if asset is None:
            problems.append(f"{asset_id}: not listed in licenses/assets.yaml")
        elif asset.status != "approved":
            problems.append(f"{asset_id}: status is {asset.status} ({asset.license}). {asset.notes or ''}".strip())
    return problems


def require_approved(config: dict[str, Any], registry: dict[str, Asset]) -> None:
    problems = check_assets(assets_used_by(config), registry)
    if problems:
        raise LicenseError("Licence check failed:\n  " + "\n  ".join(problems))
