#!/usr/bin/env python3
"""Bounded, evidence-first simulator profiling; does not change the app.

Two short post-launch/idle fixture captures, not launch latency, call stress,
physical-device energy, or a leak-free verdict. Requires macOS + full Xcode.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

BUNDLE = "com.meetspace.ios"
SCOPE = ("Debug iOS Simulator app, early post-launch/idle welcome UI, -uitesting fixtures; "
         "15s Time Profiler plus 15s Allocations by default. Not app launch latency, "
         "30 calls, network throughput, physical-device CPU/memory/energy, or absence of leaks.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="Exact already-booted test simulator UUID")
    parser.add_argument("--output", required=True, type=Path, help="New, empty evidence directory")
    parser.add_argument("--seconds", type=int, default=15, choices=range(5, 16))
    parser.add_argument("--wall-budget", type=int, default=180, choices=range(90, 241))
    args = parser.parse_args()
    try:
        simulator = str(uuid.UUID(args.simulator)).upper()
    except ValueError:
        parser.error("--simulator must be a UUID; no name/host/all-processes fallback")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("--output must be new/empty; existing traces are never overwritten")
    os.chmod(out, 0o700)
    started = time.monotonic()
    deadline = started + args.wall_budget
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    report = {"schema": 1, "status": "BLOCKED", "scope": SCOPE,
              "simulatorUDID": simulator, "bundleID": BUNDLE,
              "requestedSecondsPerTemplate": args.seconds, "wallBudgetSeconds": args.wall_budget,
              "sourceCommit": os.environ.get("GITHUB_SHA"), "commands": [], "captures": [],
              "notCovered": ["launch latency", "30 call cycles", "Leaks", "screen sharing",
                             "reconnect", "transfers", "physical devices", "energy", "Release performance"]}
    launched = False

    def save():
        report["elapsedSeconds"] = round(time.monotonic() - started, 3)
        (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name, command, timeout=12):
        remaining = 5 if name == "fixture-cleanup" else deadline - time.monotonic()
        result = {"name": name, "argv": command, "log": name + ".log"}
        report["commands"].append(result)
        begin = time.monotonic()
        if remaining <= 0:
            result.update(exitCode=None, timedOut=True, reason="global wall budget exhausted")
            save()
            return result, ""
        path = out / result["log"]
        try:
            with path.open("w") as log:
                child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                         env=env, start_new_session=True)
                try:
                    code = child.wait(timeout=max(0.1, min(timeout, remaining)))
                    result.update(exitCode=code, timedOut=False)
                except subprocess.TimeoutExpired:
                    result.update(exitCode=None, timedOut=True, reason="command timeout")
                    # Only the process group started here, never other xctrace/Xcode jobs.
                    for sig, grace in [(signal.SIGINT, 3), (signal.SIGTERM, 2), (signal.SIGKILL, 1)]:
                        if child.poll() is not None:
                            break
                        try:
                            os.killpg(child.pid, sig)
                            child.wait(timeout=grace)
                        except (ProcessLookupError, subprocess.TimeoutExpired):
                            pass
                    result["exitCode"] = child.poll()
        except OSError as error:
            path.write_text(f"Tool launch failed: {error}\n")
            result.update(exitCode=None, timedOut=False, reason="tool could not be launched")
        result["elapsedSeconds"] = round(time.monotonic() - begin, 3)
        save()
        return result, path.read_text(errors="replace") if path.exists() else ""

    def success(result):
        return result.get("exitCode") == 0 and not result.get("timedOut")

    def blocked(reason, *, failure=False):
        report["reason"] = reason
        report["status"] = "FAIL" if failure else "BLOCKED"
        save()
        print(f"{report['status']}: {reason}; receipt={out / 'receipt.json'}")
        return 1 if failure else 2

    try:
        if sys.platform != "darwin":
            return blocked("Requires macOS/full Xcode; no host substitute")
        run("developer-directory", ["xcode-select", "-p"])
        run("xcode-version", ["xcodebuild", "-version"])
        available, _ = run("find-xctrace", ["xcrun", "--find", "xctrace"])
        if not success(available):
            return blocked("xctrace missing from active developer directory; see find-xctrace.log")
        inventory = {}
        for name, command in [
            ("xctrace-version", ["xcrun", "xctrace", "version"]),
            ("xctrace-templates", ["xcrun", "xctrace", "list", "templates"]),
            ("xctrace-devices", ["xcrun", "xctrace", "list", "devices"]),
            ("xctrace-record-help", ["xcrun", "xctrace", "help", "record"]),
            ("xctrace-export-help", ["xcrun", "xctrace", "help", "export"]),
            ("simctl-launch-help", ["xcrun", "simctl", "help", "launch"]),
            ("simctl-devices", ["xcrun", "simctl", "list", "devices", "available", "--json"]),
        ]:
            result, text = run(name, command)
            inventory[name] = (result, text)
        required = ["xctrace-templates", "xctrace-devices", "xctrace-record-help", "xctrace-export-help", "simctl-devices"]
        if any(not success(inventory[name][0]) for name in required):
            return blocked("Required inventory/help command failed; actual stderr preserved")
        record_help = inventory["xctrace-record-help"][1]
        if any(flag not in record_help for flag in ["--template", "--device", "--attach", "--time-limit", "--output"]):
            return blocked("Installed xctrace record CLI does not advertise required options")
        export_help = inventory["xctrace-export-help"][1]
        if not all(flag in export_help for flag in ["--input", "--toc", "--xpath"]):
            return blocked("Installed xctrace export CLI differs; no guessed syntax fallback")
        devices = json.loads(inventory["simctl-devices"][1]).get("devices", {})
        match = [(runtime, device) for runtime, group in devices.items() for device in group
                 if device.get("udid", "").upper() == simulator]
        if len(match) != 1 or match[0][1].get("state") != "Booted" or ".iOS-" not in match[0][0]:
            return blocked("Exact requested iOS simulator is not available and already Booted")
        report["runtime"] = match[0][0]
        report["deviceName"] = match[0][1].get("name")
        if simulator.lower() not in inventory["xctrace-devices"][1].lower():
            return blocked("xctrace does not list requested simulator; host/device fallback forbidden")
        container_result, container_text = run("app-container", ["xcrun", "simctl", "get_app_container", simulator, BUNDLE, "app"])
        if not success(container_result):
            return blocked("App not installed on exact simulator")
        app = Path(container_text.strip())
        info = plistlib.loads((app / "Info.plist").read_bytes())
        executable = info.get("CFBundleExecutable")
        if info.get("CFBundleIdentifier") != BUNDLE or not executable:
            return blocked("Installed app identity does not match requested fixture app")
        # Xcode Debug may put Swift code into a debug dylib instead of the executable.
        code_files = [app / executable, app / (executable + ".debug.dylib")]
        fixture_marker = False
        for path in code_files:
            if path.is_file():
                with path.open("rb") as source:
                    tail = b""
                    while chunk := source.read(1024 * 1024):
                        if b"-uitesting" in tail + chunk:
                            fixture_marker = True
                            break
                        tail = chunk[-32:]
        if not fixture_marker:
            return blocked("Installed executable has no DEBUG -uitesting marker; will not launch live dependencies")
        report["fixtureMarkerPresent"] = True
        report["launchArguments"] = ["-uitesting"]
        for slug, template in [("cpu", "Time Profiler"), ("allocations", "Allocations")]:
            capture = {"template": template, "status": "BLOCKED", "target": "exact simulator PID"}
            report["captures"].append(capture)
            if template not in inventory["xctrace-templates"][1]:
                capture["reason"] = "Template not advertised by current Xcode"
                save()
                continue
            if deadline - time.monotonic() < args.seconds + 20:
                capture["reason"] = "Insufficient remaining bounded wall time"
                save()
                continue
            launch, launch_text = run(slug + "-launch", ["xcrun", "simctl", "launch", "--terminate-running-process", simulator, BUNDLE, "-uitesting"])
            if not success(launch):
                capture["status"] = "FAIL"
                capture["reason"] = "simctl fixture launch failed"
                continue
            launched = True
            found = re.search(r"^" + re.escape(BUNDLE) + r":\s*(\d+)\s*$", launch_text, re.MULTILINE)
            if not found:
                capture["status"] = "FAIL"
                capture["reason"] = "Cannot identify launched PID without guessing"
                continue
            pid = found.group(1)
            capture["pid"] = int(pid)
            process, process_name = run(slug + "-process-identity", ["/bin/ps", "-p", pid, "-o", "comm="])
            if not success(process) or not process_name.strip().endswith("/" + executable):
                capture["status"] = "FAIL"
                capture["reason"] = "Returned PID is not the expected app executable"
                continue
            trace = out / (slug + ".trace")
            command = ["xcrun", "xctrace", "record", "--template", template, "--device", simulator,
                       "--attach", pid, "--time-limit", f"{args.seconds}s", "--output", str(trace)]
            if "--no-prompt" in record_help:
                command.append("--no-prompt")
            recorded, _ = run(slug + "-record", command, timeout=args.seconds + 25)
            capture["recordExitCode"] = recorded.get("exitCode")
            capture["trace"] = trace.name
            capture["traceBytes"] = sum(p.stat().st_size for p in trace.rglob("*") if p.is_file()) if trace.is_dir() else 0
            if not success(recorded) or capture["traceBytes"] == 0:
                capture["status"] = "FAIL"
                capture["reason"] = "Attach/record failed or empty trace; see record log (no success inferred)"
                capture["measurementGate"] = "NO_VALID_TRACE"
                continue
            capture["traceAcquired"] = True
            toc = out / (slug + "-toc.xml")
            exported, _ = run(slug + "-toc-export", ["xcrun", "xctrace", "export", "--input", str(trace), "--toc", "--output", str(toc)], timeout=15)
            if not success(exported) or not toc.exists():
                capture["status"] = "FAIL"
                capture["reason"] = "Trace written but TOC cannot be inspected"
                continue
            root = ET.parse(toc).getroot()
            capture["toc"] = toc.name
            capture["tables"] = sorted({table.get("schema") for table in root.iter("table") if table.get("schema")})
            capture["targetPIDMentionedInTOC"] = any(
                re.search(r"(?<!\d)" + pid + r"(?!\d)", " ".join(node.attrib.values()) + " " + (node.text or ""))
                for node in root.iter("process"))
            if not capture["targetPIDMentionedInTOC"]:
                capture["status"] = "FAIL"
                capture["reason"] = "Trace TOC does not confirm target PID; inspect original TOC before any attribution"
                continue
            choices = [name for name in capture["tables"] if (name == "time-profile" if slug == "cpu" else re.search(r"alloc|heap", name, re.I))]
            capture["tableExports"] = []
            # Schema names come from this trace, not from assumed Xcode versions.
            for index, schema in enumerate(choices[:2]):
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", schema):
                    continue
                xml = out / f"{slug}-table-{index}.xml"
                xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
                data_result, _ = run(slug + f"-table-{index}-export", ["xcrun", "xctrace", "export", "--input", str(trace), "--xpath", xpath, "--output", str(xml)], timeout=12)
                rows = None
                if success(data_result) and xml.exists():
                    rows = 0
                    for _, node in ET.iterparse(xml, events=("end",)):
                        if node.tag == "row":
                            rows += 1
                        node.clear()
                capture["tableExports"].append({"schema": schema, "file": xml.name, "rows": rows})
            if any(item["rows"] is None for item in capture["tableExports"]):
                capture["status"] = "FAIL"
                capture["reason"] = "Available table export failed; trace preserved, not a successful profiling gate"
                capture["measurementGate"] = "EXPORT_FAILED"
            elif not capture["tableExports"]:
                capture["status"] = "BLOCKED"
                capture["reason"] = "Trace acquired but no recognized CPU/allocation schema; measurement not established"
                capture["measurementGate"] = "NO_RECOGNIZED_SCHEMA"
                capture["analysisRequired"] = True
            elif not any(item["rows"] > 0 for item in capture["tableExports"]):
                capture["status"] = "BLOCKED"
                capture["reason"] = "Trace acquired but exported tables contain zero records; no measured data claimed"
                capture["measurementGate"] = "NO_RECORDS"
                capture["analysisRequired"] = True
            else:
                capture["status"] = "RECORDED"
                capture["reason"] = "Native Instruments trace and target TOC recorded; human analysis required, no derived CPU/RSS claim"
                capture["measurementGate"] = "NONEMPTY_TABLES_REVIEW_REQUIRED"
                capture["analysisRequired"] = True
            # Zero rows can reflect idle UI or an unsupported instrument. Never manufacture a metric.
            save()
        if report["captures"] and all(x["status"] == "RECORDED" for x in report["captures"]):
            report["status"] = "RECORDED"
            report["reason"] = "Two short native simulator traces captured, not performance acceptance"
            code = 0
        elif any(x["status"] == "FAIL" for x in report["captures"]):
            report["status"] = "FAIL"
            report["reason"] = "At least one requested launch/attach/record/export failed; inspect exact logs"
            code = 1
        else:
            return blocked("At least one required instrument/measurement unavailable; partial traces, if any, are not completion")
        save()
        print(f"{report['status']}: receipt={out / 'receipt.json'}")
        return code
    except (OSError, ValueError, ET.ParseError, plistlib.InvalidFileException) as error:
        report["exception"] = f"{type(error).__name__}: {error}"
        return blocked("Evidence/setup could not be completed; see receipt exception", failure=True)
    finally:
        if launched:
            run("fixture-cleanup", ["xcrun", "simctl", "terminate", simulator, BUNDLE], timeout=5)
        report["evidenceFiles"] = []
        for path in sorted(out.iterdir()):
            if path.is_file() and path.name != "receipt.json":
                report["evidenceFiles"].append({"file": path.name, "bytes": path.stat().st_size,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        save()


if __name__ == "__main__":
    raise SystemExit(main())
