#!/bin/sh
set -eu

# Регрессия BusyBox awk: буквальные YAML/JSON escape-последовательности
# в имени не должны ломать JSON или менять имя после его разбора.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  echo 'test_json_backslashes.sh: SKIP (python3 недоступен)'
  exit 0
fi

python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
awk = shlex.split(os.environ.get('AWK', 'awk'))
names = [
    r'\U0001F1F3\U0001F1F1 Netherlands',
    r'literal \u0041 \n \r \t \x \q',
    r'node "quoted" \\server\share & <tag>',
    '🇳🇱 Нидерланды',
]
generated = 'control\tcarriage\rnewline\nend'

with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    # ENVIRON сохраняет настоящие управляющие символы без дополнительного
    # разбора escape-последовательностей в -v разными реализациями awk.
    (work / 'init.awk').write_text('BEGIN { generated = ENVIRON["JSON_TEST_CONTROL"]; started_iso = generated }\n', encoding='utf-8')
    environment = dict(os.environ, JSON_TEST_CONTROL=generated)
    (work / 'runs.tsv').write_text('1000\t2026-10-27 12:00:00\t100\t25\t4\t4\t4\t4\t4\n', encoding='utf-8')
    (work / 'nodes.tsv').write_text(''.join('1000\t100\t' + n + '\n' for n in names), encoding='utf-8')
    (work / 'last.tsv').write_text(''.join('1.5\tMB/s\t' + n + '\n' for n in names), encoding='utf-8')
    (work / 'stability.tsv').write_text(''.join(n + '\t2026-10-27\t2026-10-27\t1\t1\t0\t10\t1\t0\tA\t100\t100\t1\n' for n in names), encoding='utf-8')
    (work / 'progress.tsv').write_text(''.join(n + '\t100\tok\n' for n in names), encoding='utf-8')

    output = subprocess.check_output(awk + [
        '-v', 'last=' + str(work / 'last.tsv'),
        '-v', 'nodes=' + str(work / 'nodes.tsv'),
        '-v', 'stability=' + str(work / 'stability.tsv'),
        '-f', str(work / 'init.awk'),
        '-f', str(root / 'web/render_stats.awk'), str(work / 'runs.tsv'),
    ], env=environment)
    stats = json.loads(output)
    assert stats['generated'] == generated
    assert stats['runs']['count'] == 1
    for rows in [stats['last_measurement'], stats['node_history']['top'], stats['node_stability']]:
        assert {row['name'] for row in rows} == set(names), rows

    output = subprocess.check_output(awk + [
        '-v', 'running=1', '-v', 'total=4', '-f', str(work / 'init.awk'),
        '-f', str(root / 'web/render_progress.awk'), str(work / 'progress.tsv'),
    ], env=environment)
    progress = json.loads(output)
    assert progress['started_iso'] == generated
    assert progress['running'] is True and progress['tested'] == 4
    assert [row['name'] for row in progress['results']] == names

print('test_json_backslashes.sh: OK (stats, progress, literal escapes, Unicode, controls)')
PY
