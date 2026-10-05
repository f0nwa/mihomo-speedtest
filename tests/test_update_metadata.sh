#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile, unittest
ROOT = pathlib.Path(sys.argv[1])
SHA = 'a' * 64

def manifest(version=2, minimum=1):
    return (f'FORMAT_VERSION={version}\nRELEASE_VERSION=9\n'
            f'MIN_UPDATER_VERSION={minimum}\nCONFIG_SCHEMA_VERSION=1\n'
            + ('RELEASE_TAG=v9\n' if version == 2 else '')
            + 'COMPONENT|a|A\nCOMPONENT|b|B\nCOMPONENT|c|C\n'
            + ('NOTE|a|Без перезапуска\nNOTE|b|Перезапуск веба\nNOTE|c|Без перезапуска\n' if version == 2 else '')
            + f'FILE|a|a.sh|/opt/etc/mihomo-speedtest/a.sh|1|{SHA}|0755|sh\n')

class Updates(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = pathlib.Path(self.tmp.name)
    def plan(self, body, selected='a', installed='', validate=False):
        m = self.dir / 'manifest'; m.write_text(body)
        old = self.dir / 'installed'; old.write_text(installed)
        return subprocess.run(['awk', '-v', f'MANIFEST={m}', '-v', f'SELECTED={selected}',
            '-v', 'FORMAT=json', '-v', f'INSTALLED={old}', '-v', f'VALIDATE_ONLY={int(validate)}',
            '-f', str(ROOT / 'updater' / 'update_plan.awk')], capture_output=True, text=True)
    def reject(self, body, selected='a', message=''):
        r = self.plan(body, selected)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        if message: self.assertIn(message, r.stderr)
    def cli(self, body, *args):
        m = self.dir / 'manifest'; m.write_text(body)
        fetch = self.dir / 'fetch'; fetch.write_text('#!/bin/sh\ncat "$TEST_MANIFEST"\n'); fetch.chmod(0o755)
        env = dict(os.environ, UPDATE_HTTP_CMD=str(fetch), TEST_MANIFEST=str(m),
                   TMPROOT=str(self.dir), UPDATE_STATE_DIR=str(self.dir / 'state'))
        return subprocess.run(['sh', str(ROOT / 'updater' / 'update.sh'), *args], env=env, capture_output=True, text=True)
    def test_metadata_visible(self):
        r = self.plan(manifest()); self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual(d['release_tag'], 'v9')
        self.assertEqual(d['components'][0]['note'], 'Без перезапуска')
    def test_headers(self):
        for body in [manifest(99), manifest() + 'RELEASE_VERSION=10\n',
                     manifest().replace('RELEASE_TAG=v9\n', ''),
                     manifest().replace('RELEASE_TAG=v9', 'RELEASE_TAG=../main'),
                     manifest().replace('RELEASE_VERSION=9', 'RELEASE_VERSION=9=extra'),
                     manifest().replace('NOTE|a|Без перезапуска\n', '')]:
            with self.subTest(body=body): self.reject(body)
    def test_format_1_rejected(self):
        # Формат 1 (локальный прототип) больше не поддерживается, даже с
        # полным набором метаданных формата 2.
        body = manifest().replace('FORMAT_VERSION=2', 'FORMAT_VERSION=1')
        self.reject(body, 'a', 'Неподдерживаемый FORMAT_VERSION: 1')
        self.reject(manifest(version=1), 'a', 'Неподдерживаемый FORMAT_VERSION: 1')

    def test_ids(self):
        for selected in ['a,,b', 'a,', 'a a', 'a|b']:
            with self.subTest(selected=selected): self.reject(manifest(), selected)
        self.reject(manifest().replace('COMPONENT|a|A', 'COMPONENT|a a|A'))
    def test_paths_and_modes(self):
        for src in ['a//b', './a', 'a/', 'a?x=1', 'a#b', 'a b']:
            with self.subTest(src=src): self.reject(manifest().replace('|a.sh|', f'|{src}|'))
        self.reject(manifest().replace('|0755|sh', '|4755|sh'))
        self.reject(manifest().replace('/a.sh|', '/.update|'))
    def test_conflicts_after_dependencies(self):
        body = manifest() + 'CONFLICT|a|b\nDEPENDS|a|c\nDEPENDS|c|b\n'
        self.reject(body, 'a', 'Несовместим')
        r = self.plan(manifest() + 'CONFLICT|a|b\n', 'a')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)['conflicts'], [{'a':'a', 'b':'b'}])
        for relation in ['CONFLICT|a|unknown', 'CONFLICT|a|a']:
            self.reject(manifest() + relation + '\n')
    def test_full_graph_and_recursive_dependencies(self):
        self.reject(manifest() + 'DEPENDS|b|c\nDEPENDS|c|b\n', 'a', 'Цикл')
        r = self.plan(manifest() + 'DEPENDS|a|b\nDEPENDS|a|c\nDEPENDS|b|c\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([x['id'] for x in json.loads(r.stdout)['components']], ['a','b','c'])
    def test_validate_only_accepts_conflicting_catalog(self):
        r = self.plan(manifest() + 'CONFLICT|a|b\n', '', validate=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, '')
    def test_removed_order(self):
        old = ''.join(f'FILE|a|{name}|/opt/etc/mihomo-speedtest/{name}|1|{SHA}|0644|none\n'
                      for name in ['z','b','y','c'])
        r = self.plan(manifest(), installed=old); self.assertEqual(r.returncode, 0, r.stderr)
        removed = [x['dest'] for x in json.loads(r.stdout)['files'] if x['state']=='removed']
        self.assertEqual(removed, ['/opt/etc/mihomo-speedtest/b','/opt/etc/mihomo-speedtest/c','/opt/etc/mihomo-speedtest/y','/opt/etc/mihomo-speedtest/z'])
    def test_cli_strict_check_and_minimum(self):
        for mode in ['--check', '--plan']:
            with self.subTest(mode=mode):
                r = self.cli(manifest() + 'UNKNOWN|a|x\n', mode)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                r = self.cli(manifest(minimum=9), mode)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('Обновите update.sh', r.stderr)
                self.assertIn('release/manifest-format.md', r.stderr)
        r = self.cli(manifest(), '--check'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('v9', r.stdout)
    def test_no_hashing_invalid_paths_and_cleanup(self):
        # Без ранней валидации CLI прочитает существующий файл вне /opt.
        secret = self.dir / 'outside'; secret.write_text('private')
        bindir = self.dir / 'bin'; bindir.mkdir()
        spy = bindir / 'sha256sum'
        spy.write_text('#!/bin/sh\nprintf touched > "$HASH_LOG"\nprintf "%s  file\\n" "' + SHA + '"\n'); spy.chmod(0o755)
        log = self.dir / 'hash-log'
        saved = dict(os.environ)
        try:
            os.environ.update(PATH=str(bindir) + ':' + os.environ['PATH'], HASH_LOG=str(log))
            r = self.cli(manifest().replace('/opt/etc/mihomo-speedtest/a.sh', str(secret)), '--plan')
        finally:
            os.environ.clear(); os.environ.update(saved)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(log.exists(), 'CLI прочитал невалидное назначение до валидации')
        self.assertEqual(list(self.dir.glob('mst-update-*')), [])
    def test_validate_only_checks_selected_ids(self):
        r = self.plan(manifest(), 'unknown', validate=True)
        self.assertNotEqual(r.returncode, 0)
        r = self.plan(manifest() + 'CONFLICT|a|b\n', 'a,b', validate=True)
        self.assertNotEqual(r.returncode, 0)
        r = self.cli(manifest() + 'CONFLICT|a|b\n', '--check', '--components=a,b')
        self.assertNotEqual(r.returncode, 0)
        r = self.cli(manifest(), '--check', '--components=a,,b')
        self.assertNotEqual(r.returncode, 0)

    def test_generator_and_component_actions(self):
        r = subprocess.run(['sh', str(ROOT/'release/generate_manifest.sh'), '9','2','1','v9.0'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('FORMAT_VERSION=2\n', r.stdout)
        self.assertIn('RELEASE_TAG=v9.0\n', r.stdout)
        plan = self.plan(r.stdout, 'speedtest-runtime'); self.assertEqual(plan.returncode, 0, plan.stderr)
        self.assertEqual(json.loads(plan.stdout)['actions'], [])
        self.assertIn('FILE|installer|uninstall.sh|', r.stdout)
        self.assertNotIn('|VERSIONS|', r.stdout)
        self.assertIn('NOTE|web|', r.stdout)
    def test_generator_preserves_conflicts_and_extra_field_errors(self):
        declaration = self.dir/'components.txt'
        declaration.write_text('COMPONENT|a|A\nCOMPONENT|b|B\nNOTE|a|A\nNOTE|b|B\nCONFLICT|a|b\n')
        env = dict(os.environ, COMPONENTS=str(declaration))
        def generate():
            return subprocess.run(['sh', str(ROOT/'release/generate_manifest.sh'), '9','2','1'], env=env, capture_output=True, text=True)
        r = generate(); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('CONFLICT|a|b\n', r.stdout)
        valid = declaration.read_text()
        for bad in ['COMPONENT|c|C|discarded', 'COMPONENT|c|C|', 'FILE|a|../outside|/opt/etc/mihomo-speedtest/f|0644|none']:
            declaration.write_text(valid + bad + '\n')
            r = generate(); self.assertNotEqual(r.returncode, 0); self.assertEqual(r.stdout, '')
    def test_installer_complete_components_with_modes(self):
        dest = self.dir/'opt'; dest.mkdir(); init = self.dir/'init'; init.mkdir()
        # SELFDIR на роутере всегда плоский (см. Глобальные ограничения плана
        # реорганизации репозитория) - install_files() копирует всё project
        # из одного плоского каталога; в репозитории теперь компонентные
        # подпапки, поэтому здесь собирается временная плоская копия.
        selfdir = self.dir/'selfdir_flat'; selfdir.mkdir()
        for base in (ROOT, ROOT/'updater', ROOT/'speedtest-runtime', ROOT/'web', ROOT/'installer', ROOT/'config-tools'):
            for p in base.iterdir():
                if p.is_file(): (selfdir/p.name).write_bytes(p.read_bytes())
        env = dict(os.environ, SELFDIR=str(selfdir), DIR=str(dest), INSTALL_LIB_ONLY='1',
            STATS_SERVICE_DEST=str(dest/'stats_service.sh'), INITD_DIR=str(init), INITD_SCRIPT=str(init/'S80speedtest-stats'))
        r = subprocess.run(['sh','-c','. "$1"; install_files', 'sh', str(ROOT/'install.sh')], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in ['install.sh','version_check.sh','setup.sh','detect_ua.sh','update.sh','update_prepare.sh','update_transaction.sh','uninstall.sh']:
            with self.subTest(name=name):
                self.assertTrue((dest/name).is_file(), name)
                self.assertEqual((dest/name).stat().st_mode & 0o777, 0o755)
        comp_of = {'existing_config.awk':'config-tools','render_config.awk':'config-tools',
                   'providers.awk':'speedtest-runtime','update_plan.awk':'updater',
                   'config.example.yaml':'config-tools'}
        for name in ['existing_config.awk','render_config.awk','providers.awk','update_plan.awk','config.example.yaml']:
            self.assertTrue((dest/name).is_file(), name)
            self.assertEqual((dest/name).read_bytes(), (ROOT/comp_of[name]/name).read_bytes())

unittest.main(argv=['test_update_metadata'], verbosity=2)
PY
