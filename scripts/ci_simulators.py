#!/usr/bin/env python3
"""Select installed iOS simulators by device family; never silently omit iPad."""
import argparse
import json
import platform
import subprocess
import time
from pathlib import Path


def export_results(result, label, test_exit_code):
    """Diagnostic failures never replace the native xcodebuild result."""
    receipt = {"schema": 1, "nativeTestExitCode": test_exit_code, "status": "RUNNING",
               "expectedExports": ["summary", "attachments", "diagnostics"], "exports": []}
    receipt_path = result.parent / f"{label}-export-status.json"

    def save():
        try:
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        except OSError as error:
            print(f"Could not save export receipt: {type(error).__name__}", flush=True)

    if not result.exists():
        receipt.update(status="FAIL", reason="No xcresult exists; no diagnostic success inferred")
        save()
        return
    commands = [
        ("summary", 30, ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]),
        ("attachments", 120, ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                              "--output-path", str(result.parent / f"{label}-screenshots")]),
        ("diagnostics", 60, ["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(result),
                             "--output-path", str(result.parent / f"{label}-diagnostics")]),
    ]
    for name, timeout, command in commands:
        log = result.parent / f"{label}-{name}-export.log"
        partial = result.parent / f"{label}-summary.partial.json"
        record = {"name": name, "argv": command, "timeoutSeconds": timeout,
                  "log": log.name, "exitCode": None, "timedOut": False, "status": "RUNNING"}
        receipt["exports"].append(record)
        save()
        started = time.monotonic()
        try:
            with log.open("w") as output:
                if name == "summary":
                    with partial.open("w") as summary:
                        completed = subprocess.run(command, stdout=summary, stderr=output, check=False, timeout=timeout)
                else:
                    completed = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=False, timeout=timeout)
            record["exitCode"] = completed.returncode
            record["status"] = "FAIL"
            if completed.returncode == 0:
                if name == "summary":
                    value = json.loads(partial.read_text())
                    if not isinstance(value, dict):
                        raise ValueError("Summary must be a JSON object")
                    # Publish a complete summary before potentially slow attachments/diagnostics.
                    partial.replace(result.parent / f"{label}-summary.json")
                record["status"] = "PASS"
        except subprocess.TimeoutExpired:
            record.update(status="FAIL", timedOut=True, reason="Export exceeded its bounded wait")
        except (OSError, ValueError) as error:
            record.update(status="FAIL", reason=type(error).__name__)
        record["elapsedSeconds"] = round(time.monotonic() - started, 3)
        save()
        print(f"{label} {name} export: {record['status']} (exit={record['exitCode']}, timeout={record['timedOut']})", flush=True)
    receipt["status"] = "PASS" if all(item["status"] == "PASS" for item in receipt["exports"]) else "FAIL"
    save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--family", choices=["iPhone", "iPad"], required=True)
    parser.add_argument("--runtime-major", type=int)
    parser.add_argument("--preferred-device")
    parser.add_argument("--label")
    parser.add_argument("--scope", choices=["full", "audit", "compatibility", "deletion", "regression", "push-recovery"], default="full")
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
        "hostArchitecture": platform.machine(), "hostOS": platform.platform(),
        "preferredDeviceMatched": preferred, "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True),
    }, indent=2) + "\n")
    selection = []
    if args.scope == "deletion":
        selection = ["-only-testing:MeetSpaceUITests/FoundationUITests/testStage08AccountDeletionRequiresPasswordAndConfirmation"]
    elif args.scope == "push-recovery":
        # P2 cleanup recovery: real Keychain protection/reopen tests plus the two affected
        # ordinary-push/deletion UI flows. Package fault-injection tests run in the package job.
        selection = ["-only-testing:MeetSpaceTests",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testOrdinaryPushOptInAndDisableWithFixtureToken",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testStage08AccountDeletionRequiresPasswordAndConfirmation"]
    elif args.scope == "regression":
        # Target the observed keyboard/profile harness failures on every device/runtime.
        # This is a separate regression result, not a replacement for the full baseline.
        selection = ["-only-testing:MeetSpaceTests",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testAccessibilityStage08CoreScreens",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testAccessibilityStage08LargeTextLiveFlow",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testStage07SettingsPersistProfilePreferencesAndSSHDisabled",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testStage08AccountDeletionRequiresPasswordAndConfirmation"]
    elif args.scope != "full":
        selection = ["-only-testing:MeetSpaceTests",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testAccessibilityStage08CoreScreens",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testAccessibilityStage08LargeTextLiveFlow",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testStage08AccountDeletionRequiresPasswordAndConfirmation",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testConferenceCreateMediaControlsChatAndLeave",
                     "-only-testing:MeetSpaceUITests/FoundationUITests/testLargeTextNavigationAndAppearance"]
    test_exit_code = None
    try:
        subprocess.run(["xcodebuild", "-project", "MeetSpace.xcodeproj", "-scheme", "MeetSpace-Debug",
                        "-destination", f"platform=iOS Simulator,id={udid}", "-destination-timeout", "120",
                        "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO",
                        *selection, "test"], check=True)
        test_exit_code = 0
    except subprocess.CalledProcessError as error:
        test_exit_code = error.returncode
        raise
    finally:
        export_results(result, label, test_exit_code)


if __name__ == "__main__":
    main()
