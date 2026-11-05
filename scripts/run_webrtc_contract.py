#!/usr/bin/env python3
"""Run Stage 04 REST and synthetic RTP checks against disposable API/SFU containers; not a device certification."""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BACKEND_COMMIT = "0bd1248a2411842515af4e02f1e95821616748fb"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--minio-image", default="go-recorder-minio:local")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--skip-swift", action="store_true", help="Run only the synthetic SFU probe; does not certify the Swift REST contract")
    args = parser.parse_args()
    backend = args.backend.resolve()
    commit = subprocess.check_output(["git", "-C", str(backend), "rev-parse", "HEAD"], text=True).strip()
    if commit != BACKEND_COMMIT:
        raise SystemExit("Use the pinned backend commit recorded in WEBRTC_REPORT.md")
    subprocess.run(["git", "-C", str(backend), "diff", "--exit-code", "--quiet", "HEAD"], check=True)
    output = args.output or Path(tempfile.mkdtemp(prefix="meetspace-ios-contract-"))
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit("Output directory must be empty")
    output.chmod(0o700)
    names, ports, images = [], {}, {}
    api_name = None
    nonce, password = secrets.token_hex(6), secrets.token_urlsafe(32)
    network = f"meetspace-ios-contract-{nonce}"
    network_created = False

    def run(command, **options):
        return subprocess.run(command, check=True, **options)

    def container(service, image, port, environment, command=(), mounts=()):
        name = f"meetspace-ios-contract-{nonce}-{service}"
        command_line = ["docker", "run", "-d", "--name", name, "--network", network, "--label", f"meetspace.ios.contract={nonce}",
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
        run(["docker", "network", "create", "--label", f"meetspace.ios.contract={nonce}", network], stdout=subprocess.DEVNULL)
        network_created = True
        architecture = subprocess.check_output(["docker", "info", "--format", "{{.Architecture}}"], text=True).strip()
        go_architecture = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64", "amd64": "amd64"}.get(architecture)
        if go_architecture is None:
            raise RuntimeError("Unsupported Docker architecture")
        build_environment = os.environ.copy()
        build_environment.update(GOOS="linux", GOARCH=go_architecture, CGO_ENABLED="0")
        with (output / "backend-build.log").open("w") as log:
            for name, source in [("meetspace-api", "./cmd/api"), ("meetspace-media", "./cmd/media-worker"),
                                 ("sfu-probe", str(ROOT / "scripts/fixtures/sfu_probe.go"))]:
                run(["go", "build", "-o", str(output / name), source], cwd=backend, env=build_environment, stdout=log, stderr=subprocess.STDOUT)
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
            "PUBLIC_FRONTEND_URL": "https://fixture.example",
            "MEDIA_WORKER_INTERNAL_URL": f"http://meetspace-ios-contract-{nonce}-mediaworker:8091",
            "MEDIA_INTERNAL_SECRET": secrets.token_urlsafe(48), "MEDIA_TICKET_SECRET": secrets.token_urlsafe(48),
            "MEDIA_HTTP_PORT": "8091", "MEDIA_MAX_PEERS": "4", "MEDIA_UDP_PORT": "50010",
            "MEDIA_WORKER_ID": "ios-contract-media",
        }
        media_name = container("mediaworker", "alpine:3.22", 8091, environment, ["/meetspace-media"],
                               [str((output / "meetspace-media").resolve()) + ":/meetspace-media:ro"])
        for _ in range(60):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{ports['mediaworker']}/healthz", timeout=1) as response:
                    if response.status == 204:
                        break
            except OSError:
                pass
            time.sleep(1)
        else:
            raise RuntimeError("SFU worker did not start")
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
        test_environment.update(MEETSPACE_CONFERENCE_API_PORT=str(ports["api"]))
        command = ["swift", "test", "--package-path", str(ROOT / "Packages/MeetSpaceKit")]
        developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        if developer.endswith("/CommandLineTools"):
            test_environment["SDKROOT"] = str(Path(developer) / "SDKs/MacOSX26.4.sdk")
            command += ["--sdk", str(Path(developer) / "SDKs/MacOSX26.4.sdk"),
                        "-Xswiftc", "-load-plugin-library", "-Xswiftc",
                        str(Path(developer) / "usr/lib/swift/host/plugins/testing/libTestingMacros.dylib")]
        command += ["--filter", "actualBackendConferenceRESTAndGuestScope"]
        if args.skip_swift:
            (output / "contract.log").write_text("SKIPPED: Swift conference REST contract (--skip-swift)\n")
        else:
            with (output / "contract.log").open("w") as log:
                result = subprocess.run(command, cwd=ROOT, env=test_environment, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode != 0:
                raise RuntimeError("Swift conference contract failed; inspect contract.log")
        # The probe creates its own disposable users. Bearers remain in its memory only.
        probe_name = f"meetspace-ios-contract-{nonce}-probe"
        names.append(probe_name)
        probe_environment = os.environ.copy()
        probe_environment["MEETSPACE_PROBE_API"] = f"http://{api_name}:8080"
        with (output / "sfu-probe.log").open("w") as log:
            result = subprocess.run(["docker", "run", "--name", probe_name, "--network", network,
                "--label", f"meetspace.ios.contract={nonce}", "-e", "MEETSPACE_PROBE_API",
                "-v", str((output / "sfu-probe").resolve()) + ":/sfu-probe:ro", "alpine:3.22", "/sfu-probe"],
                env=probe_environment, stdout=log, stderr=subprocess.STDOUT, timeout=110)
        if result.returncode != 0:
            raise RuntimeError("Synthetic SFU probe failed; inspect sfu-probe.log")
        snapshot = None
        for _ in range(30):
            req = urllib.request.Request(f"http://127.0.0.1:{ports['mediaworker']}/internal/media/metrics",
                headers={"Authorization": "Bearer " + environment["MEDIA_INTERNAL_SECRET"]})
            with urllib.request.urlopen(req, timeout=3) as response:
                snapshot = json.load(response)
            if all(snapshot.get(key) == 0 for key in ["mediaPeersActive", "tracksPublished", "subscriptions"]):
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("SFU retained peers/tracks after leave cycles")
        (output / "sfu-cleanup.json").write_text(json.dumps(snapshot, indent=2) + "\n")
        (output / "runtime.json").write_text(json.dumps({
            "backendCommit": commit, "images": images, "result": result.returncode, "swiftContractExecuted": not args.skip_swift,
            "transport": "test-only loopback HTTP/WS adapter; production requires HTTPS/WSS"
        }, indent=2) + "\n")
        scope = "three synthetic SFU RTP cycles (Swift skipped)" if args.skip_swift else "real conference REST and three synthetic SFU RTP cycles"
        print(("PASS" if result.returncode == 0 else "FAIL") + ": " + scope + "; logs in " + str(output))
        return result.returncode
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
        for file in output.iterdir():
            if file.is_file():
                file.chmod(0o600)


if __name__ == "__main__":
    raise SystemExit(main())
