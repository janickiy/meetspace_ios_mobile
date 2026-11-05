#!/usr/bin/env python3
"""Select installed iOS simulators by device family; never silently omit iPad."""
import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--family", choices=["iPhone", "iPad"], required=True)
    args = parser.parse_args()
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    candidates = []
    for runtime, devices in inventory["devices"].items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(map(int, runtime.split(".iOS-")[1].split("-")))
        if version < (18,):
            continue
        for device in devices:
            if device["name"].startswith(args.family) and device.get("isAvailable"):
                candidates.append((version, device["name"], device["udid"]))
    if not candidates:
        raise SystemExit(f"BLOCKED: no available {args.family} simulator running iOS 18+")
    _, name, udid = sorted(candidates, reverse=True)[0]
    print(f"Testing {name}: {udid}", flush=True)
    result = Path("artifacts") / f"{args.family}.xcresult"
    result.parent.mkdir(exist_ok=True)
    try:
        subprocess.run(["xcodebuild", "-project", "MeetSpace.xcodeproj", "-scheme", "MeetSpace-Debug",
                        "-destination", f"platform=iOS Simulator,id={udid}", "-destination-timeout", "120",
                        "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO",
                        "test"], check=True)
    finally:
        if result.exists():
            # Diagnostic export must not replace the actual xcodebuild test result.
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                            "--output-path", f"artifacts/{args.family}-screenshots"], check=False)


if __name__ == "__main__":
    main()
