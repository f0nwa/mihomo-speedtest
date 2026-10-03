#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import hashlib, http.server, json, os, pathlib, shutil, ssl, stat, subprocess, sys, tempfile, threading, time, unittest
ROOT=pathlib.Path(sys.argv[1])
BASE='https://releases.test/demo/releases/latest/download'
PIN='https://releases.test/demo/releases/download/v9'

class Preparation(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
  self.root=pathlib.Path(self.tmp.name).resolve()
  self.target=self.root/'target'; (self.target/'opt/etc/mihomo').mkdir(parents=True); (self.target/'opt/etc/mihomo-speedtest').mkdir(parents=True)
  self.state=self.target/'opt/etc/mihomo/.update'
  self.work=self.root/'tmp'; self.work.mkdir()
  self.server=self.root/'server'; self.server.mkdir()
  self.log=self.root/'requests'
  self.bootlog=self.root/'boot'
  fetch=self.root/'fetch'
  fetch.write_text('#!'+sys.executable+'\n'+'''import os,pathlib,sys
u=sys.argv[1]
with open(os.environ['REQUESTS'],'a') as f:f.write(u+'\\n')
base=os.environ['SOURCE_BASE']
if u==base+'/manifest.txt':name='manifest.txt'
elif u.startswith(base.replace('/latest/download','/download/v9')+'/'):name=u.rsplit('/',1)[1]
else:sys.exit(22)
p=pathlib.Path(os.environ['SERVER'])/name
if not p.is_file():sys.exit(22)
sys.stdout.buffer.write(p.read_bytes())
'''); fetch.chmod(0o755)
  self.env=dict(os.environ, TMPROOT=str(self.work), UPDATE_TARGET_ROOT=str(self.target),
   UPDATE_STATE_DIR=str(self.state), UPDATE_RELEASE_BASE=BASE, UPDATE_HTTP_CMD=str(fetch),
   SERVER=str(self.server), REQUESTS=str(self.log), SOURCE_BASE=BASE, BOOT_LOG=str(self.bootlog))
  self.entries=[]
  for name in ['update.sh','update_plan.awk','update_prepare.sh','update_transaction.sh']:
   p=ROOT/'updater'/name
   data=p.read_bytes() if p.is_file() else b'# helper not implemented\n'
   if name=='update.sh':data=data.replace(b'UPDATER_VERSION=7',b'UPDATER_VERSION=7\nprintf fresh >> "$BOOT_LOG"')
   self.add('updater',name,data, '0755' if name.endswith('.sh') else '0644', 'sh' if name.endswith('.sh') else 'awk')
  self.add('a','a.sh',b'#!/bin/sh\nexit 0\n','0755','sh')
  self.add('b','b.txt',b'hello\n','0644','none')
  self.release()
 def add(self,cid,name,data,mode,check):
  (self.server/name).write_bytes(data)
  self.entries.append([cid,name,'/opt/etc/mihomo-speedtest/'+name,str(len(data)),hashlib.sha256(data).hexdigest(),mode,check])
 def release(self, minimum=3, schema=1, version=9):
  body=f'FORMAT_VERSION=2\nRELEASE_VERSION={version}\nRELEASE_TAG=v9\nMIN_UPDATER_VERSION={minimum}\nCONFIG_SCHEMA_VERSION={schema}\n'
  body+='COMPONENT|updater|U\nCOMPONENT|a|A\nCOMPONENT|b|B\nNOTE|updater|U\nNOTE|a|A\nNOTE|b|B\n'
  body+=''.join('FILE|'+'|'.join(row)+'\n' for row in self.entries)
  (self.server/'manifest.txt').write_text(body)
 def cli(self,*args,ok=True):
  r=subprocess.run(['/bin/sh',str(ROOT/'updater'/'update.sh'),*args],env=self.env,capture_output=True,text=True)
  if ok:self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  else:self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
  return r
 def prepare(self,components='a'):
  d=json.loads(self.cli('--prepare','--components='+components,'--format=json').stdout)
  self.assertRegex(d['plan_id'],r'^[0-9a-f]{64}$')
  self.assertTrue(d['prepared'])
  return d,self.work/'mst-update-plans'/d['plan_id']
 def clean(self):
  self.assertEqual(list(self.work.glob('mst-update-work.*')),[])
 def snapshot(self):
  return [(str(p.relative_to(self.target)),p.read_bytes(),stat.S_IMODE(p.stat().st_mode))
   for p in sorted(self.target.rglob('*')) if p.is_file()]
 def test_exact_release_bootstrap_and_no_target_writes(self):
  before=self.snapshot();d,p=self.prepare()
  urls=self.log.read_text().splitlines()
  self.assertEqual(urls[0],BASE+'/manifest.txt')
  self.assertEqual(set(urls[1:]),{PIN+'/'+x for x in ['update.sh','update_plan.awk','update_prepare.sh','update_transaction.sh','a.sh']})
  self.assertTrue(self.bootlog.is_file(),'Не запущен свежий update.sh')
  self.assertEqual(self.snapshot(),before)
  self.assertEqual([x['component'] for x in d['files']],['a'])
  self.assertEqual((p/'files/1').read_bytes(),b'#!/bin/sh\nexit 0\n')
  self.assertEqual(stat.S_IMODE((p/'files/1').stat().st_mode),0o755)
  self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o700)
  self.cli('--verify-plan',d['plan_id'],'--format=json');self.clean()
 def test_preview_id_and_canonical_selection(self):
  d1=json.loads(self.cli('--plan','--components=a,b','--format=json').stdout)
  d2=json.loads(self.cli('--plan','--components=b,a','--format=json').stdout)
  self.assertEqual(d1['plan_id'],d2['plan_id'])
  d,p=self.prepare('a,b');self.assertEqual(d1['plan_id'],d['plan_id'])
 def test_newer_bootstrap_also_verifies_plan(self):
  row=self.entries[0]
  data=(self.server/'update.sh').read_bytes().replace(b'UPDATER_VERSION=7',b'UPDATER_VERSION=8')
  (self.server/'update.sh').write_bytes(data);row[3]=str(len(data));row[4]=hashlib.sha256(data).hexdigest()
  self.release(minimum=8)
  d,p=self.prepare();self.cli('--verify-plan',d['plan_id'])
 def test_external_http_disguised_as_localhost_rejected(self):
  self.env['UPDATE_RELEASE_BASE']='http://localhost:password@example.com/demo/releases/latest/download'
  self.cli('--check',ok=False)
  self.assertFalse(self.log.exists(),'Начат запрос к внешнему HTTP-серверу')
 def test_https_redirect_cannot_downgrade_to_http(self):
  if not shutil.which('curl') or not shutil.which('openssl'):self.skipTest('curl/openssl недоступны')
  key=self.root/'key.pem';cert=self.root/'cert.pem';cfg=self.root/'ssl.conf'
  cfg.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\n')
  subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',str(key),'-out',str(cert),'-config',str(cfg)],capture_output=True,check=True)
  hits=[]
  body=(self.server/'manifest.txt').read_bytes()
  class Insecure(http.server.BaseHTTPRequestHandler):
   def do_GET(self):
    hits.append(self.path);self.send_response(200);self.end_headers();self.wfile.write(body)
   def log_message(self,*args):pass
  plain_server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Insecure)
  class Redirect(http.server.BaseHTTPRequestHandler):
   def do_GET(self):
    self.send_response(302);self.send_header('Location','http://localhost:'+str(plain_server.server_port)+self.path);self.end_headers()
   def log_message(self,*args):pass
  https=http.server.ThreadingHTTPServer(('127.0.0.1',0),Redirect)
  ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(str(cert),str(key))
  https.socket=ctx.wrap_socket(https.socket,server_side=True)
  for server in [plain_server,https]:
   thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
  self.env.pop('UPDATE_HTTP_CMD');self.env['UPDATE_RELEASE_BASE']='https://localhost:'+str(https.server_port)+'/demo/releases/latest/download'
  self.env['CURL_CA_BUNDLE']=str(cert)
  self.cli('--check',ok=False);self.assertEqual(hits,[])
 def test_three_file_bootstrap_rejected(self):
  # bootstrap версии 3 (без update_transaction.sh) в релизах не публиковался;
  # стабильный протокол принимает ровно четыре файла updater.
  self.entries=[row for row in self.entries if row[1]!='update_transaction.sh']
  self.release()
  r=self.cli('--prepare','--components=a','--format=json',ok=False)
  self.assertIn('Несовместимый bootstrap',r.stdout+r.stderr)
  self.assertFalse(self.bootlog.exists(),'Запущен свежий update.sh из неполного bootstrap')
 def test_check_only_manifest(self):
  self.cli('--check')
  self.assertEqual(self.log.read_text().splitlines(),[BASE+'/manifest.txt'])
  self.assertFalse((self.work/'mst-update-plans').exists())
 def test_changed_file_mode_config_and_manifest_invalidate(self):
  path=self.target/'opt/etc/mihomo-speedtest/a.sh';path.write_text('#!/bin/sh\nexit 0\n');path.chmod(0o755)
  d,p=self.prepare()
  path.chmod(0o644);self.cli('--verify-plan',d['plan_id'],ok=False);path.chmod(0o755)
  path.write_text('changed');self.cli('--verify-plan',d['plan_id'],ok=False)
  path.write_text('#!/bin/sh\nexit 0\n')
  config=self.target/'opt/etc/mihomo/config.yaml';config.write_text('secret: private')
  r=self.cli('--verify-plan',d['plan_id'],ok=False);self.assertNotIn('private',r.stdout+r.stderr)
  config.unlink()
  self.release(version=10);self.cli('--verify-plan',d['plan_id'],ok=False);self.clean()
 def test_payload_and_mode_tampering(self):
  d,p=self.prepare();f=p/'files/1';f.write_text('bad')
  self.cli('--verify-plan',d['plan_id'],ok=False)
  f.write_text('#!/bin/sh\nexit 0\n');f.chmod(0o644)
  self.cli('--verify-plan',d['plan_id'],ok=False)
 def test_corruption_size_sha_and_syntax_cleanup(self):
  entry=self.entries[-2]
  for data in [b'x',b'#!/bin/sh\nexit 1\n',b'#!/bin/sh\nif then\n']:
   with self.subTest(data=data):
    (self.server/'a.sh').write_bytes(data)
    if b'if then' in data:entry[3]=str(len(data));entry[4]=hashlib.sha256(data).hexdigest();self.release()
    self.cli('--prepare','--components=a',ok=False)
    self.clean();self.assertEqual(list((self.work/'mst-update-plans').glob('[0-9a-f]'*64)),[])
 def test_unsafe_bootstrap_and_minimum(self):
  for mutate in ['size','hash','missing','minimum']:
   with self.subTest(mutate=mutate):
    row=self.entries[0]; original=list(row)
    if mutate=='size':row[3]='1'
    if mutate=='hash':row[4]='a'*64
    if mutate=='missing':self.entries.remove(row)
    self.release(minimum=99 if mutate=='minimum' else 3)
    self.cli('--prepare','--components=a',ok=False);self.clean()
    if mutate=='missing':self.entries.insert(0,row)
    row[:]=original
 def test_symlink_and_nonregular_targets(self):
  target=self.target/'opt/etc/mihomo-speedtest/a.sh'
  outside=self.root/'outside';outside.write_text('secret')
  target.symlink_to(outside)
  self.cli('--prepare','--components=a',ok=False);target.unlink()
  target.mkdir();self.cli('--prepare','--components=a',ok=False);target.rmdir()
  parent=self.target/'opt/etc/mihomo-speedtest';saved=self.target/'opt/etc/mihomo-speedtest.saved';parent.rename(saved);parent.symlink_to(saved)
  self.cli('--prepare','--components=a',ok=False);self.clean()
 def test_local_changes_require_confirmation(self):
  path=self.target/'opt/etc/mihomo-speedtest/a.sh';path.write_text('local change');path.chmod(0o755)
  d,p=self.prepare();self.assertTrue(d['overwrite_required'])
  self.cli('--verify-plan',d['plan_id'],ok=False)
  self.cli('--verify-plan',d['plan_id'],'--confirm-local')
 def test_state_location_and_permissions_are_bound(self):
  d,p=self.prepare()
  self.env['UPDATE_STATE_DIR']=str(self.target/'opt/etc/mihomo/.other-update')
  self.cli('--verify-plan',d['plan_id'],ok=False)
  self.env['UPDATE_STATE_DIR']=str(self.state)
  path=self.target/'opt/etc/mihomo-speedtest/a.sh';path.write_text('#!/bin/sh\nexit 0\n');path.chmod(0o644)
  d,p=self.prepare();self.assertTrue(d['overwrite_required'])
  self.assertNotEqual(d['files'][0]['state'],'current')
  self.cli('--verify-plan',d['plan_id'],ok=False)
  self.cli('--verify-plan',d['plan_id'],'--confirm-local')
 def test_bootstrap_independent_of_installed_helpers(self):
  local=self.root/'old';local.mkdir()
  (local/'update.sh').write_bytes((ROOT/'updater'/'update.sh').read_bytes().replace(b'UPDATER_VERSION=7',b'UPDATER_VERSION=2'))
  r=subprocess.run(['/bin/sh',str(local/'update.sh'),'--prepare','--components=a','--format=json'],env=self.env,capture_output=True,text=True)
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertTrue(json.loads(r.stdout)['prepared'])
 def test_state_schema_metadata_blocks_migration(self):
  self.state.mkdir();(self.state/'config-schema-version').write_text('0\n')
  self.cli('--prepare','--components=a',ok=False)
 def test_prepare_huge_body_and_python_syntax_cleanup(self):
  # Хэш описывает маленький файл, транспорт отдаёт слишком много.
  (self.server/'a.sh').write_bytes(b'x'*600000)
  self.cli('--prepare','--components=a',ok=False);self.clean()
  (self.server/'a.sh').write_bytes(b'#!/bin/sh\nexit 0\n')
  self.add('a','invalid.py',b'if :\n','0644','py');self.release()
  self.cli('--prepare','--components=a',ok=False);self.clean()
  self.assertEqual(list(self.work.rglob('__pycache__')),[])
 def test_schema_and_downgrade_blocked(self):
  self.release(schema=2);self.cli('--prepare','--components=a',ok=False)
  self.state.mkdir();self.release(schema=1,version=10)
  (self.state/'installed-manifest.txt').write_bytes((self.server/'manifest.txt').read_bytes())
  self.release(version=9);self.cli('--prepare','--components=a',ok=False)
 def test_large_integer_release_downgrade(self):
  self.state.mkdir()
  self.release(version=10**40+1)
  (self.state/'installed-manifest.txt').write_bytes((self.server/'manifest.txt').read_bytes())
  self.release(version=10**40)
  self.cli('--prepare','--components=a',ok=False)
 def test_network_failure_and_limits(self):
  (self.server/'a.sh').unlink();self.cli('--prepare','--components=a',ok=False);self.clean()
  self.entries[-2][3]=str(8*1024*1024+1);self.release()
  self.cli('--prepare','--components=a',ok=False);self.clean()
 def test_expiry_discard_and_invalid_ids(self):
  d,p=self.prepare();(p/'created-at').write_text(str(int(time.time())-86401)+'\n')
  self.cli('--verify-plan',d['plan_id'],ok=False)
  self.cli('--discard-plan',d['plan_id']);self.assertFalse(p.exists())
  for bad in ['../outside','x','a'*63,'g'*64]:self.cli('--discard-plan',bad,ok=False)
 def test_no_sha_tool_and_no_space(self):
  bindir=self.root/'bin';bindir.mkdir()
  for name in ['awk','mktemp','dirname','cat','wc','rm','ls','stat','chmod','cp','mv','sort','cmp','date','sh','tr','mkdir','df']:
   p=shutil.which(name)
   if p:(bindir/name).symlink_to(p)
  saved=self.env['PATH'];self.env['PATH']=str(bindir)
  self.cli('--prepare','--components=a',ok=False);self.clean()
  self.env['PATH']=str(bindir)+':'+saved
  (bindir/'df').unlink();(bindir/'df').write_text('#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/mock 1 1 0 100%% /\\n"\n');(bindir/'df').chmod(0o755)
  self.cli('--prepare','--components=a',ok=False);self.clean()
 def test_awk_validation_never_executes_begin_or_end(self):
  marker=self.root/'awk-executed'
  data=('BEGIN { print "bad" > "'+str(marker)+'" }\nEND { print "bad" > "'+str(marker)+'" }\n').encode()
  self.add('a','guard.awk',data,'0644','awk');self.release()
  self.prepare();self.assertFalse(marker.exists())
 def test_removed_only_selected_component(self):
  self.state.mkdir()
  old=(self.server/'manifest.txt').read_text()
  old+='FILE|a|old-a|/opt/etc/mihomo-speedtest/old-a|1|'+'a'*64+'|0644|none\n'
  old+='FILE|b|old-b|/opt/etc/mihomo-speedtest/old-b|1|'+'a'*64+'|0644|none\n'
  (self.state/'installed-manifest.txt').write_text(old)
  d,p=self.prepare();removed=[f['dest'] for f in d['files'] if f['state']=='removed']
  self.assertEqual(removed,['/opt/etc/mihomo-speedtest/old-a'])
 def test_full_real_release(self):
  for base in (ROOT,ROOT/'updater',ROOT/'speedtest-runtime',ROOT/'web',ROOT/'installer',ROOT/'config-tools'):
   for p in base.iterdir():
    if p.is_file():(self.server/p.name).write_bytes(p.read_bytes())
  r=subprocess.run(['sh',str(ROOT/'release/generate_manifest.sh'),'9','3','1','v9'],capture_output=True,text=True)
  self.assertEqual(r.returncode,0,r.stderr)
  (self.server/'manifest.txt').write_text(r.stdout)
  d,p=self.prepare('updater,speedtest-runtime,web,installer,config-tools')
  self.assertIn('restart-web',d['actions'])
  self.cli('--verify-plan',d['plan_id'])


 def test_prepare_progress_lines_per_file(self):
  # Пункт 1 фидбека по макету "Панель управления": мини консоль обновлений
  # (job.log = stderr этого процесса, см. stats_update.sh) должна показывать
  # реальный построчный прогресс по каждому скачиваемому файлу, а не только
  # общие чекпоинты "Подготовка обновления...".
  r=self.cli('--prepare','--components=a,b','--format=json')
  self.assertIn('/opt/etc/mihomo-speedtest/a.sh',r.stderr)
  self.assertIn('/opt/etc/mihomo-speedtest/b.txt',r.stderr)

unittest.main(argv=['test_update_prepare'],verbosity=2)
PY
