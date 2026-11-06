#!/usr/bin/env python3
"""Regenerates Power.xcodeproj/project.pbxproj from the files in Power/.

The project uses the Xcode 14 file format (objectVersion 56) with explicit file
references, so it opens in Xcode 15 and newer. Run this after adding, removing
or renaming a source file outside Xcode:

    python3 scripts/generate_xcodeproj.py

Files added from inside Xcode are written to the project by Xcode itself.
Build settings are kept from the existing project file.
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "Power"
PBXPROJ = os.path.join(ROOT, f"{APP}.xcodeproj", "project.pbxproj")

SOURCE_EXT = {".swift": "sourcecode.swift"}
FOLDER_RESOURCES = {".xcassets": "folder.assetcatalog"}


def oid(*parts: str) -> str:
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def quote(name: str) -> str:
    return name if re.fullmatch(r"[A-Za-z0-9_./]+", name) else '"' + name.replace('"', '\\"') + '"'


def scan(rel_dir: str):
    """Returns (children ids, groups, file refs, sources, resources) for a folder."""
    groups, refs, sources, resources = [], [], [], []
    children = []
    abs_dir = os.path.join(ROOT, rel_dir)
    for name in sorted(os.listdir(abs_dir), key=lambda n: (not os.path.isdir(os.path.join(abs_dir, n)) or n.endswith(".xcassets"), n.lower())):
        if name.startswith("."):
            continue
        rel = f"{rel_dir}/{name}"
        ext = os.path.splitext(name)[1]
        if ext in FOLDER_RESOURCES:
            ref = oid("ref", rel)
            refs.append((ref, name, FOLDER_RESOURCES[ext]))
            resources.append((oid("build", rel), ref, name))
            children.append((ref, name))
        elif os.path.isdir(os.path.join(ROOT, rel)):
            sub_children, g, r, s, res = scan(rel)
            gid = oid("group", rel)
            groups.append((gid, name, sub_children))
            groups.extend(g)
            refs.extend(r)
            sources.extend(s)
            resources.extend(res)
            children.append((gid, name))
        elif ext in SOURCE_EXT:
            ref = oid("ref", rel)
            refs.append((ref, name, SOURCE_EXT[ext]))
            sources.append((oid("build", rel), ref, name))
            children.append((ref, name))
    return children, groups, refs, sources, resources


def main() -> None:
    old = open(PBXPROJ).read()
    configs = re.search(r"/\* Begin XCBuildConfiguration section \*/.*?/\* End XCConfigurationList section \*/", old, re.S)
    if not configs:
        sys.exit("Could not find build configurations in the existing project file.")
    configs = configs.group(0)
    project_list = re.search(r"(\w{24}) /\* Build configuration list for PBXProject", configs).group(1)
    target_list = re.search(r"(\w{24}) /\* Build configuration list for PBXNativeTarget", configs).group(1)

    children, groups, refs, sources, resources = scan(APP)
    app_group = oid("group", APP)
    main_group = oid("main-group")
    products_group = oid("products-group")
    product = oid("product", APP)
    target = oid("target", APP)
    project = oid("project", APP)
    src_phase, fw_phase, res_phase = oid("phase", "sources"), oid("phase", "frameworks"), oid("phase", "resources")

    out = []
    w = out.append
    w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")

    w("/* Begin PBXBuildFile section */\n")
    for bid, ref, name in sorted(sources + resources):
        phase = "Sources" if name.endswith(".swift") else "Resources"
        w(f"\t\t{bid} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
    w("/* End PBXBuildFile section */\n\n")

    w("/* Begin PBXFileReference section */\n")
    w(f"\t\t{product} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    for ref, name, ftype in sorted(refs):
        w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {quote(name)}; sourceTree = \"<group>\"; }};\n")
    w("/* End PBXFileReference section */\n\n")

    w(f"/* Begin PBXFrameworksBuildPhase section */\n\t\t{fw_phase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXFrameworksBuildPhase section */\n\n")

    def group(gid, name, kids, path=True):
        w(f"\t\t{gid}" + (f" /* {name} */" if name else "") + " = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
        for cid, cname in kids:
            w(f"\t\t\t\t{cid} /* {cname} */,\n")
        w("\t\t\t);\n")
        if name and path:
            w(f"\t\t\tpath = {quote(name)};\n")
        elif name:
            w(f"\t\t\tname = {quote(name)};\n")
        w("\t\t\tsourceTree = \"<group>\";\n\t\t};\n")

    w("/* Begin PBXGroup section */\n")
    all_groups = [(main_group, "", [(app_group, APP), (products_group, "Products")]),
                  (app_group, APP, children),
                  (products_group, "Products", [(product, f"{APP}.app")])] + groups
    for gid, name, kids in sorted(all_groups):
        group(gid, name, kids, path=(gid != products_group))
    w("/* End PBXGroup section */\n\n")

    w(f"""/* Begin PBXNativeTarget section */
\t\t{target} /* {APP} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {target_list} /* Build configuration list for PBXNativeTarget "{APP}" */;
\t\t\tbuildPhases = (
\t\t\t\t{src_phase} /* Sources */,
\t\t\t\t{fw_phase} /* Frameworks */,
\t\t\t\t{res_phase} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {APP};
\t\t\tproductName = {APP};
\t\t\tproductReference = {product} /* {APP}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{project} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject "{APP}" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group};
\t\t\tproductRefGroup = {products_group} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target} /* {APP} */,
\t\t\t);
\t\t}};
/* End PBXProject section */

""")

    def phase(pid, isa, label, items):
        w(f"\t\t{pid} /* {label} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
        for bid, _, name in sorted(items, key=lambda i: i[2]):
            w(f"\t\t\t\t{bid} /* {name} in {label} */,\n")
        w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")

    w("/* Begin PBXResourcesBuildPhase section */\n")
    phase(res_phase, "PBXResourcesBuildPhase", "Resources", resources)
    w("/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */\n")
    phase(src_phase, "PBXSourcesBuildPhase", "Sources", sources)
    w("/* End PBXSourcesBuildPhase section */\n\n")

    w(configs + "\n")
    w(f"\t}};\n\trootObject = {project} /* Project object */;\n}}\n")
    open(PBXPROJ, "w").write("".join(out))
    print(f"Wrote {PBXPROJ}: {len(sources)} sources, {len(resources)} resources")


if __name__ == "__main__":
    main()
