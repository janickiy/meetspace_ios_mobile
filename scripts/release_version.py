"""Shared release metadata for the Xcode project and distribution tools."""
import re
from pathlib import Path

RELEASE_VERSION = (Path(__file__).resolve().parents[1] / "VERSION").read_text().strip()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", RELEASE_VERSION):
    raise ValueError("VERSION must contain a three-part version with an optional prerelease suffix")

MARKETING_VERSION = RELEASE_VERSION.split("-", 1)[0]
BUILD_NUMBER = "14"


def matches_release(info):
    return (info.get("CFBundleShortVersionString") == MARKETING_VERSION
            and info.get("CFBundleVersion") == BUILD_NUMBER
            and info.get("MeetSpaceReleaseVersion") == RELEASE_VERSION)
