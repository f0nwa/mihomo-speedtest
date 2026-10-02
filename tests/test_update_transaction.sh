#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
# Не трогаем общие /tmp/mihomo-speedtest-*.
RT=$(mktemp -d "${TMPDIR:-/tmp}/update-tx-test.XXXXXX")
trap 'rm -rf "$RT"' EXIT INT TERM
export STATS_AUTH_RUNTIME_DIR="$RT/auth-runtime" STATS_UPDATE_RUNTIME_DIR="$RT/update-runtime"
python3 - "$ROOT" <<'PYTEST'
import pathlib,sys,unittest,json,hashlib,os,re,subprocess,time,importlib.util
ROOT=pathlib.Path(sys.argv[1])
fixture=(ROOT/'tests/test_update_prepare.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0].split("unittest.main(",1)[0]
exec(compile(fixture,'preparation_fixture','exec'))
# Модуль веб-авторизации импортируется напрямую (не через CLI - у stats_auth.py
# только initialize/reset), чтобы тесты могли независимо готовить/проверять
# auth-состояние (seed credentials, читать реальный setup-код и т.п.).
_stats_auth_spec=importlib.util.spec_from_file_location('stats_auth',str(ROOT/'web'/'stats_auth.py'))
stats_auth=importlib.util.module_from_spec(_stats_auth_spec)
_stats_auth_spec.loader.exec_module(stats_auth)
class Transaction(unittest.TestCase):
 setUp=Preparation.setUp
 add=Preparation.add
 release=Preparation.release
 cli=Preparation.cli
 prepare=Preparation.prepare
 snapshot=Preparation.snapshot
 clean=Preparation.clean
 def add_web(self):
  # web-компонент с настоящими stats_auth.py/stats_auth.sh (не заглушками) -
  # initialize_web_auth() в update.sh реально запускает python3 stats_auth.py,
  # поэтому фикстуре нужен рабочий модуль, а не однострочный маркер.
  self.add('web','stats_auth.py',(ROOT/'web'/'stats_auth.py').read_bytes(),'0644','py')
  self.add('web','stats_auth.sh',(ROOT/'web'/'stats_auth.sh').read_bytes(),'0755','sh')
  self.release()
  manifest=self.server/'manifest.txt'
  manifest.write_text(manifest.read_text().replace('COMPONENT|b|B\n','COMPONENT|b|B\nCOMPONENT|web|W\nNOTE|web|W\n'))
 def auth_dir(self):
  return self.target/'opt/etc/mihomo-speedtest/.stats-auth'
 def complete_web_setup(self,username='admin',password='change-me-12345'):
  # Имитирует оператора, завершившего /setup через веб-интерфейс - напрямую
  # через модуль (CLI stats_auth.py не имеет команды complete-setup).
  runtime=self.root/'stats-auth-runtime'
  runtime.mkdir(exist_ok=True)
  code=stats_auth.initialize_auth(str(self.auth_dir()),str(runtime))
  if code is None:
   code=stats_auth.reset_auth(str(self.auth_dir()),str(runtime))
  stats_auth.complete_setup(str(self.auth_dir()),code,username,password)
 def setUp(self):
  Preparation.setUp(self)
  if b'UPDATER_VERSION=4' in (ROOT/'updater'/'update.sh').read_bytes() and not any(e[1]=='update_transaction.sh' for e in self.entries):
   p=ROOT/'updater'/'update_transaction.sh';self.add('updater',p.name,p.read_bytes() if p.exists() else b'# missing\n','0755','sh');self.release()
 def apply(self,components='a',confirm=False):
  d,p=self.prepare(components)
  args=['--apply',d['plan_id'],'--format=json']
  if confirm:args+=['--confirm-local']
  return d,p,self.cli(*args)
 def old(self):
  self.state.mkdir(exist_ok=True)
  path=self.target/'opt/etc/mihomo-speedtest/a.sh';path.write_bytes(b'#!/bin/sh\nexit 7\n');path.chmod(0o755)
  text=(self.server/'manifest.txt').read_text().replace('RELEASE_VERSION=9','RELEASE_VERSION=8')
  row=self.entries[-2]
  # Сумма установленного a независимо вычислена по реальному старому файлу.
  text=text.replace('FILE|'+'|'.join(row), 'FILE|a|a.sh|/opt/etc/mihomo-speedtest/a.sh|'+str(path.stat().st_size)+'|'+hashlib.sha256(path.read_bytes()).hexdigest()+'|0755|sh')
  (self.state/'installed-manifest.txt').write_text(text)
  return path
 def test_apply_adds_file_and_tracks_only_installed_components(self):
  d,p,r=self.apply()
  self.assertEqual((self.target/'opt/etc/mihomo-speedtest/a.sh').read_bytes(),b'#!/bin/sh\nexit 0\n')
  self.assertEqual((self.target/'opt/etc/mihomo-speedtest/a.sh').stat().st_mode&0o777,0o755)
  installed=(self.state/'installed-manifest.txt').read_text()
  self.assertIn('FILE|a|a.sh|',installed);self.assertNotIn('FILE|b|',installed)
  self.assertFalse((self.state/'transaction.txt').exists())
  self.assertEqual(json.loads(r.stdout)['status'],'applied')
 def test_rollback_restores_replaced_file_and_manifest_offline(self):
  path=self.old();old_manifest=(self.state/'installed-manifest.txt').read_bytes()
  self.apply();self.env['UPDATE_HTTP_CMD']='/missing/transport'
  self.cli('--rollback-last')
  self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n')
  self.assertEqual((self.state/'installed-manifest.txt').read_bytes(),old_manifest)
 def test_rollback_removes_added_file(self):
  self.apply();self.cli('--rollback-last')
  self.assertFalse((self.target/'opt/etc/mihomo-speedtest/a.sh').exists())
  self.assertFalse((self.state/'installed-manifest.txt').exists())
 def test_local_changes_need_apply_confirmation(self):
  path=self.target/'opt/etc/mihomo-speedtest/a.sh';path.write_text('local\n');path.chmod(0o755)
  d,p=self.prepare();before=self.snapshot()
  self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before)
  self.cli('--apply',d['plan_id'],'--confirm-local')
  self.cli('--rollback-last');self.assertEqual(path.read_text(),'local\n')
 def test_apply_rejects_changed_plan_before_writes(self):
  d,p=self.prepare();(p/'files/1').write_text('corruption');before=self.snapshot()
  self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before)
 def test_partial_apply_preserves_unselected_installed_file(self):
  self.old();b=self.target/'opt/etc/mihomo-speedtest/b.txt';b.write_text('hello\n');b.chmod(0o644)
  self.apply();installed=(self.state/'installed-manifest.txt').read_text()
  self.assertIn('FILE|b|b.txt|',installed);self.assertEqual(b.read_text(),'hello\n')
 def test_web_first_install_is_rejected_before_writes(self):
  self.add('web','stats_mock.sh',b'#!/bin/sh\nexit 0\n','0755','sh');self.release()
  manifest=self.server/'manifest.txt';text=manifest.read_text().replace('COMPONENT|b|B\n','COMPONENT|b|B\nCOMPONENT|web|W\nNOTE|web|W\n')+'ACTION|web|restart-web\n';manifest.write_text(text)
  d,p=self.prepare('web');before=self.snapshot()
  self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before)
 def test_failed_chmod_or_rename_restores_original(self):
  for name in ['chmod','mv']:
   with self.subTest(name=name):
    if (self.root/'bin').exists():
     import shutil;shutil.rmtree(self.root/'bin')
    self.env['PATH']=os.environ['PATH'];path=self.old();d,p=self.prepare();old=(self.state/'installed-manifest.txt').read_bytes()
    bindir=self.root/'bin';bindir.mkdir();import shutil
    real=shutil.which(name);marker=self.root/('fault-'+name)
    suffix='*.mst-update-new' if name=='chmod' else '*/opt/etc/mihomo-speedtest/a.sh'
    body='#!/bin/sh\nfor arg do last=$arg; done\ncase "$last" in '+suffix+') if [ ! -e "'+str(marker)+'" ]; then touch "'+str(marker)+'"; exit 1; fi ;; esac\nexec "'+real+'" "$@"\n'
    wrapper=bindir/name;wrapper.write_text(body);wrapper.chmod(0o755);self.env['PATH']=str(bindir)+':'+os.environ['PATH']
    self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n');self.assertEqual((self.state/'installed-manifest.txt').read_bytes(),old)
 def test_no_space_apply_is_rejected_before_writes(self):
  self.old();d,p=self.prepare();before=self.snapshot()
  bindir=self.root/'bin';bindir.mkdir();df=bindir/'df'
  df.write_text('#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/mock 1 1 0 100%% /\\n"\n');df.chmod(0o755)
  self.env['PATH']=str(bindir)+':'+os.environ['PATH']
  self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before)
 def test_mixed_conflicts_rejected_in_both_orientations(self):
  self.old()
  for edge in ['a|b','b|a']:
   with self.subTest(edge=edge):
    self.release();manifest=self.server/'manifest.txt';manifest.write_text(manifest.read_text()+'CONFLICT|'+edge+'\n')
    d,p=self.prepare('a');before=self.snapshot()
    self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before)
 def test_web_actions_use_target_paths_even_with_exported_dir(self):
  self.add('web','stats_mock.sh',b'#!/bin/sh\nexit 0\n','0755','sh');self.release()
  manifest=self.server/'manifest.txt';manifest.write_text(manifest.read_text().replace('COMPONENT|b|B\n','COMPONENT|b|B\nCOMPONENT|web|W\nNOTE|web|W\n')+'ACTION|web|restart-web\n')
  init=self.target/'opt/etc/init.d/S80speedtest-stats';init.parent.mkdir(parents=True)
  init.write_text('#!/bin/sh\n[ -z "${UPDATE_VERIFIED_ENGINE_DIR:-}${UPDATE_VERIFIED_PLAN_ID:-}${UPDATE_RECOVERY_ENGINE_DIR:-}${UPDATE_BOOTSTRAP_DIR:-}${UPDATE_PINNED_MANIFEST:-}" ] || exit 91\n[ "$DIR" = "$EXPECTED_DIR" ] && [ "$SERVICE" = "$EXPECTED_DIR/stats_service.sh" ] && [ "$ENV" = "$EXPECTED_DIR/speedtest2.env" ] || exit 1\nexit 0\n')
  self.env['EXPECTED_DIR']=str(self.target/'opt/etc/mihomo-speedtest');self.env['DIR']='/wrong/exported/dir'
  self.apply('web')
 def test_web_apply_ignores_inherited_engine_markers(self):
  d,p=self.prepare()
  runtime=self.root/'web-update'
  env=dict(self.env, DIR=str(self.target/'opt/etc/mihomo-speedtest'),
   UPDATE_SCRIPT=str(ROOT/'updater/update.sh'), STATS_UPDATE_RUNTIME_DIR=str(runtime),
   UPDATE_VERIFIED_ENGINE_DIR='/tmp/old-engine', UPDATE_VERIFIED_PLAN_ID='0'*64,
   UPDATE_RECOVERY_ENGINE_DIR='/tmp/old-recovery', UPDATE_BOOTSTRAP_DIR='/tmp/old-bootstrap',
   UPDATE_PINNED_MANIFEST='/tmp/old-manifest')
  r=subprocess.run(['sh',str(ROOT/'web/stats_update.sh'),'apply-worker',d['plan_id'],'0','0'],env=env,capture_output=True,text=True)
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  job=json.loads((runtime/'job.json').read_text())
  self.assertEqual(job['state'],'done',job)
  self.assertEqual((self.target/'opt/etc/mihomo-speedtest/a.sh').read_bytes(),b'#!/bin/sh\nexit 0\n')
 def test_stale_lock_takeover_is_exclusive(self):
  d,p=self.prepare();lock=self.work/'mst-update-plans/.lock';lock.mkdir();(lock/'pid').write_text('99999999\n')
  bindir=self.root/'bin';bindir.mkdir();import shutil
  real=shutil.which('rm');wrapper=bindir/'rm'
  wrapper.write_text('#!/bin/sh\nfor arg do last=$arg; done\ncase "$last" in */.lock) marker="$FAULT_ROOT/reap-$LOCK_ROLE"; if [ ! -e "$marker" ]; then touch "$marker"; case $LOCK_ROLE in A) sleep 1 ;; B) sleep 2 ;; esac; fi ;; esac\nexec "'+real+'" "$@"\n');wrapper.chmod(0o755)
  self.env['PATH']=str(bindir)+':'+os.environ['PATH']
  fetch=self.root/'fetch';fetch.write_text(fetch.read_text().replace('u=sys.argv[1]','import time;time.sleep(4)\nu=sys.argv[1]'))
  args=['/bin/sh',str(ROOT/'updater'/'update.sh'),'--verify-plan',d['plan_id']]
  a=subprocess.Popen(args,env=dict(self.env,LOCK_ROLE='A',FAULT_ROOT=str(self.root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  b=subprocess.Popen(args,env=dict(self.env,LOCK_ROLE='B',FAULT_ROOT=str(self.root)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  outputs=[a.communicate(timeout=20),b.communicate(timeout=20)]
  self.assertEqual(sorted([a.returncode,b.returncode]),[0,1],str(outputs))
 def test_mode_validation_works_without_formatted_stat(self):
  bindir=self.root/'bin';bindir.mkdir();stat=bindir/'stat';stat.write_text('#!/bin/sh\nexit 1\n');stat.chmod(0o755)
  self.env['PATH']=str(bindir)+':'+os.environ['PATH']
  self.apply();self.cli('--rollback-last')
 def test_pending_journal_blocks_prepare(self):
  self.state.mkdir();(self.state/'transaction.txt').write_text('broken\n')
  before=self.snapshot();self.cli('--prepare','--components=a',ok=False);self.assertEqual(self.snapshot(),before)
 def test_all_commands_share_lock(self):
  d,p=self.prepare();lock=self.work/'mst-update-plans/.lock';lock.mkdir();(lock/'pid').write_text(str(os.getpid()))
  before=self.snapshot();self.cli('--apply',d['plan_id'],ok=False);self.assertEqual(self.snapshot(),before)
 def test_recover_without_journal_is_noop(self):
  before=self.snapshot();self.cli('--recover');self.assertEqual(self.snapshot(),before)
 # --- задача 3: инициализация веб-авторизации после управляемого обновления ---
 def test_apply_creates_setup_code_and_reports_it(self):
  self.add_web()
  d,p=self.prepare('web')
  r=self.cli('--apply',d['plan_id'])
  self.assertIn('Одноразовый код первичной настройки',r.stdout)
  self.assertIn('/setup',r.stdout)
  self.assertTrue((self.auth_dir()/'setup-code.sha256').is_file())
  self.assertFalse((self.auth_dir()/'credentials.json').exists())
 def test_apply_with_existing_credentials_does_not_recreate_code(self):
  self.add_web()
  self.complete_web_setup()
  creds_before=(self.auth_dir()/'credentials.json').read_bytes()
  d,p=self.prepare('web')
  r=self.cli('--apply',d['plan_id'])
  self.assertNotIn('Одноразовый код',r.stdout)
  self.assertEqual((self.auth_dir()/'credentials.json').read_bytes(),creds_before)
  self.assertFalse((self.auth_dir()/'setup-code.sha256').exists())
 def test_failed_apply_never_initializes_auth(self):
  self.add_web()
  d,p=self.prepare('web')
  bindir=self.root/'bin';bindir.mkdir()
  df=bindir/'df'
  df.write_text('#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/mock 1 1 0 100%% /\\n"\n');df.chmod(0o755)
  self.env['PATH']=str(bindir)+':'+os.environ['PATH']
  r=self.cli('--apply',d['plan_id'],ok=False)
  self.assertNotIn('Одноразовый код',r.stdout)
  self.assertNotIn('.stats-auth',r.stdout+r.stderr)
  self.assertFalse(self.auth_dir().exists())
  self.assertFalse((self.target/'opt/etc/mihomo-speedtest/stats_auth.py').exists())
 def test_legacy_install_gets_auth_on_first_web_apply(self):
  # Существующая установка "старой" версии (обновлялась и раньше, но без
  # web-компонента - веб-авторизация ещё не появлялась в манифесте) -
  # первое появление auth на уже настроенной системе должно пройти успешно.
  self.add_web()
  self.state.mkdir(exist_ok=True)
  legacy=(f'FORMAT_VERSION=2\nRELEASE_VERSION=8\nRELEASE_TAG=v8\nMIN_UPDATER_VERSION=3\n'
   f'CONFIG_SCHEMA_VERSION=1\nCOMPONENT|updater|U\nCOMPONENT|a|A\nCOMPONENT|b|B\n'
   f'NOTE|updater|U\nNOTE|a|A\nNOTE|b|B\n')
  for row in self.entries:
   if row[0] in ('updater','a','b'):legacy+='FILE|'+'|'.join(row)+'\n'
  (self.state/'installed-manifest.txt').write_text(legacy)
  d,p=self.prepare('a,web')
  r=self.cli('--apply',d['plan_id'])
  self.assertIn('Одноразовый код первичной настройки',r.stdout)
  self.assertTrue((self.auth_dir()/'setup-code.sha256').is_file())
 def test_repeated_apply_after_setup_completed_is_idempotent(self):
  self.add_web()
  d,p=self.prepare('web')
  r1=self.cli('--apply',d['plan_id'])
  m=re.search('настройки: (\\S+)',r1.stdout)
  self.assertIsNotNone(m,r1.stdout)
  runtime=self.root/'stats-auth-runtime';runtime.mkdir(exist_ok=True)
  stats_auth.complete_setup(str(self.auth_dir()),m.group(1),'admin','change-me-12345')
  creds_before=(self.auth_dir()/'credentials.json').read_bytes()
  d2,p2=self.prepare('web')
  r2=self.cli('--apply',d2['plan_id'])
  self.assertNotIn('Одноразовый код',r2.stdout)
  self.assertEqual((self.auth_dir()/'credentials.json').read_bytes(),creds_before)
 def test_apply_progress_lines_per_file(self):
  # Пункт 1 фидбека по макету "Панель управления": мини консоль обновлений
  # (job.log = stderr этого процесса) должна показывать реальный
  # построчный прогресс записи файлов при apply, а не только общие
  # чекпоинты "Применение обновления...".
  d,p,r=self.apply()
  self.assertIn('/opt/etc/mihomo-speedtest/a.sh',r.stderr)

result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Transaction))
sys.exit(not result.wasSuccessful())
PYTEST
