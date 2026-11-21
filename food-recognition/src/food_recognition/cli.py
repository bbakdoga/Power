"""`food-rec` command line interface. Run `food-rec --help` for the list of commands."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .config import load_yaml, project_root, resolve, seed_everything
from .dataset.coco import CocoAnnotation, CocoImage, load_coco, normalize_categories, save_coco
from .dataset.issues import Issue, errors
from .dataset.manifest import append_records, load_manifest, load_sources, write_manifest
from .dataset.taxonomy import load_taxonomy
from .licensing import assets_used_by, check_assets, load_assets

DEFAULT_TRAIN_CONFIGS = ["configs/detection.yaml", "configs/classification.yaml"]


def _print_issues(issues: list[Issue], limit: int = 50) -> None:
    for issue in issues[:limit]:
        where = f" [{issue.image}]" if issue.image else ""
        print(f"  {issue.severity.upper():7} {issue.code}{where}: {issue.message}")
    if len(issues) > limit:
        print(f"  ... and {len(issues) - limit} more (see the JSON output)")


class Context:
    def __init__(self, dataset_config: str) -> None:
        self.root = project_root()
        self.cfg = load_yaml(resolve(dataset_config, self.root))
        self.paths = {k: resolve(v, self.root) for k, v in self.cfg["paths"].items()}
        self.seed = int(self.cfg.get("seed", 1337))

    def taxonomy(self):  # type: ignore[no-untyped-def]
        return load_taxonomy(self.paths["taxonomy"])

    def sources(self):  # type: ignore[no-untyped-def]
        path = self.paths["sources"]
        if not path.exists():
            raise SystemExit(f"{path} not found. Copy data/manifests/sources.example.yaml to sources.yaml and fill it in.")
        return load_sources(path)

    def records(self):  # type: ignore[no-untyped-def]
        path = self.paths["manifest"]
        return load_manifest(path) if path.exists() else ([], [])


# ---------------------------------------------------------------- commands --

def cmd_check_taxonomy(ctx: Context, _: argparse.Namespace) -> int:
    taxonomy = ctx.taxonomy()
    print(f"taxonomy v{taxonomy.version}: {len(taxonomy.active)} active classes + {taxonomy.unknown.name}")
    return 0


def cmd_check_licenses(ctx: Context, args: argparse.Namespace) -> int:
    registry = load_assets(resolve("licenses/assets.yaml", ctx.root))
    failed = False
    for config_path in args.configs or DEFAULT_TRAIN_CONFIGS:
        cfg = load_yaml(resolve(config_path, ctx.root))
        problems = check_assets(assets_used_by(cfg), registry)
        print(f"{config_path}: {'OK' if not problems else 'BLOCKED'}")
        for p in problems:
            print(f"  {p}")
        failed |= bool(problems)
    pending = [a for a in registry.values() if a.status == "needs_review"]
    if pending:
        print("\nAwaiting a decision (not used by any config yet):")
        for a in pending:
            print(f"  {a.id}: {a.license}")
    return 1 if failed else 0


def cmd_import(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.importer import ImportRefused, import_folder

    sources = ctx.sources()
    source = sources.get(args.source_id)
    if source is None:
        print(f"unknown source {args.source_id}; add it to sources.yaml first")
        return 1
    records, _ = ctx.records()
    try:
        new, skipped = import_folder(args.folder, source, ctx.paths["raw_dir"],
                                     allowed_licenses=set(ctx.cfg["rights"]["allowed_licenses"]),
                                     existing_hashes={r.sha256 for r in records},
                                     group_id=args.group_id, attribution=args.attribution)
    except ImportRefused as exc:
        print(f"Import refused: {exc}")
        return 1
    append_records(ctx.paths["manifest"], new)
    print(f"imported {len(new)} images into {ctx.paths['raw_dir'] / source.source_id}; skipped {len(skipped)} duplicates")
    print("Next: annotate them in Label Studio (docs/annotation_guidelines.md), then `food-rec normalize`.")
    return 0


def cmd_normalize(ctx: Context, args: argparse.Namespace) -> int:
    dataset, issues = load_coco(args.input)
    normalized, more = normalize_categories(dataset, ctx.taxonomy())
    issues += more
    # Label Studio exports file names with an upload prefix; strip to the path under data/raw.
    if args.strip_prefix:
        for img in normalized.images:
            if img.file_name.startswith(args.strip_prefix):
                img.file_name = img.file_name[len(args.strip_prefix):]
    _print_issues(issues)
    if errors(issues):
        print("not written: fix the errors above")
        return 1
    out = Path(args.output) if args.output else ctx.paths["annotations"]
    save_coco(normalized, out)
    print(f"wrote {out} ({len(normalized.images)} images, {len(normalized.annotations)} boxes)")
    return 0


def _validate(ctx: Context, check_files: bool):  # type: ignore[no-untyped-def]
    from .dataset.validate import ValidationSettings, validate_dataset

    taxonomy = ctx.taxonomy()
    dataset, parse_issues = load_coco(ctx.paths["annotations"])
    records, manifest_issues = ctx.records()
    result = validate_dataset(dataset, taxonomy, records, ctx.sources(), ctx.paths["raw_dir"],
                              ValidationSettings.from_config(ctx.cfg), check_files=check_files)
    result.issues[:0] = parse_issues + manifest_issues
    return taxonomy, dataset, records, result


def cmd_validate(ctx: Context, args: argparse.Namespace) -> int:
    _, _, _, result = _validate(ctx, not args.no_files)
    out = ctx.paths["reports_dir"] / "validation.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"summary": result.summary(), "issues": [i.to_dict() for i in result.issues]},
                              indent=2) + "\n", encoding="utf-8")
    _print_issues(result.issues)
    summary = result.summary()
    print(f"\n{summary['images']} images, {summary['annotations']} boxes, "
          f"{summary['errors']} errors, {summary['warnings']} warnings -> {out}")
    return 0 if result.ok else 1


def cmd_split(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.split import check_leakage, split_by_group

    _, _, records, result = _validate(ctx, True)
    if not result.ok and not args.force:
        print("validation failed; run `food-rec validate` and fix the errors first")
        return 1
    annotated = {img_file for img_file in result.hashes}
    usable = [r for r in records if r.file in annotated]
    split, issues = split_by_group(usable, ctx.sources(), ctx.cfg["split"]["ratios"], ctx.seed,
                                   near_duplicates=result.near_duplicates)
    issues += check_leakage(split.assignment, usable, result.dhashes,
                            int(ctx.cfg["validation"]["near_duplicate_hamming"]))
    _print_issues(issues)
    if errors(issues):
        return 1
    path = split.save(ctx.paths["splits_dir"], {"seed": ctx.seed, "ratios": ctx.cfg["split"]["ratios"]})
    print(f"wrote {path}: {split.counts()}")
    return 0


def cmd_report(ctx: Context, _: argparse.Namespace) -> int:
    from .dataset.report import write_report
    from .dataset.split import load_split

    taxonomy, dataset, _, result = _validate(ctx, True)
    split_path = ctx.paths["splits_dir"] / "splits.json"
    assignment = load_split(split_path) if split_path.exists() else None
    path = write_report(dataset, taxonomy, result, ctx.paths["raw_dir"], ctx.paths["reports_dir"],
                        split_assignment=assignment, seed=ctx.seed)
    print(f"wrote {path}")
    return 0


def cmd_freeze(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.versioning import freeze_dataset

    _, _, _, result = _validate(ctx, True)
    path = freeze_dataset(args.version, annotations=ctx.paths["annotations"], manifest=ctx.paths["manifest"],
                          splits=ctx.paths["splits_dir"] / "splits.json", taxonomy=ctx.paths["taxonomy"],
                          validation_summary=result.summary(), out_dir=ctx.paths["dataset_versions_dir"],
                          notes=args.notes or "")
    print(f"froze dataset {args.version} -> {path}")
    return 0


def cmd_labelstudio_config(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.labelstudio import labeling_config

    out = resolve(args.output, ctx.root)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(labeling_config(ctx.taxonomy()), encoding="utf-8")
    print(f"wrote {out}")
    return 0


def cmd_ingest_corrections(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.corrections import correction_to_record, strip_metadata, validate_correction
    from .dataset.images import sha256_file

    taxonomy = ctx.taxonomy()
    accepted = set(args.consent_version)
    pending_path = ctx.paths["manifest"].with_name("corrections_pending.jsonl")
    dest_dir = ctx.paths["raw_dir"] / "user_corrections"
    dest_dir.mkdir(parents=True, exist_ok=True)
    staged, rejected = [], 0
    for bundle_path in sorted(Path(args.bundle_dir).glob("*.json")):
        bundle: dict[str, Any] = json.loads(bundle_path.read_text(encoding="utf-8"))
        image_path = bundle_path.with_suffix(".jpg")
        issues = validate_correction(bundle, taxonomy, accepted)
        if image_path.exists() and sha256_file(image_path) != bundle.get("image_sha256"):
            issues.append(Issue("error", "correction_hash", "image does not match image_sha256", bundle_path.name))
        if not image_path.exists():
            issues.append(Issue("error", "correction_no_image", f"{image_path.name} missing", bundle_path.name))
        if errors(issues):
            _print_issues(issues)
            rejected += 1
            continue
        dest = dest_dir / f"{bundle['scan_id']}.jpg"
        strip_metadata(str(image_path), str(dest))
        record = correction_to_record(bundle, str(dest.relative_to(ctx.paths["raw_dir"])))
        record.sha256 = sha256_file(dest)
        record.extra["regions"] = bundle["regions"]
        record.extra["image_size"] = [bundle["image_width"], bundle["image_height"]]
        staged.append(record)
    append_records(pending_path, staged)
    print(f"staged {len(staged)} corrections as unreviewed in {pending_path}; rejected {rejected}")
    print("Nothing enters training until a reviewer approves it with `food-rec promote-corrections`.")
    return 0


def cmd_promote_corrections(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.corrections import ReviewDecision, promote_reviewed

    pending_path = ctx.paths["manifest"].with_name("corrections_pending.jsonl")
    pending, _ = load_manifest(pending_path)
    decisions = [ReviewDecision(**json.loads(line)) for line in Path(args.decisions).read_text().splitlines() if line.strip()]
    promoted, waiting = promote_reviewed(pending, decisions)
    dataset, _ = load_coco(ctx.paths["annotations"])
    names = ctx.taxonomy().by_name()
    next_image = max((i.id for i in dataset.images), default=0) + 1
    next_ann = max((a.id for a in dataset.annotations), default=0) + 1
    for record in promoted:
        width, height = record.extra.pop("image_size")
        dataset.images.append(CocoImage(next_image, record.file, int(width), int(height)))
        for region in record.extra.pop("regions"):
            dataset.annotations.append(CocoAnnotation(next_ann, next_image, names[region["confirmed_label"]].id,
                                                      tuple(float(v) for v in region["bbox"]),  # type: ignore[arg-type]
                                                      attributes={"uncertain": True} if region.get("uncertain") else {}))
            next_ann += 1
        next_image += 1
    save_coco(dataset, ctx.paths["annotations"])
    append_records(ctx.paths["manifest"], promoted)
    promoted_ids = {r.extra.get("scan_id") for r in promoted}
    decided = {d.scan_id for d in decisions if d.reviewer}
    write_manifest(pending_path, [r for r in pending if r.extra.get("scan_id") not in decided])
    print(f"promoted {len(promoted_ids)} reviewed corrections; {len(waiting)} still waiting for review")
    return 0


def _train(kind: str, ctx: Context, args: argparse.Namespace) -> int:
    from .licensing import LicenseError

    cfg = load_yaml(resolve(args.config or f"configs/{kind}.yaml", ctx.root))
    seed_everything(int(cfg.get("seed", ctx.seed)))
    if kind == "detection":
        from .detection.train import train
    else:
        from .classification.train import train  # type: ignore[assignment]
    try:
        train(cfg, args.dataset_version, ctx.root)
    except (LicenseError, FileNotFoundError, RuntimeError) as exc:
        print(exc)
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="food-rec", description=__doc__)
    parser.add_argument("--dataset-config", default="configs/dataset.yaml")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("check-taxonomy", help="validate configs/taxonomy.yaml").set_defaults(func=cmd_check_taxonomy)
    p = sub.add_parser("check-licenses", help="fail if a training config uses an asset that is not approved")
    p.add_argument("configs", nargs="*")
    p.set_defaults(func=cmd_check_licenses)

    p = sub.add_parser("import", help="copy owned/permitted photos into data/raw and record their rights")
    p.add_argument("--folder", required=True)
    p.add_argument("--source-id", required=True)
    p.add_argument("--group-id", help="photo session or meal id used to keep near-identical shots in one split")
    p.add_argument("--attribution")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("normalize", help="map a COCO export from Label Studio onto taxonomy ids")
    p.add_argument("--input", required=True)
    p.add_argument("--output")
    p.add_argument("--strip-prefix", default="")
    p.set_defaults(func=cmd_normalize)

    p = sub.add_parser("validate", help="validate annotations, files, rights, duplicates and balance")
    p.add_argument("--no-files", action="store_true", help="skip opening image files")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("split", help="leakage-safe train/val/test split by source group")
    p.add_argument("--force", action="store_true", help="split even when validation has errors (not for training)")
    p.set_defaults(func=cmd_split)

    sub.add_parser("report", help="write reports/dataset_report.md").set_defaults(func=cmd_report)

    p = sub.add_parser("freeze", help="record an immutable dataset version")
    p.add_argument("--version", required=True)
    p.add_argument("--notes")
    p.set_defaults(func=cmd_freeze)

    p = sub.add_parser("labelstudio-config", help="generate the Label Studio labeling config from the taxonomy")
    p.add_argument("--output", default="configs/annotation/label_studio.xml")
    p.set_defaults(func=cmd_labelstudio_config)

    p = sub.add_parser("ingest-corrections", help="stage opt-in user corrections as unreviewed")
    p.add_argument("--bundle-dir", required=True)
    p.add_argument("--consent-version", action="append", required=True)
    p.set_defaults(func=cmd_ingest_corrections)

    p = sub.add_parser("promote-corrections", help="move reviewer-approved corrections into training data")
    p.add_argument("--decisions", required=True, help="JSONL of {scan_id, decision, reviewer, reviewed_at}")
    p.set_defaults(func=cmd_promote_corrections)

    for kind in ("detection", "classification"):
        p = sub.add_parser(f"train-{'detector' if kind == 'detection' else 'classifier'}",
                           help=f"train the {kind} model (preflight checks only until phase 4)")
        p.add_argument("--dataset-version", required=True)
        p.add_argument("--config")
        p.set_defaults(func=lambda c, a, k=kind: _train(k, c, a))
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    ctx = Context(args.dataset_config)
    return int(args.func(ctx, args))


if __name__ == "__main__":
    sys.exit(main())
