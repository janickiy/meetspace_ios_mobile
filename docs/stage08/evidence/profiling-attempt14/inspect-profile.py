#!/usr/bin/env python3
"""Read actual profiler artifacts. Reports raw evidence only; derives no CPU/RSS verdict."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def table_structure(path):
    rows = 0
    fields = Counter()
    sample_rows = []
    schema = []
    for _, node in ET.iterparse(path, events=('end',)):
        if node.tag == 'schema':
            schema.append(ET.tostring(node, encoding='unicode'))
            node.clear()
        elif node.tag == 'row':
            rows += 1
            fields.update(child.tag for child in node)
            if len(sample_rows) < 3:
                sample_rows.append(ET.tostring(node, encoding='unicode')[:12000])
            node.clear()
    return {'rows': rows, 'fieldCounts': dict(fields), 'schema': schema,
            'firstThreeRowsForSchemaReview': sample_rows,
            'note': 'IDs/ref values and units require human interpretation before deriving metrics'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.directory.resolve()
    receipt = json.loads((root / 'receipt.json').read_text())
    result = {'sourceCommit': receipt.get('sourceCommit'), 'receiptStatus': receipt.get('status'),
              'reason': receipt.get('reason'), 'elapsedSeconds': receipt.get('elapsedSeconds'),
              'scope': receipt.get('scope'), 'nativeTestResultIndependent': True,
              'cpuPercent': None, 'rssBytes': None, 'energy': None, 'performanceAcceptance': 'NOT_ESTABLISHED',
              'files': [], 'receiptHashChecks': [], 'captures': [], 'cleanupCommands': []}
    for path in sorted(root.rglob('*')):
        if path.is_file():
            result['files'].append({'file': str(path.relative_to(root)), 'bytes': path.stat().st_size,
                                    'sha256': digest(path)})
    for entry in receipt.get('evidenceFiles', []):
        path = root / entry['file']
        valid = path.is_file() and path.stat().st_size == entry['bytes'] and digest(path) == entry['sha256']
        result['receiptHashChecks'].append({'file': entry['file'], 'matches': valid})
    result['cleanupCommands'] = [item for item in receipt.get('commands', [])
                                 if item.get('name') in ['fixture-cleanup', 'simulator-cleanup']]
    for capture in receipt.get('captures', []):
        inspected = dict(capture)
        if capture.get('toc'):
            toc = ET.parse(root / capture['toc']).getroot()
            inspected['tocProcessAttributes'] = [item.attrib for item in toc.iter('process')]
            inspected['tocRunAttributes'] = [item.attrib for item in toc.iter('run')]
        inspected['tableInspection'] = []
        for table in capture.get('tableExports', []):
            path = root / table['file']
            if path.is_file():
                structure = table_structure(path)
                structure.update(file=table['file'], schemaName=table['schema'],
                                 receiptRowsMatch=structure['rows'] == table.get('rows'))
                inspected['tableInspection'].append(structure)
        result['captures'].append(inspected)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'receiptStatus': result['receiptStatus'], 'captures': len(result['captures']),
                      'files': len(result['files']), 'hashMismatches': sum(not x['matches'] for x in result['receiptHashChecks']),
                      'output': str(args.output)}, indent=2))

if __name__ == '__main__':
    main()
