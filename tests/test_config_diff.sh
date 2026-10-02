#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DIFF_SCRIPT="$ROOT/config-tools/config_diff.awk"
python3 - <<'PY'
import json, os, subprocess, tempfile
from pathlib import Path
script = os.environ['DIFF_SCRIPT']
count = 0
with tempfile.TemporaryDirectory() as tmp:
    old, new = Path(tmp) / 'old.yaml', Path(tmp) / 'new.yaml'
    def run(a, b):
        old.write_text(a); new.write_text(b)
        return subprocess.run(['awk', '-v', f'OLD={old}', '-v', f'NEW={new}', '-f', script], input='', text=True, capture_output=True)
    def check(a, b, want):
        global count
        result = run(a, b)
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert json.loads(result.stdout) == want, (result.stdout, want)
        assert result.stderr == ''
        count += 1
    def reject(a, b):
        global count
        result = run(a, b)
        assert result.returncode != 0
        assert result.stdout == '' and result.stderr == 'ERROR\n', (result.stdout, result.stderr)
        count += 1
    check('dns:\n  enable: true\nsecret: old-token\nport: 7890\n', 'dns:\n  enable: false\nport: 7890\nmode: rule\n', [dict(section='dns', change='changed'), dict(section='secret', change='removed'), dict(section='mode', change='added')])
    check('', '', [])
    check('mode: rule\ndns:\n  enable: true\n', 'dns:\n  enable: true\nmode: rule\n', [])
    check('# old header\nmode: rule\n# old footer\n', '# new header\nmode: rule\n# new footer\n', [])
    check('dns:\n  # old nested note\n  enable: true\n', 'dns:\n  # new nested note\n  enable: true\n', [dict(section='dns', change='changed')])
    check('mode: rule\r\n', 'mode: rule\n', [])
    check('---\nmode: rule\n...\n', 'mode: rule\n', [])
    check('description: |\n  first\n\n  second\n', 'description: |\n  first\n  second\n', [dict(section='description', change='changed')])
    check('\n# header\nmode: rule\n', 'mode: rule\n', [])
    secrets = ['ss://password@host.example', 'https://host.example/sub?token=PRIVATE', 'bearer PRIVATE', 'uuid-private-123', 'NodeSecretName', 'vmess://PRIVATE', 'trojan://PASSWORD', '192.0.2.44', 'user:password', 'ssh-rsa PRIVATE']
    for secret in secrets:
        check(f'proxies:\n  - name: {secret}\nsecret: {secret}\n', 'proxies: []\nsecret: changed\n', [dict(section='proxies', change='changed'), dict(section='secret', change='changed')])
    for invalid in ['"secret": PRIVATE\n', "'secret': PRIVATE\n", 'секрет: PRIVATE\n', 'bad.key: PRIVATE\n', '- PRIVATE\n', 'secret: PRIVATE\nsecret: SECOND\n', 'secret: PRIVATE\n---\nsecret: SECOND\n', '  orphan: PRIVATE\n', 'secret:PRIVATE\n']:
        reject(invalid, 'mode: rule\n')
        reject('mode: rule\n', invalid)
    check('foo_bar-9: old\n', 'foo_bar-9: new\n', [dict(section='foo_bar-9', change='changed')])
    result = subprocess.run(['awk', '-v', f'OLD={tmp}/missing', '-v', f'NEW={new}', '-f', script], input='', text=True, capture_output=True)
    assert result.returncode != 0 and result.stdout == '' and result.stderr == 'ERROR\n'
    count += 1
print(f'PASS: {count} config diff cases')
PY
