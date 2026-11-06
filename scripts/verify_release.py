#!/usr/bin/env python3
"""Fail closed on packaging regressions; never uploads, signs, or reads private keys.

Source checks run without Xcode. --app/--archive validate an actual device Release
product, including Apple's SDK floor current on 2026-11-06. --require-signing also
checks distribution entitlements/profiles; success is not App Store approval.
"""
from pathlib import Path
import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
import subprocess
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SDK_FLOOR = 26
XCODE_FLOOR = 2600
checks = []


def check(name, condition, detail):
    checks.append({"check": name, "status": "PASS" if condition else "FAIL", "detail": detail})


def blocked(name, detail):
    checks.append({"check": name, "status": "BLOCKED", "detail": detail})


def read_plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def command(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, check=False)


def privacy(path, name):
    value = read_plist(path)
    check(name + ".tracking", value.get("NSPrivacyTracking") is False and
          not value.get("NSPrivacyTrackingDomains"), "No tracking or tracking domains declared")
    reasons = {v["NSPrivacyAccessedAPIType"]: v["NSPrivacyAccessedAPITypeReasons"]
               for v in value.get("NSPrivacyAccessedAPITypes", [])}
    check(name + ".timers", "35F9.1" in reasons.get("NSPrivacyAccessedAPICategorySystemBootTime", []),
          "Elapsed-time deadlines require SystemBootTime/35F9.1")
    if name.endswith("app"):
        check(name + ".preferences", "CA92.1" in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", []),
              "Private app preferences require UserDefaults/CA92.1")
        collected = {v["NSPrivacyCollectedDataType"]: v for v in value.get("NSPrivacyCollectedDataTypes", [])}
        for suffix in ("Name", "EmailAddress", "UserID", "DeviceID", "EmailsOrTextMessages", "PhotosorVideos", "AudioData", "OtherUserContent"):
            row = collected.get("NSPrivacyCollectedDataType" + suffix, {})
            check(name + ".data." + suffix, row.get("NSPrivacyCollectedDataTypeLinked") is True and
                  row.get("NSPrivacyCollectedDataTypeTracking") is False and
                  row.get("NSPrivacyCollectedDataTypePurposes") == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                  "Account-linked server data; app functionality only")


def source_checks():
    generated = command([sys.executable, "scripts/generate_xcode_project.py", "--check"])
    check("source.generated_project", generated.returncode == 0, "Project matches deterministic generator")
    project_result = command(["plutil", "-convert", "json", "-o", "-", "MeetSpace.xcodeproj/project.pbxproj"])
    if project_result.returncode:
        check("source.project_parse", False, "plutil could not parse project.pbxproj")
        return
    objects = json.loads(project_result.stdout)["objects"]
    target_settings = {}
    for obj in objects.values():
        if obj.get("isa") != "PBXNativeTarget":
            continue
        configs = objects[obj["buildConfigurationList"]]["buildConfigurations"]
        target_settings[obj["name"]] = next(objects[c]["buildSettings"] for c in configs if objects[c]["name"] == "Release")
    app, ext = target_settings["MeetSpace"], target_settings["BroadcastUpload"]
    project = next(obj for obj in objects.values() if obj.get("isa") == "PBXProject")
    project_configs = objects[project["buildConfigurationList"]]["buildConfigurations"]
    base = next(objects[c]["buildSettings"] for c in project_configs if objects[c]["name"] == "Release")
    check("source.platform", base.get("IPHONEOS_DEPLOYMENT_TARGET") == "18.0" and
          base.get("SWIFT_VERSION") == "6.0" and base.get("SWIFT_STRICT_CONCURRENCY") == "complete" and
          "DEBUG" not in base.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""),
          "iOS18 deployment, Swift6 complete concurrency, no project-level DEBUG")
    for name, settings in (("app", app), ("extension", ext)):
        check("source." + name + ".release", settings.get("SWIFT_OPTIMIZATION_LEVEL") == "-O" and
              "DEBUG" not in settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "") and
              settings.get("DEBUG_INFORMATION_FORMAT") == "dwarf-with-dsym",
              "Optimized Release, no DEBUG fixtures, dSYM generation enabled")
    check("source.apns", app.get("APS_ENVIRONMENT") == "production", "Release APNs environment is production")
    check("source.extension_safety", ext.get("APPLICATION_EXTENSION_API_ONLY") == "YES" and ext.get("SKIP_INSTALL") == "YES",
          "Extension-safe APIs and embedded archive product")
    check("source.versions", all(app.get(k) == ext.get(k) and app.get(k) for k in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION")),
          "App and extension marketing/build versions agree")
    scheme = ET.parse(ROOT / "MeetSpace.xcodeproj/xcshareddata/xcschemes/MeetSpace-Release.xcscheme")
    check("source.archive_scheme", scheme.find("ArchiveAction").get("buildConfiguration") == "Release", "Archive uses Release")
    info = read_plist(ROOT / "App/Info.plist")
    extension_info = read_plist(ROOT / "BroadcastExtension/Info.plist")
    check("source.ats", "NSAppTransportSecurity" not in info, "Default strict ATS; no exceptions")
    check("source.permissions", all(info.get(k) for k in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription")), "Camera/microphone purpose strings present")
    check("source.extension_id", info.get("MeetSpaceBroadcastExtension") == ext["PRODUCT_BUNDLE_IDENTIFIER"] and
          ext["PRODUCT_BUNDLE_IDENTIFIER"].startswith(app["PRODUCT_BUNDLE_IDENTIFIER"] + "."), "ReplayKit identifier matches embedded target")
    check("source.background_modes", set(info.get("UIBackgroundModes", [])) == {"audio", "voip"}, "Declared call background modes only")
    check("source.replaykit", extension_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.broadcast-services-upload",
          "ReplayKit upload extension point")
    app_ent = read_plist(ROOT / "App/MeetSpace.entitlements")
    ext_ent = read_plist(ROOT / "BroadcastExtension/MeetSpaceBroadcast.entitlements")
    check("source.entitlements", set(app_ent) == {"aps-environment", "com.apple.security.application-groups"} and
          set(ext_ent) == {"com.apple.security.application-groups"} and
          app_ent["com.apple.security.application-groups"] == ext_ent["com.apple.security.application-groups"] == ["$(BROADCAST_APP_GROUP)"],
          "Minimal entitlements with matching configurable App Group")
    privacy(ROOT / "App/PrivacyInfo.xcprivacy", "source.app")
    privacy(ROOT / "BroadcastExtension/PrivacyInfo.xcprivacy", "source.extension")
    catalogs = list((ROOT / "App").glob("*.xcassets/AppIcon.appiconset/Contents.json"))
    icon_ok = app.get("ASSETCATALOG_COMPILER_APPICON_NAME") == "AppIcon" and bool(catalogs)
    for path in catalogs:
        items = json.loads(path.read_text()).get("images", [])
        full_size = [path.parent / i.get("filename", "") for i in items if i.get("size") == "1024x1024"]
        icon_ok = icon_ok and bool(full_size)
        for icon in full_size:
            header = icon.read_bytes()[:26] if icon.is_file() else b""
            icon_ok = icon_ok and len(header) == 26 and header[:8] == b"\x89PNG\r\n\x1a\n" and \
                struct.unpack(">II", header[16:24]) == (1024, 1024) and header[25] in (0, 2)
    check("source.app_icon", icon_ok, "AppIcon catalog contains a 1024-pixel icon and is selected for compilation")
    pinned = json.loads((ROOT / "Packages/MeetSpaceKit/Package.resolved").read_text())["pins"]
    package = (ROOT / "Packages/MeetSpaceKit/Package.swift").read_text()
    check("source.dependency_pin", len(pinned) == 1 and pinned[0]["identity"] == "webrtc" and
          pinned[0]["state"] == {"revision": "3cc466ea040e5dcd1344697bf211dc4c079d1a0c", "version": "156.0.0"} and
          'exact: "156.0.0"' in package, "WebRTC source resolution is pinned to audited revision/version")
    audit = json.loads((ROOT / "docs/ios/evidence/stage04/webrtc-library.json").read_text())
    check("source.binary_checksum", audit.get("artifactSHA256") == "43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46",
          "Audited M156 binary checksum recorded; SPM verifies downloaded artifact")


def signed_entitlements(bundle):
    result = command(["codesign", "-d", "--entitlements", ":-", str(bundle)])
    if result.returncode:
        return None
    try:
        return plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        return None


def signing_checks(bundle, expected_group, expected_team=None):
    name = "signing." + bundle.suffix.removeprefix(".")
    verified = command(["codesign", "--verify", "--deep", "--strict", str(bundle)])
    ent = signed_entitlements(bundle)
    check(name + ".signature", verified.returncode == 0 and ent is not None, "Valid signed product and readable public entitlements")
    if not ent:
        return None
    team = ent.get("com.apple.developer.team-identifier")
    info = read_plist(bundle / "Info.plist")
    check(name + ".identity", isinstance(team, str) and bool(team) and (not expected_team or team == expected_team) and
          ent.get("application-identifier", "").endswith("." + info["CFBundleIdentifier"]), "Team and app identifier agree")
    check(name + ".entitlements", ent.get("get-task-allow") is False and
          ent.get("com.apple.security.application-groups") == [expected_group] and
          (bundle.suffix != ".app" or ent.get("aps-environment") == "production"), "Distribution debugging disabled; production APNs and matching App Group")
    profile = bundle / "embedded.mobileprovision"
    if not profile.is_file():
        check(name + ".profile", False, "Distribution provisioning profile is required")
        return team
    # Decode public metadata in memory only. Never print certificates, UDIDs, or profile contents.
    decoded = command(["security", "cms", "-D", "-i", str(profile)])
    if decoded.returncode:
        check(name + ".profile", False, "Cannot decode embedded provisioning profile")
        return team
    value = plistlib.loads(decoded.stdout)
    allowed = value.get("Entitlements", {})
    expiry = value.get("ExpirationDate", dt.datetime.min)
    check(name + ".profile", expiry > dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) and
          team in value.get("TeamIdentifier", []) and not value.get("ProvisionedDevices") and
          not value.get("ProvisionsAllDevices") and allowed.get("get-task-allow") is False and
          allowed.get("application-identifier") == ent.get("application-identifier") and
          expected_group in allowed.get("com.apple.security.application-groups", []) and
          (bundle.suffix != ".app" or allowed.get("aps-environment") == "production"),
          "Unexpired App Store profile matches identity, capabilities and distribution method")
    return team


def product_checks(bundle, require_signing):
    info = read_plist(bundle / "Info.plist")
    metadata = {k: info.get(k) for k in ("CFBundleShortVersionString", "CFBundleVersion", "DTXcode", "DTXcodeBuild", "DTSDKName", "DTPlatformName", "MinimumOSVersion")}
    check("product.device_sdk", info.get("DTPlatformName") == "iphoneos" and
          int(info.get("DTXcode", 0)) >= XCODE_FLOOR and
          bool(re.fullmatch(r"iphoneos(\d+)(?:\.\d+)*", info.get("DTSDKName", ""))) and
          int(re.search(r"\d+", info["DTSDKName"])[0]) >= SDK_FLOOR,
          "Actual device product uses Xcode26+/iOS26+ SDK (Apple requirement since 2026-04-28)")
    check("product.minimum_os", tuple(map(int, info.get("MinimumOSVersion", "0").split("."))) >= (18,), "iOS18+ deployment target")
    check("product.identity", "$" not in info["CFBundleIdentifier"] and info.get("CFBundlePackageType") == "APPL", "Resolved application bundle identity")
    check("product.app_icon", (bundle / "Assets.car").is_file() and
          info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Compiled asset catalog and primary icon metadata")
    privacy(bundle / "PrivacyInfo.xcprivacy", "product.app")
    extensions = list((bundle / "PlugIns").glob("*.appex"))
    check("product.extension_count", len(extensions) == 1, "Exactly one ReplayKit extension embedded")
    if len(extensions) != 1:
        return metadata
    ext = extensions[0]
    ext_info = read_plist(ext / "Info.plist")
    group = info.get("MeetSpaceBroadcastAppGroup")
    check("product.extension_metadata", ext_info.get("CFBundleIdentifier") == info.get("MeetSpaceBroadcastExtension") and
          ext_info.get("MeetSpaceBroadcastAppGroup") == group and isinstance(group, str) and group.startswith("group.") and
          "$" not in group and all(ext_info.get(k) == info.get(k) for k in ("CFBundleShortVersionString", "CFBundleVersion")),
          "Compiled app/extension identifiers, App Group and versions agree")
    check("product.extension_sdk", all(ext_info.get(k) == info.get(k) for k in ("DTXcode", "DTSDKName", "DTPlatformName", "MinimumOSVersion")),
          "Extension and app use the same Xcode, device SDK and deployment target")
    privacy(ext / "PrivacyInfo.xcprivacy", "product.extension")
    framework = bundle / "Frameworks/WebRTC.framework"
    check("product.webrtc", (framework / "WebRTC").is_file() and (framework / "PrivacyInfo.xcprivacy").is_file(), "Native WebRTC binary and its own privacy manifest embedded")
    for filename in ("WebRTC-LICENSE.txt", "WebRTC-PATENTS.txt", "WebRTC-THIRD-PARTY-NOTICES.txt", "WebRTC-Distribution-LICENSE.txt", "Inter-OFL.txt"):
        check("product.notice." + filename, any(bundle.rglob(filename)), "Bundled dependency notice: " + filename)
    check("product.no_test_payload", not list(bundle.rglob("*.xctest")), "No test bundles in distribution product")
    if require_signing:
        team = signing_checks(bundle, group)
        signing_checks(ext, group, team)
    else:
        blocked("signing.distribution", "Not requested; an unsigned device build does not prove archive/export/signing readiness")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--app", type=Path, help="Actual Release iphoneos .app (unsigned allowed unless --require-signing)")
    group.add_argument("--archive", type=Path, help="Actual .xcarchive containing Products/Applications/MeetSpace.app")
    parser.add_argument("--require-signing", action="store_true", help="Require App Store distribution profiles and signatures; never signs or uploads")
    parser.add_argument("--report", type=Path, help="Write redacted machine-readable result")
    args = parser.parse_args()
    if args.require_signing and not (args.app or args.archive):
        parser.error("--require-signing requires --app or --archive")
    metadata = None
    try:
        source_checks()
        bundle = args.app
        if args.archive:
            apps = list((args.archive / "Products/Applications").glob("*.app"))
            check("archive.application_count", len(apps) == 1, "Exactly one app in archive")
            if len(apps) == 1:
                bundle = apps[0]
                check("archive.dsym", (args.archive / "dSYMs/MeetSpace.app.dSYM/Contents/Resources/DWARF/MeetSpace").is_file(), "Archive includes app dSYM")
        if bundle:
            metadata = product_checks(bundle, args.require_signing)
        else:
            blocked("product.device_release", "No actual device product supplied; SDK, archive and signing not verified")
    except (OSError, ValueError, KeyError, StopIteration, plistlib.InvalidFileException, ET.ParseError) as error:
        # Paths can contain user names; do not serialize exception text or tool output.
        check("verification.input", False, "Missing or malformed required input (" + type(error).__name__ + ")")
    revision = command(["git", "rev-parse", "HEAD"])
    dirty = command(["git", "status", "--porcelain"])
    tracked_inputs = ["App/Info.plist", "App/MeetSpace.entitlements", "App/PrivacyInfo.xcprivacy",
                      "BroadcastExtension/Info.plist", "BroadcastExtension/MeetSpaceBroadcast.entitlements",
                      "BroadcastExtension/PrivacyInfo.xcprivacy", "MeetSpace.xcodeproj/project.pbxproj",
                      "Packages/MeetSpaceKit/Package.swift", "Packages/MeetSpaceKit/Package.resolved",
                      "scripts/generate_xcode_project.py", "scripts/verify_release.py"]
    source_hashes = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                     for path in tracked_inputs if (ROOT / path).is_file()}
    report = {"schema": 1, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
              "sourceCommit": revision.stdout.decode().strip(), "workingTreeModified": bool(dirty.stdout),
              "sourceInputSHA256": source_hashes,
              "requirementsVerifiedAt": "2026-11-06", "minimumXcode": 26, "minimumSDK": 26,
              "buildMetadata": metadata, "checks": checks,
              "result": "FAIL" if any(c["status"] == "FAIL" for c in checks) else "PASS",
              "distributionApproval": "NOT_GRANTED",
              "externalGates": ["Apple credentials and real archive/export validation", "SDK provenance/signature and complete native dependency notices",
                                "Physical-device performance/calls/APNs/ReplayKit checks", "Publisher privacy policy, disclosures, export compliance and App Store review"]}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for entry in checks:
        print(f'{entry["status"]}: {entry["check"]}: {entry["detail"]}')
    print("Packaging gate: " + report["result"] + "; App Store distribution approval: NOT_GRANTED")
    return 1 if report["result"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
