#!/bin/sh
# config.yaml как символическая ссылка на профиль (XKeen UI держит профили в
# /opt/etc/mihomo/profiles/*.yaml и переключает активный ссылкой): обновлятор
# работает с файлом профиля, саму ссылку не трогает, откат после
# переключения профиля отклоняется, ссылки за пределы каталога Mihomo - нет.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib,sys,unittest,json,hashlib,os,subprocess,tempfile,stat,re,time,shutil
ROOT=pathlib.Path(sys.argv[1])
fixture=(ROOT/'tests/test_update_config_apply.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0].split('names=[n for n',1)[0]
exec(compile(fixture,'config_apply_fixture','exec'))
# Относительная ссылка: абсолютная /opt/... в тесте указала бы на /opt
# хоста для скриптов перезапуска/здоровья (они читают конфиг по ссылке).
# Абсолютная форма (как на роутере) проверяется в test_absolute_link_*.
LINK='profiles/default.yaml'
class ConfigSymlink(ConfigApply):
 def setUp(self):
  super().setUp()
  self.profiles=self.target/'opt/etc/mihomo/profiles';self.profiles.mkdir()
  self.profile=self.profiles/'default.yaml';self.config.rename(self.profile)
  self.link=self.config;self.link.symlink_to(LINK)
 def linked(self):
  self.assertTrue(self.link.is_symlink(),'config.yaml перестал быть ссылкой');self.assertEqual(os.readlink(self.link),LINK)
  self.assertEqual(list(self.target.rglob('*.mst-update-new')),[])
 def test_plan_and_prepare_follow_link(self):
  r=self.cli('--plan','--format=json');json.loads(r.stdout);d,p=self.prepare();self.assertEqual((p/'config-source.yaml').read_bytes(),self.original);self.linked()
 def test_apply_writes_profile_and_keeps_link(self):
  d,p,candidate=self.applied();self.linked();self.assertEqual(self.profile.read_bytes(),candidate);self.assertEqual(stat.S_IMODE(self.profile.stat().st_mode),0o640)
  self.assertEqual([r['action'] for r in self.actions()],['restart','health'])
 def test_rollback_restores_profile_and_keeps_link(self):
  self.applied();self.cli('--rollback-last');self.restored();self.linked();self.assertEqual(self.profile.read_bytes(),self.original)
 def test_absolute_link_resolved_inside_target_root(self):
  self.link.unlink();self.link.symlink_to('/opt/etc/mihomo/profiles/default.yaml')
  json.loads(self.cli('--plan','--format=json').stdout);d,p=self.prepare();self.assertEqual((p/'config-source.yaml').read_bytes(),self.original)
  self.assertEqual(os.readlink(self.link),'/opt/etc/mihomo/profiles/default.yaml')
 def test_rollback_refused_after_profile_switch(self):
  self.applied();other=self.profiles/'other.yaml';other.write_text('other: profile\n')
  self.link.unlink();self.link.symlink_to('profiles/other.yaml');before=self.snapshot()
  self.cli('--rollback-last',ok=False);self.assertEqual(self.snapshot(),before);self.assertEqual(other.read_text(),'other: profile\n')
 def test_bad_links_rejected_without_writes(self):
  outside=self.root/'outside.yaml';outside.write_bytes(self.original)
  chain=self.profiles/'chain.yaml';chain.symlink_to(self.profile)
  cases=[(str(outside),'за пределы'),('../mihomo-speedtest/b.txt','Недопустимая цель'),('profiles/missing.yaml','отсутствующий файл'),('profiles/chain.yaml','Символическая ссылка в управляемом пути')]
  for target,message in cases:
   with self.subTest(target=target):
    self.link.unlink();self.link.symlink_to(target);before=self.snapshot()
    r=self.cli('--plan','--format=json',ok=False);self.assertIn(message,r.stderr);self.assertEqual(self.snapshot(),before)
names=[n for n in ConfigSymlink.__dict__ if n.startswith('test_')]
if os.environ.get('MST_TEST_NAMES'):names=os.environ['MST_TEST_NAMES'].split(',')
suite=unittest.TestSuite(ConfigSymlink(n) for n in names)
result=unittest.TextTestRunner(verbosity=2).run(suite);sys.exit(not result.wasSuccessful())
PY
