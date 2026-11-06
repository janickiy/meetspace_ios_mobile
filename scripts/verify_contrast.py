#!/usr/bin/env python3
"""Measure WCAG text contrast of actual semantic palette values (not screenshots)."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def luminance(value):
    channels = [((value >> shift) & 255) / 255 for shift in (16, 8, 0)]
    return sum(weight * (v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4)
               for weight, v in zip((0.2126, 0.7152, 0.0722), channels))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    source = (ROOT / "Packages/MeetSpaceKit/Sources/DesignSystem/Theme.swift").read_text()
    colors = {name: [int(light, 16), int(dark, 16)] for name, light, dark in
              re.findall(r"static let (\w+) = adaptive\(0x([a-f0-9]+), 0x([a-f0-9]+)\)", source)}
    rows = []
    for index, mode in enumerate(("light", "dark")):
        for foreground in ("ink", "muted", "accent", "success", "danger"):
            for background in ("background", "surface", "surfaceSecondary", "accentSoft"):
                values = sorted([luminance(colors[foreground][index]), luminance(colors[background][index])])
                ratio = (values[1] + 0.05) / (values[0] + 0.05)
                rows.append({"mode": mode, "foreground": foreground, "background": background,
                             "ratio": round(ratio, 4), "status": "PASS" if ratio >= 4.5 else "FAIL"})
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"standard": "WCAG 2.x relative luminance, normal text >=4.5:1",
                                          "scope": "Opaque semantic text colors; does not replace UI/VoiceOver audit",
                                          "checks": rows}, indent=2) + "\n")
    failed = [row for row in rows if row["status"] == "FAIL"]
    print(json.dumps({"checks": len(rows), "failed": failed}, ensure_ascii=False))
    raise SystemExit(bool(failed))


if __name__ == "__main__":
    main()
