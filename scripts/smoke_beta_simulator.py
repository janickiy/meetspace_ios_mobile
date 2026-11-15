#!/usr/bin/env python3
"""Install and launch the actual Release .app on an available iPhone/iOS 18 simulator."""
import argparse
import json
import plistlib
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


BUNDLE_ID = "com.meetspace.ios"


def choose_device(inventory):
    candidates = []
    for runtime, devices in inventory.get("devices", {}).items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(18(?:-\d+)*)", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match[1].split("-"))
        for device in devices:
            if (device.get("isAvailable") and device.get("name", "").startswith("iPhone")
                    and device.get("state") in ("Booted", "Shutdown")):
                candidates.append((device["state"] == "Booted", version, device["name"], device["udid"], runtime, device))
    if not candidates:
        raise RuntimeError("No available iPhone simulator with an iOS 18 runtime")
    *_, runtime, device = max(candidates, key=lambda item: item[:4])
    return {"udid": device["udid"], "name": device["name"], "runtime": runtime, "initialState": device["state"]}


def find_launch_pid(output):
    match = re.search(rf"^{re.escape(BUNDLE_ID)}:\s*([1-9]\d*)\s*$", output, re.MULTILINE)
    if not match:
        raise RuntimeError("simctl launch did not return the app PID")
    return int(match[1])


def process_is_running(output, pid):
    for line in output.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[0] == str(pid) and BUNDLE_ID in fields[2]:
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    screenshot = output / "release-simulator.png"
    screenshot.unlink(missing_ok=True)
    report = {"schema": 1, "status": "RUNNING", "app": str(app), "bundleID": BUNDLE_ID,
              "startedAt": datetime.now(timezone.utc).isoformat(), "commands": [], "cleanup": []}
    report_path = output / "release-simulator-smoke.json"
    device = None
    booted_by_script = install_attempted = launch_attempted = False
    verified = False

    def save():
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    def run(label, argv, timeout=30, check=True, cleanup=False):
        record = {"step": label, "argv": argv, "timeoutSeconds": timeout, "exitCode": None}
        report["cleanup" if cleanup else "commands"].append(record)
        started = time.monotonic()
        try:
            result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, check=False)
            record.update(exitCode=result.returncode, stdout=result.stdout[-8000:], stderr=result.stderr[-8000:])
            if check and result.returncode != 0:
                raise RuntimeError(f"{label} failed (exit {result.returncode})")
            return result
        except subprocess.TimeoutExpired:
            record["timedOut"] = True
            raise RuntimeError(f"{label} exceeded {timeout} seconds") from None
        finally:
            record["elapsedSeconds"] = round(time.monotonic() - started, 3)
            save()

    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        if info.get("CFBundleIdentifier") != BUNDLE_ID or "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
            raise RuntimeError("Expected the MeetSpace iPhoneSimulator .app bundle")
        if not (app / info.get("CFBundleExecutable", "")).is_file():
            raise RuntimeError("App executable is missing")
        report["version"] = info.get("CFBundleShortVersionString")
        report["build"] = info.get("CFBundleVersion")
        inventory = json.loads(run("inventory", ["xcrun", "simctl", "list", "devices", "available", "--json"]).stdout)
        device = choose_device(inventory)
        report["device"] = device
        udid = device["udid"]
        if device["initialState"] == "Shutdown":
            booted_by_script = True
            run("boot", ["xcrun", "simctl", "boot", udid], timeout=30)
        run("boot-status", ["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=300)
        existing = run("existing-app", ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "app"], timeout=90, check=False)
        if existing.returncode == 0:
            raise RuntimeError("MeetSpace is already installed; refusing to overwrite an existing simulator app")
        if not re.search(r"no such (?:file|app)|couldn.t be found", existing.stderr, re.IGNORECASE):
            raise RuntimeError("Could not determine whether MeetSpace is already installed")
        install_attempted = True
        run("install-release", ["xcrun", "simctl", "install", udid, str(app)], timeout=180)
        launch_attempted = True
        launch = run("launch-release", ["xcrun", "simctl", "launch", udid, BUNDLE_ID], timeout=60)
        pid = find_launch_pid(launch.stdout)
        report["pid"] = pid
        time.sleep(5)
        processes = run("check-running", ["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
        if not process_is_running(processes.stdout, pid):
            raise RuntimeError("Release app exited within five seconds of launch")
        run("screenshot", ["xcrun", "simctl", "io", udid, "screenshot", str(screenshot)], timeout=30)
        if not screenshot.is_file() or screenshot.stat().st_size == 0:
            raise RuntimeError("Simulator screenshot was not produced")
        processes = run("check-running-after-screenshot", ["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
        if not process_is_running(processes.stdout, pid):
            raise RuntimeError("Release app exited before screenshot verification")
        report["screenshot"] = screenshot.name
        verified = True
    except (OSError, ValueError, RuntimeError) as error:
        report["error"] = str(error)
    finally:
        if device:
            udid = device["udid"]
            cleanup = []
            if launch_attempted:
                cleanup.append(("terminate", ["xcrun", "simctl", "terminate", udid, BUNDLE_ID], 30))
            if install_attempted:
                cleanup.append(("uninstall", ["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], 90))
            if booted_by_script:
                cleanup.append(("restore-shutdown", ["xcrun", "simctl", "shutdown", udid], 90))
            for label, argv, timeout in cleanup:
                try:
                    run(label, argv, timeout=timeout, cleanup=True)
                except (OSError, RuntimeError) as error:
                    report.setdefault("cleanupErrors", []).append(str(error))
        report["status"] = "PASS" if verified and not report.get("cleanupErrors") else "FAIL"
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save()
    print(f"Release simulator smoke: {report['status']} — {report_path}", flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
