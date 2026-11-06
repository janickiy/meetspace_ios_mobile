#!/usr/bin/env python3
"""Measure already-built host stress tests, not iOS/energy/Instruments performance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TEST_FILES = [
    "Tests/IntegrationTests/ConferenceSessionTests.swift",
    "Tests/IntegrationTests/DirectCallCoordinatorTests.swift",
    "Tests/IntegrationTests/RecordingsTests.swift",
    "Tests/IntegrationTests/RealtimeStressTests.swift",
    "Tests/IntegrationTests/FileTransferStressTests.swift",
    "Tests/BroadcastTests/BroadcastLifecycleStressTests.swift",
]
SOURCE_FILES = [
    "Sources/Features/ConferenceSession.swift", "Sources/Features/DirectCallCoordinator.swift",
    "Sources/Realtime/UserRealtime.swift", "Sources/Storage/AccountFileStore.swift",
    "Sources/Broadcast/BroadcastHostChannel.swift", "Sources/Broadcast/BroadcastUploadConnection.swift",
    "Sources/Broadcast/BroadcastWire.swift", "Sources/API/RecordingDownloads.swift",
    "Sources/API/MessagingRepository.swift", "Sources/API/Authentication.swift",
]


def tree_rss_kib(root_pid):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True).splitlines()
    processes = [tuple(map(int, row.split())) for row in rows if len(row.split()) == 3]
    descendants = {root_pid}
    while True:
        expanded = descendants | {pid for pid, parent, _ in processes if parent in descendants}
        if expanded == descendants:
            break
        descendants = expanded
    return sum(rss for pid, _, rss in processes if pid in descendants)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--sdk", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin" or not 1 <= args.repeat <= 10:
        raise SystemExit("Requires macOS and 1...10 repetitions")
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise SystemExit("Output must be a new empty directory")
    command = ["swift", "test", "--package-path", "Packages/MeetSpaceKit", "--skip-build", "--filter", "stage08Thirty"]
    environment = os.environ.copy(); environment["LC_ALL"] = "C"
    if args.sdk:
        command += ["--sdk", str(args.sdk)]
        environment["SDKROOT"] = str(args.sdk)
    records = []
    for index in range(1, args.repeat + 1):
        resource_file = args.output / f"run-{index}-resources.txt"
        log_file = args.output / f"run-{index}.log"
        started = time.monotonic()
        samples = []
        with log_file.open("w") as log:
            process = subprocess.Popen(["/usr/bin/time", "-l", "-o", str(resource_file)] + command,
                cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None:
                samples.append({"elapsedSec": round(time.monotonic() - started, 4), "treeRSSKiB": tree_rss_kib(process.pid)})
                time.sleep(0.05)
        elapsed = time.monotonic() - started
        resources = resource_file.read_text()
        cpu = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", resources)
        rss = re.search(r"(\d+)\s+maximum resident set size", resources)
        output = log_file.read_text()
        passed = re.findall(r"Test (stage08Thirty\w+)\(\) passed after ([\d.]+) seconds", output)
        record = {"run": index, "exitCode": process.returncode, "wallMonotonicSec": round(elapsed, 4),
            "timeUserCPUSec": float(cpu[2]) if cpu else None, "timeSystemCPUSec": float(cpu[3]) if cpu else None,
            "timeMaximumRSSBytes": int(rss[1]) if rss else None,
            "sampledMaximumTreeRSSKiB": max((x["treeRSSKiB"] for x in samples), default=0),
            "tests": [{"name": name, "durationSec": float(seconds)} for name, seconds in passed]}
        records.append(record)
        (args.output / f"run-{index}-rss.json").write_text(json.dumps(samples, indent=2) + "\n")
        if process.returncode != 0 or len(passed) != 6 or cpu is None or rss is None:
            raise SystemExit(f"Run {index} failed or lacks six stress results; inspect {log_file}")
        print(f"Run {index}: 6 PASS; command wall {elapsed:.3f}s; sampled tree RSS {record['sampledMaximumTreeRSSKiB']} KiB", flush=True)
    selected = [ROOT / "Packages/MeetSpaceKit" / path for path in TEST_FILES + SOURCE_FILES]
    selected.append(Path(__file__).resolve())
    report = {
        "scope": "macOS host debug test process tree including SwiftPM/test runner; not iOS app, native WebRTC, device, Instruments, network throughput, or energy measurements",
        "method": "Build excluded (--skip-build). time.monotonic wall; macOS /usr/bin/time -l CPU/high-water RSS; ps parent-tree RSS sampled every approximately 50ms. RSS samples sum processes and may double-count shared pages; timing includes the SwiftPM runner.",
        "environment": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(),
            "logicalCPUs": os.cpu_count(), "swift": subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT).strip()},
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "workingTreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
        "sourceHashes": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in selected},
        "command": command, "cyclesPerStressTestPerRun": 30, "runs": records,
        "medianCommandWallSec": statistics.median(x["wallMonotonicSec"] for x in records),
        "acceptance": "Six functional stress tests pass each run. No performance threshold or energy result is inferred. Weak-release assertions cover selected Swift objects; they are not a process-wide leak detector."
    }
    (args.output / "host-stress.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
