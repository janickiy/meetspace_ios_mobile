#!/usr/bin/env python3
"""Run a real audio-only SFU/record-worker/FFmpeg/S3 pipeline with synthetic Opus silence; no device/video certification."""
import argparse
import json
import hashlib
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
    parser.add_argument("--worker-image", default="go-recorder-worker:latest")
    args = parser.parse_args()
    backend = args.backend.resolve()
    commit = subprocess.check_output(["git", "-C", str(backend), "rev-parse", "HEAD"], text=True).strip()
    if commit != BACKEND_COMMIT:
        raise SystemExit("Use the pinned backend commit recorded in docs/stage07/RUNTIME_CONTRACT.md")
    subprocess.run(["git", "-C", str(backend), "diff", "--exit-code", "--quiet", "HEAD"], check=True)
    output = args.output or Path(tempfile.mkdtemp(prefix="meetspace-ios-recording-"))
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit("Output directory must be empty")
    output.chmod(0o700)
    names, ports, images = [], {}, {}
    api_name = None
    nonce, password = secrets.token_hex(6), secrets.token_urlsafe(32)
    network = f"meetspace-ios-recording-{nonce}"
    network_created = False

    def run(command, **options):
        return subprocess.run(command, check=True, **options)

    def container(service, image, port, environment, command=(), mounts=(), entrypoint=None):
        name = f"meetspace-ios-recording-{nonce}-{service}"
        command_line = ["docker", "run", "-d", "--name", name, "--network", network, "--label", f"meetspace.ios.recording={nonce}",
                        "-p", f"127.0.0.1::{port}"]
        if entrypoint:
            command_line += ["--entrypoint", entrypoint]
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
        run(["docker", "network", "create", "--label", f"meetspace.ios.recording={nonce}", network], stdout=subprocess.DEVNULL)
        network_created = True
        architecture = subprocess.check_output(["docker", "info", "--format", "{{.Architecture}}"], text=True).strip()
        go_architecture = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64", "amd64": "amd64"}.get(architecture)
        if go_architecture is None:
            raise RuntimeError("Unsupported Docker architecture")
        build_environment = os.environ.copy()
        build_environment.update(GOOS="linux", GOARCH=go_architecture, CGO_ENABLED="0")
        with (output / "backend-build.log").open("w") as log:
            for name, source in [("meetspace-api", "./cmd/api"), ("meetspace-media", "./cmd/media-worker"),
                                 ("meetspace-recorder", "./cmd/record-worker"),
                                 ("recording-probe", str(ROOT / "scripts/fixtures/recording_probe.go"))]:
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
            "MINIO_ENDPOINT": f"{minio}:9000", "MINIO_PUBLIC_ENDPOINT": f"https://{minio}:9000",
            "MINIO_ROOT_USER": "ios_test", "MINIO_ROOT_PASSWORD": password, "MINIO_BUCKET": "ios-contract",
            "RABBIT_MQ_HOST": rabbitmq, "RABBIT_MQ_PORT": "5672",
            "RABBIT_MQ_USER": "ios_test", "RABBIT_MQ_PASSWORD": password, "RATE_LIMIT_ENABLED": "false",
            "PUBLIC_FRONTEND_URL": "https://fixture.example",
            "MEDIA_WORKER_INTERNAL_URL": f"http://meetspace-ios-recording-{nonce}-mediaworker:8091",
            "MEDIA_INTERNAL_SECRET": secrets.token_urlsafe(48), "MEDIA_TICKET_SECRET": secrets.token_urlsafe(48),
            "MEDIA_HTTP_PORT": "8091", "MEDIA_MAX_PEERS": "4", "MEDIA_UDP_PORT": "50010",
            "MEDIA_WORKER_ID": "ios-contract-media", "MEDIA_MAX_SCREEN_SHARERS": "1",
            "WORKER_ID": "ios-contract-recorder", "WORKER_PORT": "8090", "STORAGE_PATH": "/storage",
            "FFMPEG_PATH": "/usr/bin/ffmpeg", "RECORDING_WIDTH": "320", "RECORDING_HEIGHT": "240",
            "RECORDING_FPS": "10", "RECORDING_MAX_ACTIVE": "1", "RECORDING_MAX_MIB": "32",
            "RECORDING_MAX_DURATION": "1m", "RECORDING_POLL_INTERVAL": "250ms", "RECORDING_LEASE_TTL": "10s",
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
        # Run only the newly built pinned recorder binary; reuse cached runtime solely for FFmpeg/libs.
        record_name = container("recordworker", args.worker_image, 8090, environment, [],
            [str((output / "meetspace-recorder").resolve()) + ":/app/record-worker:ro",
             str(backend / "database/migrations") + ":/app/database/migrations:ro"], entrypoint="/app/record-worker")
        for _ in range(60):
            if subprocess.check_output(["docker", "inspect", record_name, "--format", "{{.State.Running}}"], text=True).strip() != "true":
                raise RuntimeError("Pinned record-worker exited; inspect private log")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{ports['recordworker']}/health", timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            time.sleep(0.5)
        else:
            raise RuntimeError("Record worker did not start")
        # The probe creates its own disposable users. Bearers remain in its memory only.
        probe_name = f"meetspace-ios-recording-{nonce}-probe"
        names.append(probe_name)
        probe_environment = os.environ.copy()
        probe_environment["MEETSPACE_PROBE_API"] = f"http://{api_name}:8080"
        probe_environment["MEETSPACE_PROBE_OBJECT_HOST"] = f"{minio}:9000"
        with (output / "recording-probe.log").open("w") as log:
            result = subprocess.run(["docker", "run", "--name", probe_name, "--network", network,
                "--label", f"meetspace.ios.recording={nonce}", "-e", "MEETSPACE_PROBE_API", "-e", "MEETSPACE_PROBE_OBJECT_HOST",
                "-v", str(output.resolve()) + ":/evidence",
                "-v", str((output / "recording-probe").resolve()) + ":/recording-probe:ro", "alpine:3.22", "/recording-probe"],
                env=probe_environment, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        if result.returncode != 0:
            raise RuntimeError("Recording pipeline probe failed; inspect recording-probe.log")
        # Independently inspect and fully decode the actual downloaded artifact with cached FFmpeg.
        probe_command = ["docker", "run", "--rm", "--network", "none", "-v", str(output.resolve()) + ":/evidence:ro"]
        with (output / "ffprobe.json").open("w") as log:
            run(probe_command + ["--entrypoint", "/usr/bin/ffprobe", args.worker_image, "-v", "error", "-count_frames",
                "-show_entries", "stream=codec_name,codec_type,sample_rate,channels,duration,nb_read_frames:format=duration,size",
                "-of", "json", "/evidence/recording.m4a"], stdout=log, stderr=subprocess.PIPE)
        media = json.loads((output / "ffprobe.json").read_text())
        if len(media["streams"]) != 1 or media["streams"][0]["codec_name"] != "aac" or media["streams"][0]["codec_type"] != "audio" or int(media["streams"][0]["nb_read_frames"]) < 100 or not 4 <= float(media["format"]["duration"]) <= 30:
            raise RuntimeError("Downloaded artifact did not contain expected decoded AAC frames")
        with (output / "decode.txt").open("w") as log:
            run(probe_command + ["--entrypoint", "/usr/bin/ffmpeg", args.worker_image, "-v", "error", "-i", "/evidence/recording.m4a", "-f", "null", "-"], stdout=log, stderr=subprocess.STDOUT)
        (output / "decode.txt").write_text("PASS: FFmpeg fully decoded the downloaded audio artifact with exit code 0\n")
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
            raise RuntimeError("SFU retained peers/tracks after recording scenario")
        (output / "sfu-cleanup.json").write_text(json.dumps(snapshot, indent=2) + "\n")
        (output / "runtime.json").write_text(json.dumps({
            "backendCommit": commit, "images": images, "result": result.returncode, "recordingMode": "audio_only", "syntheticSource": "valid Opus silence, 20ms packets", "realRecorderFFmpegAndS3": True,
            "transport": "isolated Docker HTTP/WS + DTLS/SRTP; production requires HTTPS/WSS",
            "sourceHashes": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [ROOT / "scripts/run_recording_pipeline.py", ROOT / "scripts/fixtures/recording_probe.go"]},
            "limitations": ["Synthetic silent audio source, no microphone or camera capture", "No video rendering or iOS/AVPlayer/device acceptance", "Test-only internal HTTP/WS and signed-download HTTPS to known HTTP MinIO adapter; no public TLS deployment"],
            "artifact": json.loads((output / "artifact.json").read_text()), "ffprobe": media,
            "ffmpegDecode": "PASS, exit code 0"
        }, indent=2) + "\n")
        print("PASS: real ready audio recording pipeline; logs in " + str(output))
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
        remaining = subprocess.check_output(["docker", "ps", "-aq", "--filter", f"label=meetspace.ios.recording={nonce}"], text=True).splitlines()
        networks = subprocess.check_output(["docker", "network", "ls", "-q", "--filter", f"label=meetspace.ios.recording={nonce}"], text=True).splitlines()
        (output / "cleanup.json").write_text(json.dumps({"remainingContainers": len(remaining), "remainingNetworks": len(networks)}, indent=2) + "\n")
        for file in output.iterdir():
            if file.is_file():
                file.chmod(0o600)


if __name__ == "__main__":
    raise SystemExit(main())
