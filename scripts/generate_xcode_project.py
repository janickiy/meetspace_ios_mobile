#!/usr/bin/env python3
"""Dependency-free, deterministic Xcode project generator. Run --check in CI."""
from pathlib import Path
import argparse
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "MeetSpace.xcodeproj"
objects = {}


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **values):
    key = uid(object_name)
    assert key not in objects, object_name
    objects[key] = {"isa": isa, **values}
    return key


def encode(value, level=0):
    tab = "\t" * level
    if isinstance(value, dict):
        return "{\n" + "".join(f"{tab}\t{json.dumps(k)} = {encode(v, level + 1)};\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{tab}\t{encode(v, level + 1)},\n" for v in value) + tab + ")"
    return json.dumps(value, ensure_ascii=False)


def configs(name, settings):
    ids = []
    for mode in ("Debug", "Release"):
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                      DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
        if mode == "Debug":
            values.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) DEBUG")
        ids.append(add(name + mode, "XCBuildConfiguration", name=mode, buildSettings=values))
    return add(name + "Configs", "XCConfigurationList", buildConfigurations=ids,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def make_project():
    project_id = uid("project")
    package = add("package", "XCLocalSwiftPackageReference", relativePath="Packages/MeetSpaceKit")
    product_files = []
    source_groups = []
    targets = []
    target_names = [("MeetSpace", "App", "application", "app", ["MeetSpaceFeatures", "MeetSpaceCore", "MeetSpaceAPI"]),
                    ("MeetSpaceTests", "Tests/MeetSpaceTests", "bundle.unit-test", "xctest", ["MeetSpaceCore", "MeetSpaceStorage"]),
                    ("MeetSpaceUITests", "Tests/MeetSpaceUITests", "bundle.ui-testing", "xctest", [])]
    for name, directory, kind, extension, modules in target_names:
        file_ids, sources, resources, frameworks, dependencies, packages = [], [], [], [], [], []
        for path in sorted((ROOT / directory).iterdir()):
            if not path.is_file():
                continue
            relative = path.relative_to(ROOT).as_posix()
            file_type = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcprivacy": "text.xml"}[path.suffix]
            reference = add(relative, "PBXFileReference", lastKnownFileType=file_type, path=path.name, sourceTree="<group>")
            file_ids.append(reference)
            if path.suffix != ".plist":
                build = add(relative + "Build", "PBXBuildFile", fileRef=reference)
                (sources if path.suffix == ".swift" else resources).append(build)
        source_groups.append(add(name + "Group", "PBXGroup", children=file_ids, path=directory, sourceTree="<group>"))
        for module in modules:
            product = add(name + module, "XCSwiftPackageProductDependency", package=package, productName=module)
            packages.append(product)
            frameworks.append(add(name + module + "Link", "PBXBuildFile", productRef=product))
        if name != "MeetSpace":
            proxy = add(name + "Proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
                        remoteGlobalIDString=uid("MeetSpaceTarget"), remoteInfo="MeetSpace")
            dependencies.append(add(name + "Dependency", "PBXTargetDependency", target=uid("MeetSpaceTarget"), targetProxy=proxy))
        product = add(name + "Product", "PBXFileReference", explicitFileType="wrapper.application" if extension == "app" else "wrapper.cfbundle",
                      includeInIndex=0, path=f"{name}.{extension}", sourceTree="BUILT_PRODUCTS_DIR")
        product_files.append(product)
        settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.meetspace.ios" + ("" if name == "MeetSpace" else "." + name),
                        CODE_SIGN_STYLE="Automatic", GENERATE_INFOPLIST_FILE="YES", TARGETED_DEVICE_FAMILY="1,2",
                        SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO")
        if name == "MeetSpace":
            settings.update(INFOPLIST_FILE="App/Info.plist", GENERATE_INFOPLIST_FILE="NO", MARKETING_VERSION="0.2.0",
                            CURRENT_PROJECT_VERSION="1", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
        elif name == "MeetSpaceTests":
            settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/MeetSpace.app/MeetSpace",
                            BUNDLE_LOADER="$(TEST_HOST)", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])
        else:
            settings.update(TEST_TARGET_NAME="MeetSpace", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])
        phases = [add(name + "Sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0),
                  add(name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=frameworks, runOnlyForDeploymentPostprocessing=0),
                  add(name + "Resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)]
        targets.append(add(name + "Target", "PBXNativeTarget", buildConfigurationList=configs(name, settings), buildPhases=phases,
                           buildRules=[], dependencies=dependencies, name=name, packageProductDependencies=packages,
                           productName=name, productReference=product, productType="com.apple.product-type." + kind))
    products = add("products", "PBXGroup", children=product_files, name="Products", sourceTree="<group>")
    package_group = add("packageGroup", "PBXFileReference", lastKnownFileType="wrapper", path="Packages/MeetSpaceKit", sourceTree="<group>")
    group = add("mainGroup", "PBXGroup", children=source_groups + [package_group, products], sourceTree="<group>")
    base_settings = dict(IPHONEOS_DEPLOYMENT_TARGET="18.0", SDKROOT="iphoneos", SWIFT_VERSION="6.0",
                         SWIFT_STRICT_CONCURRENCY="complete", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES",
                         GCC_C_LANGUAGE_STANDARD="gnu17", SWIFT_EMIT_LOC_STRINGS="YES")
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600",
                                           "TargetAttributes": {uid("MeetSpaceTestsTarget"): {"TestTargetID": uid("MeetSpaceTarget")}, uid("MeetSpaceUITestsTarget"): {"TestTargetID": uid("MeetSpaceTarget")}}},
        buildConfigurationList=configs("Project", base_settings), compatibilityVersion="Xcode 15.0", developmentRegion="ru",
        hasScannedForEncodings=0, knownRegions=["ru", "Base"], mainGroup=group, productRefGroup=products,
        projectDirPath="", projectRoot="", packageReferences=[package], targets=targets)
    return "// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=60, objects=objects, rootObject=project_id)) + "\n"


def reference(parent, name):
    ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=uid(name + "Target"),
                  BuildableName=name + (".app" if name == "MeetSpace" else ".xctest"), BlueprintName=name, ReferencedContainer="container:MeetSpace.xcodeproj")


def scheme(configuration):
    root = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.7")
    build = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    reference(entry, "MeetSpace")
    test = ET.SubElement(root, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                         selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    testables = ET.SubElement(test, "Testables")
    for name in ("MeetSpaceTests", "MeetSpaceUITests"):
        item = ET.SubElement(testables, "TestableReference", skipped="NO", parallelizable="NO")
        reference(item, name)
    launch = ET.SubElement(root, "LaunchAction", buildConfiguration=configuration, selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), "MeetSpace")
    profile = ET.SubElement(root, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "MeetSpace")
    ET.SubElement(root, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(root, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(root)
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode") + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = {PROJECT / "project.pbxproj": make_project(),
               PROJECT / "project.xcworkspace/contents.xcworkspacedata": '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"/></Workspace>\n'}
    for config in ("Debug", "Release"):
        outputs[PROJECT / f"xcshareddata/xcschemes/MeetSpace-{config}.xcscheme"] = scheme(config)
    for path, contents in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != contents:
                raise SystemExit(f"Outdated generated file: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
    print("PASS: Xcode project " + ("is reproducible" if args.check else "generated"))


if __name__ == "__main__":
    main()
