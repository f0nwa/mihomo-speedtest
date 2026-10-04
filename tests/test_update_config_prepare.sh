#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib,sys,unittest,json,hashlib,os,subprocess,tempfile,stat,re
ROOT=pathlib.Path(sys.argv[1])
fixture=(ROOT/'tests/test_update_prepare.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0].split('unittest.main(',1)[0]
exec(compile(fixture,'preparation_fixture','exec'))
class ConfigPreparation(unittest.TestCase):
 add=Preparation.add;cli=Preparation.cli;clean=Preparation.clean;snapshot=Preparation.snapshot
 def setUp(self):
  # Production migrator intentionally requires /tmp even on macOS.
  original=tempfile.tempdir;tempfile.tempdir='/tmp'
  try:Preparation.setUp(self)
  finally:tempfile.tempdir=original
  self.config=self.target/'opt/etc/mihomo/config.yaml';self.config.write_text((ROOT/'config-tools'/'config.example.yaml').read_text()+'secret: "VERY_PRIVATE_SECRET"\n')
  for name in ['migrate_config.sh','migrate_config.awk','fast_wg.awk','config_diff.awk','config.example.yaml']:
   p=ROOT/'config-tools'/name;self.add('config-tools',name,p.read_bytes() if p.exists() else b'# not implemented\n','0755' if name.endswith('.sh') else '0644','sh' if name.endswith('.sh') else 'awk' if name.endswith('.awk') else 'none')
  self.binary=self.root/'mihomo';self.binary.write_text('#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -d) shift; dir=$1 ;; -f) shift; config=$1 ;; esac; shift; done\ncase "$dir" in /tmp/*|/private/tmp/*) ;; *) exit 9 ;; esac\nprintf "%s\\n" "$dir" >> "$MIHOMO_CALLS"\n[ -z "${SAFE_PATHS:-}" ] && [ "${SKIP_SAFE_PATH_CHECK:-false}" != true ] || exit 8\n[ "$MIHOMO_FAIL" = 0 ] || { echo VERY_PRIVATE_SECRET >&2; exit 7; }\nprintf checked > "$dir/cache.db"\n');self.binary.chmod(0o755)
  self.calls=self.root/'mihomo-calls';self.env.update(UPDATE_MIHOMO_BIN=str(self.binary),MIHOMO_CALLS=str(self.calls),MIHOMO_FAIL='0',SAFE_PATHS='/opt',SKIP_SAFE_PATH_CHECK='true')
  self.release()
 def release(self,schema=2):
  Preparation.release(self,schema=schema)
  m=self.server/'manifest.txt';m.write_text(m.read_text().replace('COMPONENT|b|B\n','COMPONENT|b|B\nCOMPONENT|config-tools|C\nNOTE|config-tools|C\n'))
 def prepare(self):
  d=json.loads(self.cli('--prepare','--components=a','--format=json').stdout);return d,self.work/'mst-update-plans'/d['plan_id']
 def confirmed(self,id):return self.cli('--verify-plan',id,'--confirm-config','--format=json')
 def test_schema_upgrade_adds_virtual_and_verified_tools(self):
  before=self.snapshot();d,p=self.prepare();self.assertIn('active-config',[c['id'] for c in d['components']]);self.assertIn('config-tools',[c['id'] for c in d['components']]);self.assertTrue(d['config_migration']['confirmation_required']);self.assertEqual(self.snapshot(),before)
  self.assertTrue(self.calls.exists());self.assertNotIn('VERY_PRIVATE_SECRET',json.dumps(d));self.confirmed(d['plan_id']);self.assertEqual(self.snapshot(),before)
 def test_confirm_config_is_separate(self):
  d,p=self.prepare();self.cli('--verify-plan',d['plan_id'],ok=False);self.cli('--verify-plan',d['plan_id'],'--confirm-local',ok=False);self.confirmed(d['plan_id'])
 def test_known_hash_and_no_review_does_not_need_confirmation(self):
  self.config.write_text(re.sub(r'(?ms)^geox-url:.*?(?=^[A-Za-z0-9_-]+:|\Z)', '', self.config.read_text()))
  self.state.mkdir();(self.state/'config-sha256').write_text(hashlib.sha256(self.config.read_bytes()).hexdigest()+'\n');d,p=self.prepare();self.assertFalse(d['config_migration']['confirmation_required']);self.cli('--verify-plan',d['plan_id'])
 def test_review_always_requires_confirmation(self):
  self.state.mkdir();self.config.write_text(self.config.read_text()+'tun: {enable: true}\n');(self.state/'config-sha256').write_text(hashlib.sha256(self.config.read_bytes()).hexdigest()+'\n');d,p=self.prepare();self.assertTrue(d['config_migration']['confirmation_required'])
 def test_mihomo_failure_no_persistent_writes_or_secret_output(self):
  before=self.snapshot();self.env['MIHOMO_FAIL']='1';r=self.cli('--prepare','--components=a',ok=False);self.assertNotIn('VERY_PRIVATE_SECRET',r.stdout+r.stderr);self.assertEqual(self.snapshot(),before);self.clean()
 def test_saved_migration_artifacts_cannot_change(self):
  for name in ['candidate.yaml','migration-report.txt','config-diff.json','config-source.yaml','config-info.txt']:
   with self.subTest(name=name):
    d,p=self.prepare();(p/name).write_text('CORRUPTED');before=self.snapshot();self.cli('--verify-plan',d['plan_id'],'--confirm-config',ok=False);self.assertEqual(self.snapshot(),before)
 def test_migration_tool_payload_rechecked(self):
  d,p=self.prepare();record=(p/'records').read_text().splitlines();n=0
  for line in record:
   if line.startswith('FILE|'):
    n+=1
    if '|migrate_config.sh|' in line:(p/'files'/str(n)).write_text('#!/bin/sh\necho UNSAFE\n')
  r=self.cli('--verify-plan',d['plan_id'],'--confirm-config',ok=False);self.assertNotIn('UNSAFE',r.stdout)
 def test_config_diff_before_confirmation_and_full_opt_in(self):
  d,p=self.prepare();r=self.cli('--show-config-diff',d['plan_id'],'--format=json');json.loads(r.stdout);self.assertNotIn('VERY_PRIVATE_SECRET',r.stdout+r.stderr)
  self.cli('--show-config-diff',d['plan_id'],'--full-config-diff')
 def test_live_config_and_schema_changes_reject_id(self):
  d,p=self.prepare();self.config.write_text(self.config.read_text()+'# edited\n');self.cli('--verify-plan',d['plan_id'],'--confirm-config',ok=False)
  d,p=self.prepare();self.state.mkdir(exist_ok=True);(self.state/'config-schema-version').write_text('2\n');self.cli('--verify-plan',d['plan_id'],'--confirm-config',ok=False)
 def test_apply_without_xkeen_stops_before_writes(self):
  d,p=self.prepare();before=self.snapshot();r=self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertNotEqual(r.returncode,0);self.assertEqual(self.snapshot(),before)
 def test_full_diff_rejects_json_format(self):
  d,p=self.prepare();self.cli('--show-config-diff',d['plan_id'],'--full-config-diff','--format=json',ok=False)
 def test_config_test_timeout_is_bounded(self):
  self.binary.write_text('#!/bin/sh\nexec sleep 10\n');self.env['UPDATE_CONFIG_TEST_TIMEOUT']='1';before=self.snapshot();import time
  start=time.monotonic();self.cli('--prepare','--components=a',ok=False);self.assertLess(time.monotonic()-start,15);self.assertEqual(self.snapshot(),before);self.clean()
 def test_live_config_change_during_test_rejects_preparation(self):
  self.env['LIVE_CONFIG']=str(self.config);self.binary.write_text('#!/bin/sh\necho "# concurrent edit" >> "$LIVE_CONFIG"\n')
  r=self.cli('--prepare','--components=a',ok=False);self.assertIn('состояние изменилось',r.stderr);self.clean()
 def test_candidate_changed_by_test_is_rejected(self):
  self.binary.write_text('#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -f) shift; file=$1 ;; esac; shift; done\necho changed >> "$file"\n')
  self.cli('--prepare','--components=a',ok=False);self.clean()
 def test_copied_source_must_match_snapshot(self):
  wrapper=self.root/'bin';wrapper.mkdir();realcp=shutil.which('cp')
  script=wrapper/'cp';script.write_text('#!/bin/sh\n'+realcp+' "$@" || exit $?\nfor dest do :; done\ncase "$dest" in */config-source.yaml) printf "# wrong copy\\n" >> "$dest" ;; esac\n');script.chmod(0o755)
  self.env['PATH']=str(wrapper)+os.pathsep+self.env['PATH'];before=self.snapshot();self.cli('--prepare','--components=a',ok=False);self.assertEqual(self.snapshot(),before);self.clean()
 def test_schema_downgrade_rejected(self):
  self.state.mkdir();(self.state/'config-schema-version').write_text('3\n');self.cli('--prepare','--components=a',ok=False)
 # --- Служебный вход mst-speedtest (замер WG через основное ядро): порт 7896 ---
 def without_listener(self):
  a=self.config.read_text();start=a.index('# --- Входы ---');end=a.index('# --- НАСТРОЙКИ GEO-ДАННЫХ ---');self.config.write_text(a[:start]+a[end:])
 def netstat(self,line):
  b=self.root/'nsbin';b.mkdir(exist_ok=True);(b/'netstat').write_text('#!/bin/sh\nprintf "%s\\n" "Proto Recv-Q Send-Q Local Address Foreign Address State" "'+line+'"\n');(b/'netstat').chmod(0o755)
  self.env['PATH']=str(b)+os.pathsep+os.environ['PATH']
 def test_busy_service_port_rejects_first_listener(self):
  self.without_listener();self.netstat('tcp 0 0 0.0.0.0:7896 0.0.0.0:* LISTEN');before=self.snapshot()
  r=self.cli('--prepare','--components=a',ok=False);self.assertIn('7896',r.stderr);self.assertEqual(self.snapshot(),before);self.clean()
 def test_free_service_port_allows_first_listener(self):
  self.without_listener();self.netstat('tcp 0 0 0.0.0.0:17896 0.0.0.0:* LISTEN');d,p=self.prepare()
  self.assertIn('  - name: mst-speedtest\n',(p/'candidate.yaml').read_text())
 def test_existing_listener_skips_port_check(self):
  # Вход уже есть - порт 7896 держит само ядро, это не конфликт.
  self.netstat('tcp 0 0 127.0.0.1:7896 0.0.0.0:* LISTEN');self.prepare()
result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ConfigPreparation));sys.exit(not result.wasSuccessful())
PY
