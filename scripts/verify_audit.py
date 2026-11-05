#!/usr/bin/env python3
"""Read-only integrity checks for the stage 01 audit. No network or server writes."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs/ios"
REQUIRED = (
    "API_CONTRACTS.md", "REALTIME_PROTOCOL.md", "SCREEN_MATRIX.md",
    "FEATURE_PARITY.md", "RISK_REGISTER.md", "AUDIT_REPORT.md",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path,
                        help="Directory containing pinned backend, android and design checkouts")
    args = parser.parse_args()
    errors = []

    def check(condition, message):
        if not condition:
            errors.append(message)

    manifest = json.loads((DOCS / "evidence/source-manifest.json").read_text())
    references = manifest["references"]
    markdown = [ROOT / "README.md", *(DOCS / name for name in REQUIRED)]
    for path in markdown:
        check(path.is_file() and path.stat().st_size > 100, f"Missing/empty document: {path.name}")
    if errors:
        return finish(errors)

    for path in markdown:
        content = path.read_text()
        table_columns = None
        for number, line in enumerate(content.splitlines(), 1):
            if not line.startswith("|"):
                table_columns = None
                continue
            columns = len(re.findall(r"(?<!\\)\|", line))
            if table_columns is None:
                table_columns = columns
            check(columns == table_columns, f"Malformed table: {path.name}:{number}")
        definitions = dict(re.findall(r"^\[([^\]]+)\]:\s+(\S+)\s*$", content, re.M))
        used = set(re.findall(r"\]\[([BAD]-[a-z-]+)\]", content))
        for key in used:
            check(key in references, f"Unknown source reference {key} in {path.name}")
            if key in references:
                check(definitions.get(key) == references[key]["url"],
                      f"Unpinned or missing source link {key} in {path.name}")
        for link in re.findall(r"\]\(([^)]+)\)", content):
            parsed = urlsplit(link)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            target = (path.parent / unquote(parsed.path)).resolve()
            check(target.is_relative_to(ROOT) and target.is_file(),
                  f"Invalid local link in {path.name}: {link}")

    # These are credential signatures, not sample credentials; never print a match.
    patterns = [
        re.compile(r"\b(?:gh[pousr]|hp)_[A-Za-z0-9]{30,}\b"),
        re.compile(r"github_pat_[A-Za-z0-9_]{30,}"),
        re.compile(r"https?://[^\s/<>'\"]+@"),
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ]
    scan = [*ROOT.glob("*.md"), *DOCS.rglob("*.md"), *DOCS.rglob("*.json"),
            *DOCS.rglob("*.txt"), *ROOT.joinpath("scripts").glob("*.py")]
    for path in scan:
        check(not any(pattern.search(path.read_text()) for pattern in patterns),
              f"Potential credential in {path.relative_to(ROOT)} (value redacted)")

    parity = (DOCS / "FEATURE_PARITY.md").read_text()
    ids = re.findall(r"^\| (F\d{2})\s", parity, re.M)
    check(len(ids) == 23 and set(ids) == {f"F{i:02d}" for i in range(1, 24)},
          "Feature IDs must be unique F01-F23")
    matrix = (DOCS / "SCREEN_MATRIX.md").read_text()
    screen_ids = re.findall(r"^\| `([a-z-]+)` /", matrix, re.M)
    check(len(screen_ids) == len(set(screen_ids)) == 21, "Expected 21 distinct design screen rows")

    design_report = json.loads((DOCS / "evidence/design-checks.json").read_text())
    check(all(item["exit_code"] == 0 for item in design_report["javascript"]),
          "Recorded design syntax check failed")
    check(all(item["exists"] for item in design_report["local_html_css_resources"]),
          "Recorded design resource check failed")

    if args.source_root:
        source = args.source_root.resolve()
        for key, repo in manifest["repositories"].items():
            checkout = source / key
            result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=checkout,
                                    capture_output=True, text=True)
            check(result.returncode == 0 and result.stdout.strip() == repo["commit"],
                  f"Wrong source commit: {key}")
        for key, ref in references.items():
            file = source / ref["repository"] / ref["path"]
            check(file.is_file() and hashlib.sha256(file.read_bytes()).hexdigest() == ref["sha256"],
                  f"Source checksum mismatch: {key}")
        design = source / "design"
        tracked = subprocess.check_output(["git", "ls-files"], cwd=design, text=True).splitlines()
        check(set(tracked) == {item["path"] for item in manifest["design_files"]},
              "Design inventory differs from tracked tree")
        for item in manifest["design_files"]:
            file = design / item["path"]
            check(file.is_file() and hashlib.sha256(file.read_bytes()).hexdigest() == item["sha256"],
                  f"Design checksum mismatch: {item['path']}")
        for item in manifest["route_declarations"]:
            lines = (source / "backend" / item["path"]).read_text().splitlines()
            check(0 < item["line"] <= len(lines)
                  and lines[item["line"] - 1].strip() == item["declaration"],
                  f"Route declaration differs: {item['path']}:{item['line']}")
        gallery = (design / "meetspace-refresh-20261016/gallery.js").read_text()
        # The first literal array is the gallery screen catalog, not application state.
        catalog = gallery.split("const screens = [", 1)[1].split("];", 1)[0]
        actual_ids = re.findall(r'id:\s*"([a-z-]+)"', catalog)
        check(set(actual_ids) == set(screen_ids), "Screen matrix differs from gallery catalog")
        print(f"Checked {len(references)} source hashes, {len(manifest['design_files'])} design files, "
              f"{len(manifest['route_declarations'])} route/group declarations")
    else:
        print("Source checkout verification: NOT RUN (pass --source-root)")
    print(f"Checked {len(markdown)} documents, {len(ids)} feature rows, {len(screen_ids)} screen rows")
    return finish(errors)


def finish(errors):
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: audit integrity; does not certify runtime behavior or absence of all secrets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
