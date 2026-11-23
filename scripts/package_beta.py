#!/usr/bin/env python3
"""Package a simulator app and, when supplied, an unsigned iOS archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from release_version import BUILD_NUMBER, RELEASE_VERSION, matches_release

ROOT = Path(__file__).resolve().parents[1]


def binary_architectures(app, info, extension, platform):
    required = {'arm64', 'x86_64'} if platform == 'iPhoneSimulator' else {'arm64'}
    binaries = [app / info['CFBundleExecutable'],
                app / 'PlugIns/BroadcastUpload.appex' / extension['CFBundleExecutable'],
                app / 'Frameworks/WebRTC.framework/WebRTC']
    receipt = {}
    for binary in binaries:
        if not binary.is_file():
            raise SystemExit(f'Required release binary is missing: {binary}')
        result = subprocess.run(['xcrun', 'lipo', '-archs', str(binary)],
                                capture_output=True, text=True, check=True, timeout=30)
        architectures = set(result.stdout.split())
        if not required.issubset(architectures):
            raise SystemExit(f'{binary.name}: expected {sorted(required)}, found {sorted(architectures)}')
        receipt[binary.relative_to(app).as_posix()] = sorted(architectures)
    return receipt


def package(products, directory):
    files = []
    for kind, bundle, app, platform in products:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        extension = plistlib.loads((app / 'PlugIns/BroadcastUpload.appex/Info.plist').read_bytes())
        for data in [info, extension]:
            if not matches_release(data) or platform not in data.get('CFBundleSupportedPlatforms', []):
                raise SystemExit(f'{kind}: expected {platform} release {RELEASE_VERSION}, build {BUILD_NUMBER}')
        if info.get('CFBundleIdentifier') != 'com.meetspace.ios' or not (app / 'MeetSpace').is_file():
            raise SystemExit(f'{kind}: expected a MeetSpace application bundle')
        architectures = binary_architectures(app, info, extension, platform)
        if platform == 'iPhoneSimulator':
            for signed_bundle in [app, app / 'PlugIns/BroadcastUpload.appex', app / 'Frameworks/WebRTC.framework']:
                subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(signed_bundle)],
                               check=True, timeout=30)
        output = directory / f'MeetSpace-{RELEASE_VERSION}-{kind}.zip'
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(bundle), str(output)], check=True)
        files.append({'file': output.name, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                      'bytes': output.stat().st_size, 'platform': platform,
                      'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                      'binaryArchitectures': architectures,
                      'simulatorCodeSignVerified': platform == 'iPhoneSimulator'})
    (directory / 'SHA256SUMS').write_text(''.join(f"{x['sha256']}  {x['file']}\n" for x in files))
    installation = 'Extract the simulator ZIP and install MeetSpace.app on an iPhone or iPad simulator.'
    if any(kind == 'ios-unsigned' for kind, *_ in products):
        installation += ' The device ZIP contains an unsigned xcarchive requiring Apple signing.'
    (directory / 'manifest.json').write_text(json.dumps({
        'release': RELEASE_VERSION, 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'distributionSigned': False, 'files': files,
        'installation': installation
    }, indent=2) + '\n')
    return [entry['file'] for entry in files] + ['SHA256SUMS', 'manifest.json']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Optional unsigned device xcarchive')
    parser.add_argument('--simulator-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    products = []
    if args.archive:
        products.append(('ios-unsigned', args.archive, args.archive / 'Products/Applications/MeetSpace.app', 'iPhoneOS'))
    products.append(('simulator', args.simulator_app, args.simulator_app, 'iPhoneSimulator'))
    args.output.mkdir(parents=True, exist_ok=True)
    # Prepare all products first. Hard links publish each complete file without overwriting an existing release.
    with tempfile.TemporaryDirectory(dir=args.output) as temp:
        staging = Path(temp)
        filenames = package(products, staging)
        published = []
        try:
            for name in filenames:
                target = args.output / name
                os.link(staging / name, target)
                published.append(target)
        except OSError:
            for target in published:
                target.unlink()
            raise
    print(f'Packaged MeetSpace {RELEASE_VERSION} ({BUILD_NUMBER}) in {args.output}')


if __name__ == '__main__':
    main()
