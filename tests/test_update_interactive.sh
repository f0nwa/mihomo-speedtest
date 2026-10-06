#!/bin/sh
# Диалог через настоящий псевдотерминал; обновлятор заменён локальной фикстурой.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json, os, pathlib, pty, select, subprocess, sys, tempfile, time, unittest
ROOT=pathlib.Path(sys.argv[1])
class Interactive(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir='/tmp');self.addCleanup(self.tmp.cleanup)
  self.d=pathlib.Path(self.tmp.name);(self.d/'tmp').mkdir();(self.d/'.update').mkdir()
  (self.d/'.update/installed-manifest.txt').write_text('RELEASE_TAG=1.5.1\nRELEASE_VERSION=42\n')
  self.plan={'release_tag':'1.5.3','release_version':'44','plan_id':'a'*64,'prepared':False,'overwrite_required':False,'config_schema_version':'3','config_migration':{'required':False,'confirmation_required':False,'old_schema':'3'},'files':[{'dest':'/opt/etc/mihomo-speedtest/a.sh','component':'web','state':'new'}],'components':[{'id':'updater'},{'id':'web'},{'id':'config-tools'}],'actions':['restart-web']}
  (self.d/'update.sh').write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$DIR/calls"
exec python3 "$DIR/fake.py" "$@"
''')
  (self.d/'fake.py').write_text('''import json,os,sys,pathlib
p=pathlib.Path(os.environ['DIR']);a=sys.argv[1:] or ['--plan'];d=json.loads((p/'plan').read_text())
if (p/'fail').exists() and a[0]==(p/'fail').read_text(): print('ERROR: Проверка не пройдена',file=sys.stderr);sys.exit(1)
if a[0]=='--prepare':
 d['prepared']=True;d['plan_id']='b'*64
 if 'active-config' in ' '.join(a):d['config_migration']['confirmation_required']=True;d['actions'].append('restart-mihomo')
 if (p/'prepare-tag').exists(): d['release_tag']='1.5.4';d['release_version']='45'
if a[0] in ('--plan','--prepare'): print(json.dumps(d,separators=(',',':')))
elif a[0]=='--apply': print('{"ok":true}')
elif a[0]=='--show-config-diff': print('Группы и правила будут обновлены')
else: print('OK')
''')
  # Тест запускает диспетчер так же, как установленная команда.
  helper=ROOT/'installer/update_interactive.sh'
  if helper.exists(): (self.d/'update_interactive.sh').write_bytes(helper.read_bytes())
 def run_cli(self,answers='',args=(),tty=True):
  (self.d/'plan').write_text(json.dumps(self.plan,separators=(',',':')))
  env=dict(os.environ,DIR=str(self.d),TMPROOT=str(self.d/'tmp'),NO_COLOR='1',TERM='dumb')
  cmd=['sh',str(ROOT/'mihomo-speedtest.sh'),'update',*args]
  if not tty:
   r=subprocess.run(cmd,input=answers,text=True,capture_output=True,env=env,timeout=10);return r.returncode,r.stdout+r.stderr
  master,slave=pty.openpty()
  p=subprocess.Popen(cmd,stdin=slave,stdout=slave,stderr=slave,env=env);os.close(slave)
  os.write(master,answers.encode());out=b'';deadline=time.monotonic()+10
  try:
   while time.monotonic()<deadline:
    if select.select([master],[],[],.1)[0]:
     try: part=os.read(master,65536)
     except OSError: break
     if not part:break
     out+=part
    elif p.poll() is not None:break
   if p.poll() is None: p.wait(timeout=2)
  finally:
   if p.poll() is None:p.kill();p.wait()
   os.close(master)
  return p.returncode,out.decode(errors='replace')
 def calls(self):return (self.d/'calls').read_text() if (self.d/'calls').exists() else ''
 def test_happy_path(self):
  rc,out=self.run_cli('д\n');self.assertEqual(rc,0,out)
  self.assertIn('--prepare --format=json',self.calls());self.assertIn('--apply '+'b'*64,self.calls())
  self.assertNotIn('b'*64,out);self.assertNotIn('restart-web',out);self.assertIn('1.5.3',out)
  self.assertIn('перезапустится',out);self.assertEqual(list((self.d/'tmp').iterdir()),[])
 def test_cancel_before_download(self):
  rc,out=self.run_cli('н\n');self.assertEqual(rc,0,out);self.assertNotIn('--prepare',self.calls());self.assertNotIn('--apply',self.calls())
 def test_no_updates(self):
  self.plan['release_tag']='1.5.1';self.plan['release_version']='42';self.plan['files'][0]['state']='current'
  rc,out=self.run_cli();self.assertEqual(rc,0,out);self.assertIn('Обновлений нет',out);self.assertNotIn('--prepare',self.calls())
 def test_local_changes_declined(self):
  self.plan['overwrite_required']=True;self.plan['files'][0]['state']='modified'
  rc,out=self.run_cli('д\nн\n');self.assertEqual(rc,0,out);self.assertNotIn('--apply',self.calls());self.assertIn('--discard-plan '+'b'*64,self.calls())
 def test_local_changes_confirmed(self):
  self.plan['overwrite_required']=True;self.plan['files'][0]['state']='modified'
  rc,out=self.run_cli('д\nд\n');self.assertEqual(rc,0,out);self.assertIn('--confirm-local',self.calls());self.assertIn('/opt/etc/mihomo-speedtest/a.sh',out)
 def test_migration_optional_and_confirmed_after_diff(self):
  self.plan['config_schema_version']='4'
  rc,out=self.run_cli('д\nд\nд\n');self.assertEqual(rc,0,out)
  self.assertIn('active-config',self.calls());self.assertIn('--show-config-diff '+'b'*64,self.calls());self.assertIn('--confirm-config',self.calls())
  self.assertIn('Группы и правила',out);self.assertIn('XKeen',out)
 def test_migration_deferred(self):
  self.plan['config_schema_version']='4'
  rc,out=self.run_cli('д\nн\n');self.assertEqual(rc,0,out);self.assertNotIn('active-config',self.calls());self.assertIn('--apply',self.calls())
 def test_failure_does_not_apply(self):
  (self.d/'fail').write_text('--prepare')
  rc,out=self.run_cli('д\n');self.assertNotEqual(rc,0);self.assertNotIn('--apply',self.calls());self.assertIn('Проверка не пройдена',out);self.assertEqual(list((self.d/'tmp').iterdir()),[])
 def test_release_changed_requires_new_consent(self):
  (self.d/'prepare-tag').write_text('1')
  rc,out=self.run_cli('д\nн\n');self.assertEqual(rc,0,out);self.assertNotIn('--apply',self.calls());self.assertIn('1.5.4',out)
 def test_empty_answer_cancels(self):
  rc,out=self.run_cli('\n');self.assertEqual(rc,0,out);self.assertNotIn('--prepare',self.calls())
 def test_invalid_answer_repeats_question(self):
  rc,out=self.run_cli('что\nн\n');self.assertEqual(rc,0,out);self.assertIn('Введите д',out);self.assertNotIn('--apply',self.calls())
 def test_migration_declined_after_preview(self):
  self.plan['config_schema_version']='4'
  rc,out=self.run_cli('д\nд\nн\n');self.assertEqual(rc,0,out);self.assertNotIn('--apply',self.calls());self.assertIn('--discard-plan '+'b'*64,self.calls())
 def test_current_files_can_migrate_config(self):
  self.plan['release_tag']='1.5.1';self.plan['release_version']='42';self.plan['files'][0]['state']='current';self.plan['config_schema_version']='4'
  rc,out=self.run_cli('д\nд\nд\n');self.assertEqual(rc,0,out);self.assertIn('--confirm-config',self.calls())
 def test_apply_error_does_not_claim_success(self):
  (self.d/'fail').write_text('--apply')
  rc,out=self.run_cli('д\n');self.assertNotEqual(rc,0);self.assertNotIn('Готово.',out);self.assertEqual(list((self.d/'tmp').iterdir()),[])
 def test_flags_bypass_dialog(self):
  rc,out=self.run_cli(args=('--plan','--format=json'),tty=False);self.assertEqual(rc,0,out);self.assertEqual(json.loads(out)['release_tag'],'1.5.3');self.assertEqual(self.calls(),'--plan --format=json\n')
 def test_no_terminal_only_checks(self):
  rc,out=self.run_cli(tty=False);self.assertEqual(rc,0,out);self.assertEqual(self.calls(),'--check\n')
unittest.main(argv=['tests'],verbosity=2)
PY
