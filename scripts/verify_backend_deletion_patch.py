#!/usr/bin/env python3
"""Verify the supplied backend fix in an isolated checkout and disposable PostgreSQL.
Never applies changes to --backend, reads its .env, or connects to an existing database.
Requires Git, Go, Docker and the pinned commit in the supplied local backend repository.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = '9e6058c31cc07bff0f48d8f7f6a40106c55c4881'
PATCH_ROOT = ROOT / 'server-patches/account-deletion'
PATCH = PATCH_ROOT / 'backend-device-account-serialization.patch'


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def output(argv, **kwargs):
    return subprocess.check_output(argv, text=True, **kwargs).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    backend, destination = args.backend.resolve(), args.output.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit('Output directory must be empty')
    destination.mkdir(parents=True, exist_ok=True)
    destination.chmod(0o700)
    evidence = json.loads((PATCH_ROOT / 'receipt.json').read_text())
    patch_digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
    if evidence['baseCommit'] != BASE or evidence['files'][PATCH.name]['sha256'] != patch_digest:
        raise SystemExit('Patch does not match its reviewed evidence')
    if output(['git', '-C', str(backend), 'rev-parse', BASE + '^{commit}']) != BASE:
        raise SystemExit('Pinned backend source is unavailable')
    name = 'meetspace-p2-verify-' + secrets.token_hex(6)
    child = os.environ.copy()
    child.update(POSTGRES_USER='audit_test', POSTGRES_PASSWORD=secrets.token_urlsafe(32), POSTGRES_DB='audit_backend')
    record = {'startedAtUTC': datetime.now(timezone.utc).isoformat(), 'baseCommit': BASE,
              'patchSHA256': patch_digest, 'status': 'FAIL', 'backendCheckoutModified': False,
              'testExitCode': None, 'cleanup': 'NOT_RUN'}
    created = False
    try:
        with tempfile.TemporaryDirectory(prefix='meetspace-p2-backend-') as folder:
            temporary = Path(folder)
            archive = temporary / 'source.tar'
            with archive.open('wb') as stream:
                run(['git', '-C', str(backend), 'archive', '--format=tar', BASE], stdout=stream)
            checkout = temporary / 'source'
            checkout.mkdir()
            with tarfile.open(archive) as source:
                source.extractall(checkout, filter='data')
            run(['git', 'apply', '--check', str(PATCH)], cwd=checkout)
            run(['git', 'apply', str(PATCH)], cwd=checkout)
            for path, details in evidence['sourceHashes'].items():
                if hashlib.sha256((checkout / path).read_bytes()).hexdigest() != details['sha256']:
                    raise RuntimeError('Applied source differs from reviewed patch: ' + path)
            record['applyCheck'] = 'PASS; applied source hashes match reviewed files'
            run(['docker', 'run', '-d', '--name', name, '--label', 'meetspace.audit.p2=true',
                 '--tmpfs', '/var/lib/postgresql/data', '-p', '127.0.0.1::5432',
                 '-e', 'POSTGRES_USER', '-e', 'POSTGRES_PASSWORD', '-e', 'POSTGRES_DB',
                 'postgres:17-alpine'], env=child, stdout=subprocess.DEVNULL)
            created = True
            for _ in range(60):
                ready = subprocess.run(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'audit_test', '-d', 'audit_backend'],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if ready.returncode == 0:
                    break
                time.sleep(1)
            else:
                raise RuntimeError('Disposable PostgreSQL did not become ready')
            mapping = output(['docker', 'port', name, '5432/tcp'])
            if not re.fullmatch(r'127\.0\.0\.1:\d+', mapping):
                raise RuntimeError('PostgreSQL is not exposed exclusively on loopback')
            port = mapping.rsplit(':', 1)[1]
            child['MEETSPACE_AUDIT_POSTGRES_DSN'] = 'postgres://audit_test:' + child['POSTGRES_PASSWORD'] + '@127.0.0.1:' + port + '/audit_backend?sslmode=disable'
            sql = ['docker', 'exec', name, 'psql', '-U', 'audit_test', '-d', 'audit_backend', '-Atc']
            record['postgresVersion'] = output(sql + ['SELECT version()'])
            record['isolation'] = output(sql + ['SHOW default_transaction_isolation'])
            record['dockerImage'] = output(['docker', 'inspect', name, '--format', '{{.Image}}'])
            record['goVersion'] = output(['go', 'version'])
            command = ['go', 'test', '-race', './internal/infrastructure/postgres', '-run',
                       '^TestAuditDevice(SaveSerializesWithAccountDeletion|RegistrationRechecksAccountState)$',
                       '-count=1', '-v', '-timeout', '3m']
            record['command'] = command
            with (destination / 'tests.log').open('w') as log:
                completed = subprocess.run(command, cwd=checkout, env=child, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            record['testExitCode'] = completed.returncode
            text = (destination / 'tests.log').read_text()
            passed = re.findall(r'^\s*--- PASS: (\S+)', text, re.M)
            failed = re.findall(r'^\s*--- FAIL: (\S+)', text, re.M)
            skipped = re.findall(r'^\s*--- SKIP: (\S+)', text, re.M)
            record['tests'] = {'topLevelPassed': len([x for x in passed if '/' not in x]),
                               'subtestsPassed': len([x for x in passed if '/' in x]),
                               'failed': failed, 'skipped': skipped,
                               'observedLockDependencies': text.count('observed second transaction waiting for first transaction in pg_blocking_pids')}
            if completed.returncode or failed or skipped or record['tests']['topLevelPassed'] != 2 or record['tests']['subtestsPassed'] != 9 or record['tests']['observedLockDependencies'] != 4:
                raise RuntimeError('Required real PostgreSQL cases did not all pass')
            remaining = output(sql + ["SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'audit_%'"])
            record['remainingAuditSchemas'] = int(remaining)
            if remaining != '0':
                raise RuntimeError('Audit schema cleanup failed')
            record['status'] = 'PASS'
    finally:
        if created:
            cleanup = subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            record['cleanup'] = 'PASS: owned disposable container removed' if cleanup.returncode == 0 else 'FAIL: owned container could not be removed'
            if cleanup.returncode:
                record['status'] = 'FAIL'
        record['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
        if (destination / 'tests.log').exists():
            record['logSHA256'] = hashlib.sha256((destination / 'tests.log').read_bytes()).hexdigest()
        (destination / 'receipt.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(record['status'] + ': pinned patch, 9 PostgreSQL cases, 4 observed lock dependencies, zero skipped; ' + record['cleanup'])
    return 0 if record['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
