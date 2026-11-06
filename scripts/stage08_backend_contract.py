#!/usr/bin/env python3
"""Run real Stage 08 current-backend and account-deletion contracts against disposable dependencies and an unchanged backend checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BACKEND_COMMIT = "9e6058c31cc07bff0f48d8f7f6a40106c55c4881"


def source_files():
    package = ROOT / "Packages/MeetSpaceKit"
    return [ROOT / "scripts/stage08_backend_contract.py", *sorted((package / "Sources/API").glob("*.swift")),
            *sorted((package / "Sources/Core").glob("*.swift")), package / "Tests/IntegrationTests/FeaturesLoopbackTests.swift", package / "Tests/IntegrationTests/Stage08APILoopbackTests.swift",
            package / "Tests/IntegrationTests/Stage03Tests.swift", package / "Tests/IntegrationTests/LoopbackContractTests.swift"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--minio-image", default="go-recorder-minio:local")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    backend = args.backend.resolve()
    commit = subprocess.check_output(["git", "-C", str(backend), "rev-parse", "HEAD"], text=True).strip()
    if commit != BACKEND_COMMIT:
        raise SystemExit("Use the pinned backend commit recorded in docs/stage08/API_CONTRACT.md")
    subprocess.run(["git", "-C", str(backend), "diff", "--exit-code", "--quiet", "HEAD"], check=True)
    output = args.output or Path(tempfile.mkdtemp(prefix="meetspace-ios-stage08-"))
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit("Output directory must be empty")
    output.chmod(0o700)
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files()}
    names, ports, images = [], {}, {}
    api_name = None
    nonce, password = secrets.token_hex(6), secrets.token_urlsafe(32)
    network = f"meetspace-ios-stage08-{nonce}"
    network_created = False

    def run(command, **options):
        return subprocess.run(command, check=True, **options)

    def container(service, image, port, environment, command=(), mounts=()):
        name = f"meetspace-ios-stage08-{nonce}-{service}"
        command_line = ["docker", "run", "-d", "--name", name, "--network", network, "--label", f"meetspace.ios.stage08={nonce}",
                        "-p", f"127.0.0.1::{port}"]
        for mount in mounts:
            command_line += ["-v", mount]
        # Values stay in this child process's environment, never command arguments or reports.
        child_environment = os.environ.copy()
        for key, value in environment.items():
            child_environment[key] = value
            command_line += ["-e", key]
        run(command_line + [image] + list(command), env=child_environment, stdout=subprocess.DEVNULL)
        names.append(name)
        mapping = subprocess.check_output(["docker", "port", name, f"{port}/tcp"], text=True).strip()
        ports[service] = int(mapping.rsplit(":", 1)[1])
        images[service] = subprocess.check_output(["docker", "image", "inspect", image, "--format", "{{.Id}}"], text=True).strip()
        return name

    try:
        run(["docker", "network", "create", "--label", f"meetspace.ios.stage08={nonce}", network], stdout=subprocess.DEVNULL)
        network_created = True
        architecture = subprocess.check_output(["docker", "info", "--format", "{{.Architecture}}"], text=True).strip()
        go_architecture = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64", "amd64": "amd64"}.get(architecture)
        if go_architecture is None:
            raise RuntimeError("Unsupported Docker architecture")
        build_environment = os.environ.copy()
        build_environment.update(GOOS="linux", GOARCH=go_architecture, CGO_ENABLED="0")
        with (output / "backend-build.log").open("w") as log:
            run(["go", "build", "-o", str(output / "meetspace-api"), "./cmd/api"], cwd=backend, env=build_environment, stdout=log, stderr=subprocess.STDOUT)
        postgres = container("postgres", "postgres:17-alpine", 5432,
                             {"POSTGRES_USER": "ios_test", "POSTGRES_PASSWORD": password, "POSTGRES_DB": "ios_contract"})
        redis = container("redis", "redis:7-alpine", 6379, {})
        minio = container("minio", args.minio_image, 9000,
                  {"MINIO_ROOT_USER": "ios_test", "MINIO_ROOT_PASSWORD": password}, ["server", "/data"])
        rabbitmq = container("rabbitmq", "rabbitmq:4.2.9-management", 5672,
                  {"RABBITMQ_DEFAULT_USER": "ios_test", "RABBITMQ_DEFAULT_PASS": password})
        for _ in range(60):
            try:
                for port in ports.values():
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        pass
                # An open mapped TCP port does not mean RabbitMQ completed application startup.
                checks = [
                    ["docker", "exec", postgres, "pg_isready", "-U", "ios_test", "-d", "ios_contract"],
                    ["docker", "exec", "--user", "rabbitmq", rabbitmq, "rabbitmq-diagnostics", "-q", "check_running", "--timeout", "3"],
                ]
                with (output / "health-private.log").open("a") as health:
                    ready = all(subprocess.run(check, stdout=health, stderr=subprocess.STDOUT).returncode == 0 for check in checks)
                if not ready:
                    time.sleep(1)
                    continue
                with urllib.request.urlopen(f"http://127.0.0.1:{ports['minio']}/minio/health/ready", timeout=1) as response:
                    if response.status != 200:
                        continue
                break
            except OSError:
                time.sleep(1)
        else:
            raise RuntimeError("Dependencies did not start")
        environment = {
            "APP_ENV": "local", "APP_PORT": "8080", "GIN_MODE": "release",
            "JWT_SECRET": secrets.token_urlsafe(48),
            "POSTGRES_HOST": postgres, "POSTGRES_PORT": "5432",
            "POSTGRES_USER": "ios_test", "POSTGRES_PASSWORD": password, "POSTGRES_DB": "ios_contract",
            "REDIS_HOST": redis, "REDIS_PORT": "6379",
            "MINIO_ENDPOINT": f"{minio}:9000", "MINIO_PUBLIC_ENDPOINT": f"https://127.0.0.1:{ports['minio']}",
            "MINIO_ROOT_USER": "ios_test", "MINIO_ROOT_PASSWORD": password, "MINIO_BUCKET": "ios-contract",
            "RABBIT_MQ_HOST": rabbitmq, "RABBIT_MQ_PORT": "5672",
            "RABBIT_MQ_USER": "ios_test", "RABBIT_MQ_PASSWORD": password, "RATE_LIMIT_ENABLED": "false",
            "PUBLIC_FRONTEND_URL": "https://fixture.example", "MEDIA_WORKER_INTERNAL_URL": "http://127.0.0.1:1",
        }
        # The unmodified API listens on all interfaces INSIDE its isolated container.
        # Docker exposes its random host port on loopback only.
        api_name = container("api", "alpine:3.22", 8080, environment, ["/meetspace-api"],
                             [str((output / "meetspace-api").resolve()) + ":/meetspace-api:ro",
                              str(backend / "database/migrations") + ":/database/migrations:ro"])
        for _ in range(60):
            if subprocess.check_output(["docker", "inspect", api_name, "--format", "{{.State.Running}}"], text=True).strip() != "true":
                raise RuntimeError("Disposable backend exited; inspect private output")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{ports['api']}/version", timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            time.sleep(1)
        else:
            raise RuntimeError("API did not start")
        test_environment = os.environ.copy()
        test_environment.update(MEETSPACE_FEATURES_API_PORT=str(ports["api"]), MEETSPACE_STAGE08_API_PORT=str(ports["api"]))
        command = ["swift", "test", "--package-path", str(ROOT / "Packages/MeetSpaceKit")]
        developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        if developer.endswith("/CommandLineTools"):
            test_environment["SDKROOT"] = str(Path(developer) / "SDKs/MacOSX26.4.sdk")
            command += ["--sdk", str(Path(developer) / "SDKs/MacOSX26.4.sdk"),
                        "-Xswiftc", "-load-plugin-library", "-Xswiftc",
                        str(Path(developer) / "usr/lib/swift/host/plugins/testing/libTestingMacros.dylib")]
        command += ["--filter", "actualBackendCalendarFoldersSettingsAndRecordings|stage08ActualBackendAccountDeletion"]
        with (output / "contract.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=test_environment, stdout=log, stderr=subprocess.STDOUT)
        contract = (output / "contract.log").read_text()
        after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files()}
        changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
        result_code = result.returncode or (1 if changed else 0)
        selected = r"(?:actualBackendCalendarFoldersSettingsAndRecordings|stage08ActualBackendAccountDeletion)\(\)"
        passed = len(re.findall(r"^✔ Test " + selected + r" passed", contract, re.MULTILINE))
        failed = len(re.findall(r"^✘ Test " + selected + r" failed", contract, re.MULTILINE))
        (output / "runtime.json").write_text(json.dumps({
            "backendCommit": commit, "images": images, "result": result_code,
            "testCommand": command,
            "iosBaseCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "iosWorkingTreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
            "sourceSHA256": before, "sourceChangedDuringRun": changed,
            "tests": {"total": 2, "executed": passed + failed, "passed": passed, "failed": failed, "skipped": 0},
            "recordingsLimit": "API-only starting/stopping and authorization; no recorder/FFmpeg worker or final artifact, no AVPlayer acceptance",
            "transport": "test-only loopback HTTP/WS adapter; production requires HTTPS/WSS"
        }, indent=2) + "\n")
        excerpts = [line for line in contract.splitlines() if (line.startswith("PASS real Stage7") or line.startswith("PASS real Stage8")) or "Test run with" in line or "actualBackendCalendarFoldersSettingsAndRecordings" in line or "stage08ActualBackendAccountDeletion" in line]
        (output / "results.txt").write_text("\n".join(excerpts) + "\n")
        print(("PASS" if result_code == 0 else "FAIL") + ": current Stage8 backend contracts; logs in " + str(output))
        return result_code
    finally:
        if api_name is not None:
            with (output / "api-private.log").open("w") as log:
                subprocess.run(["docker", "logs", api_name], stdout=log, stderr=subprocess.STDOUT)
        for name in names:
            with (output / (name.rsplit("-", 1)[-1] + "-private.log")).open("w") as log:
                subprocess.run(["docker", "logs", name], stdout=log, stderr=subprocess.STDOUT)
        for name in reversed(names):
            # Every name was created in this invocation. No compose volumes, checkout data or user services are touched.
            subprocess.run(["docker", "rm", "-f", "-v", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if network_created:
            subprocess.run(["docker", "network", "rm", network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        remaining = subprocess.check_output(["docker", "ps", "-aq", "--filter", f"label=meetspace.ios.stage08={nonce}"], text=True).splitlines()
        remaining_networks = subprocess.check_output(["docker", "network", "ls", "-q", "--filter", f"label=meetspace.ios.stage08={nonce}"], text=True).splitlines()
        (output / "cleanup.json").write_text(json.dumps({"remainingContainers": len(remaining), "remainingNetworks": len(remaining_networks)}, indent=2) + "\n")
        for file in output.iterdir():
            if file.is_file():
                file.chmod(0o600)


if __name__ == "__main__":
    raise SystemExit(main())
