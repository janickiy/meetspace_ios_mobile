#!/usr/bin/env python3
"""Package built beta products; never describe an unsigned archive as an installable IPA."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--simulator-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    if version != '0.2.0-beta':
        raise SystemExit('Unexpected release label')
    products = [('ios-unsigned', args.archive, args.archive / 'Products/Applications/MeetSpace.app', 'iPhoneOS'),
                ('simulator', args.simulator_app, args.simulator_app, 'iPhoneSimulator')]
    args.output.mkdir(parents=True, exist_ok=True)
    files = []
    for kind, bundle, app, platform in products:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        extension = plistlib.loads((app / 'PlugIns/BroadcastUpload.appex/Info.plist').read_bytes())
        for data in [info, extension]:
            assert data['CFBundleShortVersionString'] == '0.2.0'
            assert data['CFBundleVersion'] == '2'
            assert data['MeetSpaceReleaseVersion'] == version
            assert platform in data['CFBundleSupportedPlatforms']
        assert info['CFBundleIdentifier'] == 'com.meetspace.ios'
        assert (app / 'MeetSpace').is_file()
        architectures = binary_architectures(app, info, extension, platform)
        if platform == 'iPhoneSimulator':
            for signed_bundle in [app, app / 'PlugIns/BroadcastUpload.appex', app / 'Frameworks/WebRTC.framework']:
                subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(signed_bundle)],
                               check=True, timeout=30)
        output = args.output / f'MeetSpace-{version}-{kind}.zip'
        assert not output.exists(), 'Refusing to replace a previously packaged artifact'
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(bundle), str(output)], check=True)
        files.append({'file': output.name, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                      'bytes': output.stat().st_size, 'platform': platform,
                      'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                      'binaryArchitectures': architectures,
                      'simulatorCodeSignVerified': platform == 'iPhoneSimulator'})
    (args.output / 'SHA256SUMS').write_text(''.join(f"{x['sha256']}  {x['file']}\n" for x in files))
    (args.output / 'manifest.json').write_text(json.dumps({
        'release': version, 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'distributionSigned': False, 'files': files,
        'installation': 'Simulator ZIP contains a simulator .app. Device ZIP is an unsigned xcarchive requiring Apple signing; no IPA or TestFlight upload.'
    }, indent=2) + '\n')
    print('Packaged beta simulator app and unsigned device archive')


if __name__ == '__main__':
    main()
