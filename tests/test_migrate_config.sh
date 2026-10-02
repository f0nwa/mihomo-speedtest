#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib, tempfile, subprocess, unittest, os, stat
ROOT=pathlib.Path(__import__('sys').argv[1])
class Migration(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir="/tmp");self.addCleanup(self.tmp.cleanup);self.d=pathlib.Path(self.tmp.name)
  self.old=self.d/'old.yaml';self.template=self.d/'template.yaml';self.out=self.d/'new.yaml';self.report=self.d/'report.txt'
  self.base=(ROOT/'config-tools'/'config.example.yaml').read_text();self.template.write_text(self.base)
  self.old.write_text(self.base.replace('subscription-1.example.com/CHANGE_ME','subscription-1.example.com/PRIVATE_TOKEN').replace('v2rayNG/1.8.0','custom-agent').replace('password: "CHANGE_ME"','password: "PRIVATE_PASSWORD"').replace('log-level: silent','log-level: debug').replace('routing-mark: 255','routing-mark: 111')+'secret: "PRIVATE_API_SECRET"\ndns:\n  enable: true\n  nameserver: [1.1.1.1]\n')
 def run_cli(self,ok=True,**env):
  r=subprocess.run(['sh',str(ROOT/'config-tools'/'migrate_config.sh'),'--source',str(self.old),'--template',str(self.template),'--output',str(self.out),'--report',str(self.report)],env=dict(os.environ,**env),capture_output=True,text=True)
  self.assertEqual(r.returncode==0,ok,r.stdout+r.stderr)
  if not ok:self.assertIn("ERROR:",r.stderr)
  return r
 def test_preserves_data_and_uses_new_groups(self):
  self.template.write_text(self.base.replace("'🚀 Авто по пингу'","'Новая авто группа'"))
  before=self.old.read_bytes();r=self.run_cli();text=self.out.read_text()
  for s in ['PRIVATE_TOKEN','custom-agent','PRIVATE_PASSWORD','PRIVATE_API_SECRET','log-level: debug','routing-mark: 111','dns:\n  enable: true','Новая авто группа']:self.assertIn(s,text)
  self.assertEqual(sum(x.startswith('dns:') for x in text.splitlines()),1);self.assertEqual(self.old.read_bytes(),before)
  for s in ['PRIVATE_TOKEN','PRIVATE_PASSWORD','PRIVATE_API_SECRET']:self.assertNotIn(s,r.stdout+r.stderr+self.report.read_text())
  self.assertEqual(stat.S_IMODE(self.out.stat().st_mode),0o600)
 def test_provider_options_preserved(self):
  self.old.write_text(self.old.read_text().replace('    url: "https://subscription-1','    interval: 987\n    header-extra: secret-option\n    url: "https://subscription-1'))
  self.run_cli();self.assertIn('interval: 987',self.out.read_text());self.assertIn('header-extra: secret-option',self.out.read_text())
 def test_unknown_and_managed_edits_are_reported_without_values(self):
  self.old.write_text(self.old.read_text()+'tun: {enable: true, device: SECRET_DEVICE}\n')
  self.run_cli();report=self.report.read_text();self.assertIn('REVIEW|unknown-top-key|tun',report);self.assertNotIn('SECRET_DEVICE',report)
 def test_static_names_references_follow_import(self):
  self.old.write_text(self.old.read_text().replace('🇩🇪 Hysteria2','Private node, one').replace('🇳🇱 Hysteria2','Private node two'))
  self.run_cli();t=self.out.read_text();self.assertNotIn('🇩🇪 Hysteria2',t);self.assertIn("proxies: ['Private node, one', 'Private node two']",t)
 def test_empty_static_does_not_restore_demo_nodes(self):
  a=self.old.read_text();start=a.index('proxies:\n');end=a.index('# --- Провайдеры прокси ---');self.old.write_text(a[:start]+'proxies: []\n\n'+a[end:])
  self.run_cli();self.assertNotIn('server: proxy-node',self.out.read_text());self.assertIn('proxies: []',self.out.read_text())
 def test_repeat_migration_is_stable(self):
  self.run_cli();first=self.out.read_bytes();self.old.write_bytes(first);self.run_cli();self.assertEqual(self.out.read_bytes(),first)
 def test_duplicate_root_key_rejected_without_replacing_output(self):
  self.out.write_text('GOOD');self.old.write_text(self.old.read_text()+'log-level: info\n');self.run_cli(False);self.assertEqual(self.out.read_text(),'GOOD')
 def test_missing_template_markers_rejected(self):
  self.template.write_text(self.base.replace('SUBSCRIPTIONS:END','OTHER:END'));self.out.write_text('GOOD');self.run_cli(False);self.assertEqual(self.out.read_text(),'GOOD')
 def test_source_symlink_rejected(self):
  actual=self.d/'actual';self.old.rename(actual);self.old.symlink_to(actual);self.run_cli(False)
 def test_output_outside_ram_rejected(self):
  self.out=pathlib.Path('/opt/_not_ram_config.yaml');self.run_cli(False);self.assertFalse(self.out.exists())
 def test_output_alias_source_rejected(self):
  self.out=self.old;before=self.old.read_bytes();self.run_cli(False);self.assertEqual(self.old.read_bytes(),before)
 def test_secret_with_list_syntax_is_opaque(self):
  self.old.write_text(self.old.read_text().replace('secret: "PRIVATE_API_SECRET"', 'secret: "proxies: [PRIVATE_API_SECRET]"'))
  self.run_cli();self.assertIn('secret: "proxies: [PRIVATE_API_SECRET]"',self.out.read_text())
 def test_reverse_markers_rejected(self):
  self.template.write_text(self.base.replace('SUBSCRIPTIONS:BEGIN','SWAP').replace('SUBSCRIPTIONS:END','SUBSCRIPTIONS:BEGIN').replace('SWAP','SUBSCRIPTIONS:END'));self.run_cli(False)
 def test_missing_custom_anchor_rejected(self):
  s=self.old.read_text().replace('anchors:', 'anchors:\n  private-secret: &private-secret PRIVATE_PASSWORD').replace('password: "PRIVATE_PASSWORD"', 'password: *private-secret')
  self.old.write_text(s);self.out.write_text('GOOD');self.run_cli(False);self.assertEqual(self.out.read_text(),'GOOD')
 def test_literal_scalar_does_not_define_missing_anchor(self):
  s=self.old.read_text().replace('anchors:', 'anchors:\n  private-secret: &private-secret PRIVATE_PASSWORD').replace('password: "PRIVATE_PASSWORD"', 'password: *private-secret').replace('secret: "PRIVATE_API_SECRET"', 'secret: |\n  &private-secret literal-text')
  self.old.write_text(s);self.run_cli(False)
 def test_fast_http_subscription_rejected(self):
  self.old.write_text(self.old.read_text().replace('  fast:\n    type: file','  fast:\n    type: http\n    url: "https://private.example/PRIVATE_TOKEN"'));self.run_cli(False)
 def test_inline_provider_map_rejected(self):
  self.old.write_text(self.old.read_text().replace('proxy-providers:', 'proxy-providers: {weird: {url: "PRIVATE_URL"}}'));self.run_cli(False)
 def test_quoted_provider_name_rejected(self):
  self.old.write_text(self.old.read_text().replace('  provider-b:', '  "provider-b":'));self.run_cli(False)
 def test_marker_words_in_secret_are_not_structure(self):
  self.template.write_text(self.base+'secret: default\n')
  self.old.write_text(self.old.read_text().replace('PRIVATE_API_SECRET', 'STATIC_DNS:BEGIN STATIC_DNS:END'))
  self.run_cli();self.assertIn('secret: "STATIC_DNS:BEGIN STATIC_DNS:END"',self.out.read_text());self.assertEqual(sum(x.startswith('dns:') for x in self.out.read_text().splitlines()),1)
 def test_candidate_rename_failure_after_report_keeps_output(self):
  self.out.write_text('GOOD');b=self.d/'bin';b.mkdir();real=__import__('shutil').which('mv')
  (b/'mv').write_text('#!/bin/sh\nfor arg do last=$arg; done\ncase "$last" in */new.yaml) exit 1 ;; esac\nexec "'+real+'" "$@"\n');(b/'mv').chmod(0o755)
  self.run_cli(False,PATH=str(b)+':'+os.environ['PATH']);self.assertEqual(self.out.read_text(),'GOOD')
 def test_oversize_source_rejected(self):
  self.old.write_text('#'+('x'*1048576));self.out.write_text('GOOD');self.run_cli(False);self.assertEqual(self.out.read_text(),'GOOD')
 def test_publication_failure_keeps_output(self):
  self.out.write_text('GOOD');b=self.d/'bin';b.mkdir();(b/'mv').write_text('#!/bin/sh\nexit 1\n');(b/'mv').chmod(0o755)
  self.run_cli(False,PATH=str(b)+':'+os.environ['PATH']);self.assertEqual(self.out.read_text(),'GOOD')
 # --- Служебный вход mst-speedtest и свои listeners (замер WG через основное ядро) ---
 def schema2(self,extra=''):
  # Конфиг до появления входа: без раздела listeners (группы - управляемые, заменяются шаблоном).
  a=self.old.read_text();start=a.index('# --- Входы ---');end=a.index('# --- НАСТРОЙКИ GEO-ДАННЫХ ---')
  self.old.write_text(a[:start]+extra+a[end:])
 def service(self,t):
  self.assertEqual(t.count('\n  - name: mst-speedtest\n'),1);self.assertIn('    port: 7896\n    proxy: MST-SPEEDTEST\n',t);self.assertEqual(t.count('\n  - name: MST-SPEEDTEST\n'),1);self.assertEqual(t.count('\nlisteners:\n'),1)
 def test_old_config_gets_service_listener_and_group(self):
  self.schema2();self.run_cli();t=self.out.read_text();self.service(t);self.assertNotIn('unknown-top-key|listeners',self.report.read_text())
 def test_user_listeners_preserved_between_markers(self):
  self.schema2('listeners:\n  - name: my-socks\n    type: socks\n    port: 7777\n  - name: mst-speedtest\n    type: mixed\n    port: 7896\n    proxy: X\n\n')
  self.run_cli();t=self.out.read_text();self.service(t)
  begin=t.index('STATIC_LISTENERS:BEGIN');end=t.index('STATIC_LISTENERS:END')
  self.assertIn('  - name: my-socks\n    type: socks\n    port: 7777\n',t[begin:end]);self.assertNotIn('proxy: X',t)
  self.assertIn('PRESERVED|section|listeners',self.report.read_text())
  first=self.out.read_bytes();self.old.write_bytes(first);self.out.unlink();self.run_cli();self.assertEqual(self.out.read_bytes(),first)
 def test_user_listener_on_service_port_rejected(self):
  self.schema2('listeners:\n  - name: my-http\n    type: http\n    port: 7896\n\n');self.out.write_text('GOOD');self.run_cli(False);self.assertEqual(self.out.read_text(),'GOOD')
 def test_local_port_on_service_port_rejected(self):
  self.old.write_text(self.old.read_text().replace('routing-mark: 111','routing-mark: 111\nmixed-port: 7896'));self.run_cli(False)
 def test_flow_listener_rejected(self):
  self.schema2('listeners:\n  - {name: my-socks, type: socks, port: 7777}\n\n');self.run_cli(False)
unittest.main(argv=["test_migrate_config"],verbosity=2)
PY
