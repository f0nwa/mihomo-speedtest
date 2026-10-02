#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib,sys,unittest,json,hashlib,os,subprocess,tempfile,stat,re,time,shutil
ROOT=pathlib.Path(sys.argv[1])
fixture=(ROOT/'tests/test_update_config_prepare.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0].split('result=unittest.TextTestRunner',1)[0]
exec(compile(fixture,'config_fixture','exec'))
class ConfigApply(ConfigPreparation):
 def setUp(self):
  super().setUp();self.original=self.config.read_bytes();self.config.chmod(0o640)
  self.state.mkdir();(self.state/'config-schema-version').write_text('1\n');(self.state/'config-sha256').write_text(hashlib.sha256(self.original).hexdigest()+'\n')
  self.actionlog=self.root/'actions';self.env.update(ACTION_LOG=str(self.actionlog),LIVE_CONFIG=str(self.config),LIVE_SCHEMA=str(self.state/'config-schema-version'),FAULT_MARKER=str(self.root/'fault'),FAIL_ACTION='none',UPDATE_ACTION_TIMEOUT='3',UPDATE_HEALTH_TIMEOUT='2')
  for action,var in [('restart','UPDATE_XKEEN_BIN'),('health','UPDATE_HEALTH_CMD')]:
   script=self.root/action
   script.write_text('#!'+sys.executable+'\n'+'''import os,sys,pathlib,hashlib,json,time,signal
kind=pathlib.Path(sys.argv[0]).name
if kind=='restart' and sys.argv[1:]!=['-restart']:sys.exit(9)
row={'action':kind,'hash':hashlib.sha256(pathlib.Path(os.environ['LIVE_CONFIG']).read_bytes()).hexdigest(),'schema':pathlib.Path(os.environ['LIVE_SCHEMA']).read_text() if pathlib.Path(os.environ['LIVE_SCHEMA']).exists() else None}
with open(os.environ['ACTION_LOG'],'a') as f:f.write(json.dumps(row)+'\\n')
marker=pathlib.Path(os.environ['FAULT_MARKER'])
if os.environ['FAIL_ACTION']==kind+'-always':sys.exit(7)
if os.environ['FAIL_ACTION']==kind and not marker.exists():marker.touch();print('VERY_PRIVATE_SECRET',file=sys.stderr);sys.exit(7)
if os.environ['FAIL_ACTION']==kind+'-timeout-success' and not marker.exists():signal.signal(signal.SIGTERM,lambda *_:sys.exit(0));marker.touch();time.sleep(20)
if os.environ['FAIL_ACTION']==kind+'-timeout' and not marker.exists():marker.touch();time.sleep(20)
''');script.chmod(0o755);self.env[var]=str(script)
 def actions(self):return [json.loads(s) for s in self.actionlog.read_text().splitlines()] if self.actionlog.exists() else []
 def applied(self):
  d,p=self.prepare();candidate=(p/'candidate.yaml').read_bytes();self.cli('--apply',d['plan_id'],'--confirm-config','--format=json');return d,p,candidate
 def wrapper(self,name,body):
  directory=self.root/'bin';directory.mkdir(exist_ok=True);real=shutil.which(name)
  script=directory/name;script.write_text('#!/bin/sh\nreal="'+real+'"\n'+body);script.chmod(0o755);self.env['PATH']=str(directory)+os.pathsep+os.environ['PATH']
 def restored(self):
  self.assertEqual(self.config.read_bytes(),self.original);self.assertEqual(stat.S_IMODE(self.config.stat().st_mode),0o640)
  self.assertEqual((self.state/'config-schema-version').read_text(),'1\n','schema');self.assertEqual((self.state/'config-sha256').read_text(),hashlib.sha256(self.original).hexdigest()+'\n','hash');self.assertFalse((self.state/'transaction.txt').exists(),'journal')
 def test_apply_publishes_config_metadata_before_one_restart(self):
  d,p,candidate=self.applied();self.assertEqual(self.config.read_bytes(),candidate);self.assertEqual(stat.S_IMODE(self.config.stat().st_mode),0o640)
  expected=hashlib.sha256(candidate).hexdigest();self.assertEqual((self.state/'config-schema-version').read_text(),'2\n');self.assertEqual((self.state/'config-sha256').read_text(),expected+'\n');self.assertEqual(stat.S_IMODE((self.state/'config-sha256').stat().st_mode),0o600)
  self.assertEqual([r['action'] for r in self.actions()],['restart','health']);self.assertTrue(all(r['hash']==expected and r['schema']=='2\n' for r in self.actions()))
  self.assertFalse((self.state/'transaction.txt').exists());self.assertTrue((self.state/'rollback').is_dir())
 def test_apply_requires_confirmation_without_writes(self):
  d,p=self.prepare();before=self.snapshot();self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before);self.assertEqual(self.actions(),[])
 def test_manual_rollback_restores_mode_metadata_and_restarts_once(self):
  self.applied();self.env['UPDATE_HTTP_CMD']='/no-network';self.cli('--rollback-last');self.restored();self.assertEqual([r['action'] for r in self.actions()],['restart','health','restart','health']);self.assertEqual(self.actions()[-1]['hash'],hashlib.sha256(self.original).hexdigest())
 def test_missing_original_metadata_removed_on_rollback(self):
  (self.state/'config-schema-version').unlink();(self.state/'config-sha256').unlink();self.applied();self.cli('--rollback-last');self.assertEqual(self.config.read_bytes(),self.original);self.assertFalse((self.state/'config-schema-version').exists());self.assertFalse((self.state/'config-sha256').exists())
 def test_restart_failure_rolls_back_whole_plan_without_secret_output(self):
  d,p=self.prepare();self.env['FAIL_ACTION']='restart';r=self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertNotIn('VERY_PRIVATE_SECRET',r.stdout+r.stderr);self.restored();self.assertFalse((self.target/'opt/etc/mihomo/a.sh').exists());self.assertEqual([r['action'] for r in self.actions()],['restart','restart','health'])
 def test_health_failure_rolls_back_config_and_metadata(self):
  d,p=self.prepare();self.env['FAIL_ACTION']='health';self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.restored();self.assertEqual([r['action'] for r in self.actions()],['restart','health','restart','health'])
 def test_publication_failure_restores_config_before_restart(self):
  d,p=self.prepare();self.wrapper('mv','for arg do last=$arg; done\ncase "$last" in */.update/config-schema-version) if [ ! -e "$FAULT_MARKER" ]; then touch "$FAULT_MARKER"; exit 1; fi ;; esac\nexec "$real" "$@"\n');self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.restored();self.assertEqual([r['action'] for r in self.actions()],['restart','health']);self.assertTrue(all(r['hash']==hashlib.sha256(self.original).hexdigest() for r in self.actions()))
 def test_term_after_config_rename_restores_entire_plan(self):
  d,p=self.prepare();self.wrapper('mv','for arg do last=$arg; done\ncase "$last" in */opt/etc/mihomo/config.yaml) if [ ! -e "$FAULT_MARKER" ]; then "$real" "$@" || exit; touch "$FAULT_MARKER"; kill -TERM "$PPID"; exit 0; fi ;; esac\nexec "$real" "$@"\n');self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertTrue((self.root/'fault').exists());self.cli('--recover');self.restored()
 def test_kill_after_config_rename_can_recover_offline(self):
  d,p=self.prepare();self.wrapper('mv','for arg do last=$arg; done\ncase "$last" in */opt/etc/mihomo/config.yaml) if [ ! -e "$FAULT_MARKER" ]; then "$real" "$@" || exit; touch "$FAULT_MARKER"; kill -KILL "$PPID"; exit 1; fi ;; esac\nexec "$real" "$@"\n');self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertTrue((self.state/'transaction.txt').exists());self.env['UPDATE_HTTP_CMD']='/no-network';self.cli('--recover');self.restored();self.assertEqual([r['action'] for r in self.actions()],['restart','health'])
 def test_corrupt_config_backup_refuses_rollback_before_writes(self):
  self.applied();bundle=self.state/'rollback';records=(bundle/'list.txt').read_text().splitlines();record=next(r.split('|') for r in records if r.startswith('CONFIG|'));(bundle/'backups'/record[-1]).write_bytes(b'corrupt');before=self.snapshot();self.cli('--rollback-last',ok=False);self.assertEqual(self.snapshot(),before);self.assertEqual(len(self.actions()),2)
 def test_health_timeout_restores_old_config(self):
  d,p=self.prepare();self.env['FAIL_ACTION']='health-timeout';start=time.monotonic();self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertLess(time.monotonic()-start,15);self.assertTrue((self.root/'fault').exists());self.restored();self.assertEqual([r['action'] for r in self.actions()],['restart','health','restart','health'])
 def test_state_config_collision_refuses_before_writes(self):
  self.add('a','config-schema-version',b'2\n','0644','none');self.release();self.env['UPDATE_STATE_DIR']=str(self.target/'opt/etc/mihomo-speedtest');d,p=self.prepare();before=self.snapshot();self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertEqual(self.snapshot(),before)
 def test_failed_rollback_health_keeps_journal_and_can_retry_offline(self):
  d,p=self.prepare();self.env['FAIL_ACTION']='health-always';r=self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertEqual(r.returncode,2);self.assertTrue((self.state/'transaction.txt').exists());self.assertEqual(self.config.read_bytes(),self.original)
  self.env['FAIL_ACTION']='none';self.env['UPDATE_HTTP_CMD']='/no-network';self.cli('--recover');self.restored()
 def test_partial_config_copy_does_not_truncate_original(self):
  d,p=self.prepare();self.wrapper('cp','for arg do last=$arg; done\ncase "$last" in */config.yaml.mst-update-new) if [ ! -e "$FAULT_MARKER" ]; then touch "$FAULT_MARKER"; : > "$last"; exit 1; fi ;; esac\nexec "$real" "$@"\n');self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertTrue((self.root/'fault').exists());self.restored();self.assertFalse((self.config.parent/'config.yaml.mst-update-new').exists())
 def test_kill_during_commit_promotion_keeps_verified_config(self):
  d,p=self.prepare();candidate=(p/'candidate.yaml').read_bytes();self.wrapper('mv','for arg do last=$arg; done\ncase "$last" in */.update/rollback) if [ ! -e "$FAULT_MARKER" ]; then "$real" "$@" || exit; touch "$FAULT_MARKER"; kill -KILL "$PPID"; exit 1; fi ;; esac\nexec "$real" "$@"\n');self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertTrue((self.root/'fault').exists());self.env['UPDATE_HTTP_CMD']='/no-network';self.cli('--recover');self.assertEqual(self.config.read_bytes(),candidate);self.assertEqual((self.state/'config-schema-version').read_text(),'2\n');self.assertFalse((self.state/'transaction.txt').exists());self.assertEqual([r['action'] for r in self.actions()],['restart','health']);self.cli('--rollback-last');self.restored()
 def test_restart_timeout_exit_zero_still_rolls_back(self):
  d,p=self.prepare();self.env['FAIL_ACTION']='restart-timeout-success';result=self.cli('--apply',d['plan_id'],'--confirm-config',ok=False);self.assertTrue((self.root/'fault').exists());self.assertFalse((self.state/'transaction.txt').exists(),result.stderr);self.restored();self.assertEqual([r['action'] for r in self.actions()],['restart','restart','health'])
# Only the new application scenarios; preparation is tested separately.
names=[n for n in ConfigApply.__dict__ if n.startswith('test_')]
if os.environ.get('MST_TEST_NAMES'):names=os.environ['MST_TEST_NAMES'].split(',')
suite=unittest.TestSuite(ConfigApply(n) for n in names)
result=unittest.TextTestRunner(verbosity=2).run(suite);sys.exit(not result.wasSuccessful())
PY
