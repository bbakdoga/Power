"""`food-rec` command line interface. Run `food-rec --help` for the list of commands."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .config import load_yaml, project_root, resolve, seed_everything
from .dataset.coco import CocoAnnotation, CocoImage, load_coco, merge_datasets, normalize_categories, save_coco
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
    if args.merge and out.exists():
        existing, _ = load_coco(out)
        normalized, added, replaced = merge_datasets(existing, normalized)
        print(f"merged: {added} new images, {replaced} re-annotated")
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


def cmd_exclude_images(ctx: Context, args: argparse.Namespace) -> int:
    """Remove images whose validation errors cannot be fixed by hand (e.g. source boxes outside the photo).

    The whole image goes, not just the bad box: a kept image with a missing box
    would teach the detector that the food there is background. Every removal is
    logged with its reason in data/manifests/excluded.jsonl so it can be reported.
    """
    codes = set(args.code)
    _, _, records, result = _validate(ctx, not args.no_files)
    reasons: dict[str, list[str]] = {}
    for issue in result.issues:
        if issue.severity == "error" and issue.code in codes and issue.image:
            reasons.setdefault(issue.image, []).append(f"{issue.code}: {issue.message}")
    other = [i for i in errors(result.issues) if i.code not in codes]
    if not reasons:
        print(f"no images with {', '.join(sorted(codes))}; nothing to do")
    else:
        dataset, _ = load_coco(ctx.paths["annotations"])
        drop_ids = {img.id for img in dataset.images if img.file_name in reasons}
        boxes_before = len(dataset.annotations)
        dataset.images = [img for img in dataset.images if img.id not in drop_ids]
        dataset.annotations = [a for a in dataset.annotations if a.image_id not in drop_ids]
        log = ctx.paths["manifest"].with_name("excluded.jsonl")
        if args.dry_run:
            print("dry run: nothing written")
        else:
            with open(log, "a", encoding="utf-8") as handle:
                for file_name in sorted(reasons):
                    handle.write(json.dumps({"file": file_name, "reasons": reasons[file_name]}) + "\n")
            save_coco(dataset, ctx.paths["annotations"])
            write_manifest(ctx.paths["manifest"], [r for r in records if r.file not in reasons])
        print(f"excluded {len(drop_ids)} images ({boxes_before - len(dataset.annotations)} boxes); "
              f"{len(dataset.images)} images and {len(dataset.annotations)} boxes remain; reasons -> {log}")
    if other:
        print(f"{len(other)} other errors remain; run `food-rec validate`")
    return 1 if other else 0


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


def _require_source(ctx: Context, source_id: str, license_name: str) -> int | None:
    source = ctx.sources().get(source_id)
    if source is None:
        print(f"add a `{source_id}` entry to data/manifests/sources.yaml first (see sources.example.yaml)")
        return 1
    if source.license != license_name or not source.commercial_use:
        print(f"sources.yaml entry {source_id} must have license {license_name} and commercial_use: true")
        return 1
    return None


def _commit_import(ctx: Context, records, dataset, stats) -> None:  # type: ignore[no-untyped-def]
    append_records(ctx.paths["manifest"], records)
    out = ctx.paths["annotations"]
    if out.exists():
        existing, _ = load_coco(out)
        dataset, _, _ = merge_datasets(existing, dataset)
    save_coco(dataset, out)
    for line in stats.lines():
        print(f"  {line}")


def cmd_propose_mapping(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.external import myfoodrepo

    cfg = load_yaml(resolve("configs/external/myfoodrepo.yaml", ctx.root))
    folders = myfoodrepo.find_splits([Path(p) for p in args.paths], resolve("data/external", ctx.root))
    proposal = myfoodrepo.propose_mapping(myfoodrepo.category_counts(folders), cfg, ctx.taxonomy())
    out = resolve(args.output or f"configs/external/myfoodrepo_mapping_{args.release}.yaml", ctx.root)
    myfoodrepo.write_mapping(proposal, out, f"# MyFoodRepo {args.release} category -> our class. "
                             "Proposed by `food-rec propose-mapping`.\n"
                             "# Targets: a taxonomy class, unknown_food, or drop (not boxed).")
    summary: dict[str, int] = {}
    for entry in proposal.values():
        summary[entry["class"]] = summary.get(entry["class"], 0) + 1
    covered = sorted(k for k in summary if k not in ("drop", ctx.taxonomy().unknown.name))
    missing = sorted(set(ctx.taxonomy().classifier_labels()) - set(covered))
    print(f"wrote {out}: {len(proposal)} categories -> {len(covered)} of our classes, "
          f"{summary.get(ctx.taxonomy().unknown.name, 0)} unknown_food, {summary.get('drop', 0)} dropped")
    if missing:
        print(f"no MyFoodRepo category for: {', '.join(missing)}")
    print("Check every line, fix any wrong ones, set `reviewed: true`, then run `food-rec import-myfoodrepo`.")
    return 0


def cmd_import_myfoodrepo(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.external import myfoodrepo

    release = load_yaml(resolve("configs/external/myfoodrepo.yaml", ctx.root))["releases"][args.release]
    problems = check_assets([release["asset"]], load_assets(resolve("licenses/assets.yaml", ctx.root)))
    if problems:
        print("Import refused by the licence register:\n  " + "\n  ".join(problems))
        return 1
    if (failed := _require_source(ctx, release["source_id"], release["license"])) is not None:
        return failed
    taxonomy = ctx.taxonomy()
    mapping_path = args.mapping or f"configs/external/myfoodrepo_mapping_{args.release}.yaml"
    try:
        mapping = myfoodrepo.load_reviewed_mapping(resolve(mapping_path, ctx.root), taxonomy)
    except ValueError as exc:
        print(exc)
        return 1
    folders = myfoodrepo.find_splits([Path(p) for p in args.paths], resolve("data/external", ctx.root))
    existing, _ = ctx.records()
    records, dataset, stats = myfoodrepo.import_splits(
        folders, mapping, taxonomy, ctx.paths["raw_dir"], source_id=release["source_id"],
        attribution=" ".join(release["attribution"].split()), known_hashes={r.sha256 for r in existing})
    _commit_import(ctx, records, dataset, stats)
    return 0


def cmd_select_openimages(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.external import openimages

    cfg = load_yaml(resolve("configs/external/open_images.yaml", ctx.root))
    class_map = openimages.build_class_map(cfg, Path(args.classes_csv), ctx.taxonomy())
    selection = openimages.select_images(
        class_map, boxes_csv=Path(args.boxes_csv), metadata_csv=Path(args.metadata_csv),
        labels_csv=Path(args.labels_csv) if args.labels_csv else None, max_per_class=args.max_per_class,
        skip_depictions=bool(cfg.get("skip_depictions", True)))
    sel_path = resolve(f"data/external/openimages_{args.split}_selection.json", ctx.root)
    openimages.save_selection(selection, sel_path)
    ids_path = sel_path.with_name(f"openimages_{args.split}_ids.txt")
    ids_path.write_text("\n".join(selection.image_ids()) + "\n", encoding="utf-8")
    print(f"{len(selection.boxes)} images with boxes, {len(selection.to_annotate)} to annotate; "
          f"skipped {selection.skipped_license} (licence) and {selection.skipped_rotation} (rotated)")
    print(f"ids -> {ids_path}\nnext: python scripts/download_openimages.py {ids_path} data/external/openimages_images "
          f"--split {args.split}")
    return 0


def cmd_import_openimages(ctx: Context, args: argparse.Namespace) -> int:
    from .dataset.external import openimages

    cfg = load_yaml(resolve("configs/external/open_images.yaml", ctx.root))
    if (failed := _require_source(ctx, cfg["source_id"], "CC-BY-2.0")) is not None:
        return failed
    taxonomy = ctx.taxonomy()
    class_map = openimages.build_class_map(cfg, Path(args.classes_csv), taxonomy)
    selection = openimages.load_selection(resolve(f"data/external/openimages_{args.split}_selection.json", ctx.root))
    existing, _ = ctx.records()
    records, dataset, to_annotate, stats = openimages.import_images(
        selection, class_map, taxonomy, Path(args.images_dir), ctx.paths["raw_dir"],
        source_id=cfg["source_id"], known_hashes={r.sha256 for r in existing})
    _commit_import(ctx, records, dataset, stats)
    if to_annotate:
        todo = ctx.paths["annotations"].with_name("to_annotate_openimages.tsv")
        with open(todo, "a", encoding="utf-8") as handle:
            handle.writelines(f"{file}\t{label}\n" for file, label in to_annotate)
        print(f"  {len(to_annotate)} photos need boxes drawn: listed in {todo}")
    return 0


def cmd_attributions(ctx: Context, args: argparse.Namespace) -> int:
    records, _ = ctx.records()
    out = resolve(args.output, ctx.root)
    out.parent.mkdir(parents=True, exist_ok=True)
    rows = sorted({(r.license, r.attribution) for r in records if r.attribution})
    out.write_text("license\tattribution\n" + "".join(f"{lic}\t{text}\n" for lic, text in rows), encoding="utf-8")
    print(f"wrote {out}: {len(rows)} attributions")
    return 0


def _train(kind: str, ctx: Context, args: argparse.Namespace) -> int:
    from .licensing import LicenseError

    cfg = load_yaml(resolve(args.config or f"configs/{kind}.yaml", ctx.root))
    if args.seed is not None:
        cfg["seed"] = args.seed            # repeat an experiment with another seed
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


def cmd_evaluate(ctx: Context, args: argparse.Namespace) -> int:
    from .evaluation.run_eval import evaluate_run, headline
    from .licensing import LicenseError

    lines, failed = [], 0
    for run in args.runs:
        try:
            result = evaluate_run(resolve(run, ctx.root), ctx.root, split=args.split, checkpoint=args.checkpoint)
        except (LicenseError, FileNotFoundError, RuntimeError, ValueError) as exc:
            print(f"{run}: {exc}")
            failed += 1
            continue
        lines.append(headline(result))
        print(f"wrote {Path(result['run']) / f'eval_{args.split}.json'}")
    print("\n".join(["", *lines]))
    return 1 if failed else 0


def cmd_compare(ctx: Context, args: argparse.Namespace) -> int:
    from .evaluation.run_eval import compare

    files = sorted((ctx.root / "models/runs").glob(f"*/*/eval_{args.split}.json"))
    results = [json.loads(f.read_text(encoding="utf-8")) for f in files]
    if args.dataset_version:
        results = [r for r in results if r["dataset_version"] == args.dataset_version]
    if not results:
        print(f"no eval_{args.split}.json files yet; run `food-rec evaluate <run folders>` first")
        return 1
    print("\n".join(compare(results)))
    return 0


def cmd_select_openimages_pretrain(ctx: Context, args: argparse.Namespace) -> int:
    from .licensing import require_approved
    from .training.openimages_pretrain import select_pretrain

    require_approved({"assets": ["open_images_v7", "openimages_pretrain_own"]},
                     load_assets(resolve("licenses/assets.yaml", ctx.root)))
    out = resolve(args.out, ctx.root)
    stats = select_pretrain(boxes_csv=Path(args.boxes_csv), metadata_csv=Path(args.metadata_csv),
                            classes_csv=Path(args.classes_csv), out_dir=out, max_images=args.max_images, seed=ctx.seed)
    print(f"selected {stats['images']} images ({stats['val']} for validation) over {stats['classes']} classes; "
          f"skipped {stats['license']} for licence, {stats['rotation']} rotated")
    print(f"next: python scripts/download_openimages.py {out / 'ids.txt'} {out / 'images'} --max-side 640")
    return 0


def _pretrain(kind: str, ctx: Context, args: argparse.Namespace) -> int:
    from .licensing import LicenseError
    from .training.pretrain_runs import pretrain_classifier, pretrain_detector

    cfg = load_yaml(resolve(args.config or f"configs/pretrain/{kind}_openimages.yaml", ctx.root))
    try:
        if kind == "detection":
            pretrain_detector(cfg, ctx.root, resume=Path(args.resume) if args.resume else None)
        else:
            pretrain_classifier(cfg, ctx.root)
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
    p.add_argument("--merge", action="store_true",
                   help="merge into the existing annotations (keeps imported datasets) instead of replacing the file")
    p.set_defaults(func=cmd_normalize)

    p = sub.add_parser("validate", help="validate annotations, files, rights, duplicates and balance")
    p.add_argument("--no-files", action="store_true", help="skip opening image files")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("split", help="leakage-safe train/val/test split by source group")
    p.add_argument("--force", action="store_true", help="split even when validation has errors (not for training)")
    p.set_defaults(func=cmd_split)

    p = sub.add_parser("exclude-images", help="drop images with unfixable validation errors, logging why")
    p.add_argument("--code", action="append", required=True, help="error code to exclude, e.g. bbox_out_of_bounds")
    p.add_argument("--no-files", action="store_true", help="skip opening image files")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_exclude_images)

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


    p = sub.add_parser("propose-mapping", help="propose MyFoodRepo category -> taxonomy mapping for review")
    p.add_argument("paths", nargs="+", help="downloaded train/val .tar.gz files or extracted folders")
    p.add_argument("--release", default="v0.4", choices=["v0.4", "v2.0"])
    p.add_argument("--output", help="default: configs/external/myfoodrepo_mapping_<release>.yaml")
    p.set_defaults(func=cmd_propose_mapping)

    p = sub.add_parser("import-myfoodrepo", help="import MyFoodRepo (AIcrowd or Kaggle mirror) with a reviewed mapping")
    p.add_argument("paths", nargs="+")
    p.add_argument("--release", default="v0.4", choices=["v0.4", "v2.0"])
    p.add_argument("--mapping", help="default: configs/external/myfoodrepo_mapping_<release>.yaml")
    p.set_defaults(func=cmd_import_myfoodrepo)

    p = sub.add_parser("select-openimages", help="choose CC BY 2.0 Open Images photos of our foods to download")
    p.add_argument("--classes-csv", required=True)
    p.add_argument("--boxes-csv", required=True)
    p.add_argument("--metadata-csv", required=True)
    p.add_argument("--labels-csv", help="human image-level labels, for foods without boxes")
    p.add_argument("--split", default="train")
    p.add_argument("--max-per-class", type=int, default=1500)
    p.set_defaults(func=cmd_select_openimages)

    p = sub.add_parser("import-openimages", help="import downloaded Open Images photos and boxes")
    p.add_argument("--classes-csv", required=True)
    p.add_argument("--images-dir", required=True)
    p.add_argument("--split", default="train")
    p.set_defaults(func=cmd_import_openimages)

    p = sub.add_parser("attributions", help="write the CC BY attribution list for imported photos")
    p.add_argument("--output", default="reports/attributions.tsv")
    p.set_defaults(func=cmd_attributions)

    p = sub.add_parser("select-openimages-pretrain", help="choose general CC BY 2.0 Open Images photos for pretraining")
    p.add_argument("--classes-csv", required=True, help="oidv7-class-descriptions-boxable.csv")
    p.add_argument("--boxes-csv", required=True, help="oidv6-train-annotations-bbox.csv")
    p.add_argument("--metadata-csv", required=True, help="train-images-boxable-with-rotation.csv")
    p.add_argument("--max-images", type=int, default=200_000)
    p.add_argument("--out", default="data/pretrain/openimages")
    p.set_defaults(func=cmd_select_openimages_pretrain)

    for kind in ("detection", "classification"):
        name = "detector" if kind == "detection" else "classifier"
        p = sub.add_parser(f"pretrain-{name}", help=f"pretrain the {name} on Open Images (produces openimages_pretrain_own)")
        p.add_argument("--config")
        if kind == "detection":
            p.add_argument("--resume", help="run folder to continue after a job hit its time limit")
        p.set_defaults(func=lambda c, a, k=kind: _pretrain(k, c, a))

    for kind in ("detection", "classification"):
        p = sub.add_parser(f"train-{'detector' if kind == 'detection' else 'classifier'}",
                           help=f"train the {kind} model on a frozen dataset version")
        p.add_argument("--dataset-version", required=True)
        p.add_argument("--config")
        p.add_argument("--seed", type=int, help="override the config's seed (run folders are named by seed)")
        p.set_defaults(func=lambda c, a, k=kind: _train(k, c, a))

    p = sub.add_parser("evaluate", help="score finished runs on the held-out test split (writes eval_<split>.json)")
    p.add_argument("runs", nargs="+", help="run folders, e.g. models/runs/detection-scratch/v0.1.0-*")
    p.add_argument("--split", default="test", choices=["test", "val"])
    p.add_argument("--checkpoint", default="best.pt")
    p.set_defaults(func=cmd_evaluate)

    p = sub.add_parser("compare", help="mean ± std over seeds of every evaluated run, one line per experiment")
    p.add_argument("--split", default="test", choices=["test", "val"])
    p.add_argument("--dataset-version")
    p.set_defaults(func=cmd_compare)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    ctx = Context(args.dataset_config)
    return int(args.func(ctx, args))


if __name__ == "__main__":
    sys.exit(main())
