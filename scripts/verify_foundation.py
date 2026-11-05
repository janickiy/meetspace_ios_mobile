#!/usr/bin/env python3
"""Static integrity checks, deliberately not a replacement for xcodebuild/UI tests."""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def main():
    subprocess.run(["python3", str(ROOT / "scripts/generate_xcode_project.py"), "--check"], check=True)
    for name in ("Info.plist", "PrivacyInfo.xcprivacy"):
        with (ROOT / "App" / name).open("rb") as file:
            data = plistlib.load(file)
        if name == "Info.plist":
            require("NSAppTransportSecurity" not in data, "Unexpected ATS overrides")
            require(data["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is False, "Unimplemented multiwindow enabled")
    for configuration in ("Debug", "Release"):
        scheme = ET.parse(ROOT / f"MeetSpace.xcodeproj/xcshareddata/xcschemes/MeetSpace-{configuration}.xcscheme")
        require(scheme.find("LaunchAction").attrib["buildConfiguration"] == configuration, "Incorrect scheme configuration")
        require(len(scheme.findall("TestAction/Testables/TestableReference")) == 2, "Missing iOS test targets")
    package = (ROOT / "Packages/MeetSpaceKit/Package.swift").read_text()
    for name in ("Core", "API", "Realtime", "Storage", "DesignSystem", "Features"):
        require(f'name: "MeetSpace{name}"' in package, f"Missing module {name}")
    for path in (ROOT / "Packages/MeetSpaceKit/Sources").rglob("*.swift"):
        text = path.read_text()
        require("URLCredential(trust:" not in text, f"TLS bypass in {path}")
        require("print(" not in text, f"Unreviewed logging in {path}")
    provenance = json.loads((ROOT / "docs/ios/evidence/stage02/resource-manifest.json").read_text())
    for item in provenance["resources"]:
        path = ROOT / item["path"]
        require(path.is_file(), f"Missing resource {path}")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], f"Resource changed: {path}")
    strings = ROOT / "Packages/MeetSpaceKit/Sources/DesignSystem/Resources/ru.lproj/Localizable.strings"
    translations = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', strings.read_text(), re.MULTILINE))
    for path in (ROOT / "Packages/MeetSpaceKit/Sources").rglob("*.swift"):
        for raw in re.findall(r'"((?:[^"\\]|\\.)*)"', path.read_text()):
            if re.search("[А-Яа-яЁё]", raw) and "\\(" not in raw:
                require(raw in translations, f"Missing Russian localization: {raw}")
    print("PASS: modules, schemes, resources, Russian copy and TLS configuration integrity")


if __name__ == "__main__":
    main()
