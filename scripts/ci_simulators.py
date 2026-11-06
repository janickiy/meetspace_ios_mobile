#!/usr/bin/env python3
"""Select installed iOS simulators by device family; never silently omit iPad."""
import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--family", choices=["iPhone", "iPad"], required=True)
    parser.add_argument("--runtime-major", type=int)
    parser.add_argument("--preferred-device")
    parser.add_argument("--label")
    parser.add_argument("--scope", choices=["full", "audit", "compatibility", "deletion"], default="full")
    args = parser.parse_args()
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    candidates = []
    for runtime, devices in inventory["devices"].items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(map(int, runtime.split(".iOS-")[1].split("-")))
        if version < (18,):
            continue
        if args.runtime_major and version[0] != args.runtime_major:
            continue
        for device in devices:
            if device["name"].startswith(args.family) and device.get("isAvailable"):
                candidates.append((device["name"] == args.preferred_device, version, device["name"], device["udid"]))
    if not candidates:
        raise SystemExit(f"BLOCKED: no available {args.family} simulator for iOS {args.runtime_major or '18+'}")
    preferred, version, name, udid = sorted(candidates, reverse=True)[0]
    label = args.label or args.family
    if not label.isalnum():
        raise SystemExit("Label must be alphanumeric")
    print(f"Testing {name} on iOS {version}: {udid}, scope={args.scope}", flush=True)
    result = Path("artifacts") / f"{label}.xcresult"
    result.parent.mkdir(exist_ok=True)
    (result.parent / f"{label}-environment.json").write_text(json.dumps({
        "device": name, "runtime": list(version), "udid": udid, "scope": args.scope,
        "preferredDeviceMatched": preferred, "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True),
    }, indent=2) + "\n")
    selection = []
    if args.scope == "deletion":
        selection = ["-only-testing:MeetSpaceUITests/FoundationUITests/testStage08AccountDeletionRequiresPasswordAndConfirmation"]
    elif args.scope != "full":
        selection = ["-only-testing:MeetSpaceTests",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testAccessibilityStage08CoreScreens",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testAccessibilityStage08LargeTextLiveFlow",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testStage08AccountDeletionRequiresPasswordAndConfirmation",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testConferenceCreateMediaControlsChatAndLeave",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testLargeTextNavigationAndAppearance"]
    try:
        subprocess.run(["xcodebuild", "-project", "MeetSpace.xcodeproj", "-scheme", "MeetSpace-Debug",
                        "-destination", f"platform=iOS Simulator,id={udid}", "-destination-timeout", "120",
                        "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO",
                        *selection, "test"], check=True)
    finally:
        # UI-test diagnostics contain only enum classifications of synthetic fixture
        # inputs, never passwords, lengths, hashes, tokens or production account data.
        with (result.parent / f"{label}-fixture-diagnostics.txt").open("w") as diagnostic:
            subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "show", "--style", "compact",
                            "--predicate", 'eventMessage CONTAINS "MeetSpaceDeletionDiagnostic"',
                            "--last", "1h"], stdout=diagnostic, stderr=subprocess.DEVNULL, check=False)
        if result.exists():
            # Diagnostic export must not replace the actual xcodebuild test result.
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                            "--output-path", f"artifacts/{label}-screenshots"], check=False)
            subprocess.run(["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(result),
                            "--output-path", f"artifacts/{label}-diagnostics"], check=False)
            with (result.parent / f"{label}-summary.json").open("w") as summary:
                subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                "--path", str(result)], stdout=summary, check=False)


if __name__ == "__main__":
    main()
