#!/bin/sh
# Вкладка «Конфиг» (YAML): навигатор разделов, поиск и полноэкранный режим
# (createConfigNav() в web/stats_app_config.js), подписи бэкапов. Проводка
# проверяется grep-ом, разбор разделов, «хлебные крошки», поиск и подписи -
# node на шаблоне конфига. Нет node - поведение пропускается (на роутере его нет).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
JS=$ROOT/web/stats_app_config.js
CSS=$ROOT/web/stats_style.css
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'var nav = createConfigNav(' "$JS" || fail "редактор не обёрнут в createConfigNav"
grep -q 'main.appendChild(nav.root)' "$JS" || fail "навигатор не добавлен в карточку конфига"
grep -q 'nav.attach(ed)' "$JS" || fail "навигатор не подключён к редактору"
grep -q 'cm: cm,' "$JS" || fail "createEditor не отдаёт CodeMirror навигатору"
grep -q 'activeNav.destroy()' "$JS" || fail "уход с вкладки не закрывает полноэкранный режим"
grep -q 'nav.setDirty(view.dirty)' "$JS" || fail "полноэкранная панель не знает о несохранённых правках"
grep -q "'Ctrl-F'" "$JS" || fail "нет Ctrl+F"
grep -q '\.config-work\.fs{position:fixed' "$CSS" || fail "нет стилей полноэкранного режима"
grep -q '\.cm-hit-cur' "$CSS" || fail "нет подсветки текущего совпадения"

command -v node >/dev/null 2>&1 || { echo "SKIP test_config_nav (поведение): нет node"; echo "test_config_nav: OK"; exit 0; }
node - "$JS" "$ROOT/config-tools/config.example.yaml" <<'JS'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const a = src.indexOf('var SECTION_RU'), b = src.indexOf('function svgIcon');
if (a < 0 || b < a) { console.error('FAIL: не найден блок функций навигатора'); process.exit(1); }
const code = src.slice(a, b).replace(/^export /gm, '');
const { yamlSections, yamlCrumbs, findAllText } = new Function(code + '\nreturn { yamlSections, yamlCrumbs, findAllText };')();
function eq(x, y, what) { if (JSON.stringify(x) !== JSON.stringify(y)) { console.error('FAIL: ' + what + ': ' + JSON.stringify(x) + ' != ' + JSON.stringify(y)); process.exit(1); } }
const fmtMatch = src.match(/function fmtBackupName\(name\) \{[\s\S]*?\n\}/);
if (!fmtMatch) { console.error('FAIL: не найдена fmtBackupName'); process.exit(1); }
const fmtBackupName = new Function(fmtMatch[0] + '\nreturn fmtBackupName;')();
eq(fmtBackupName('config.yaml.2026-11-02_134400.bak'),
  '02.11.2026 13:44:00 · config.yaml.2026-11-02_134400.bak', 'полное имя первой копии');
eq(fmtBackupName('config.yaml.2026-11-02_134400-2.bak'),
  '02.11.2026 13:44:00 · копия 2 · config.yaml.2026-11-02_134400-2.bak', 'номер второй копии');
eq(fmtBackupName('config.yaml.2026-11-02_134400-10.bak'),
  '02.11.2026 13:44:00 · копия 10 · config.yaml.2026-11-02_134400-10.bak', 'номер десятой копии');
eq(fmtBackupName('config.yaml.not-a-date.bak'), 'config.yaml.not-a-date.bak', 'неизвестное имя');

const doc = [
  '# комментарий',
  'mixed-port: 7890',
  'mode: rule',
  'dns:',
  '  enable: true',
  '  nameserver:',
  '    - https://dns.google/dns-query',
  'log-level: warning',
  'proxies:',
  '- name: wg-home',
  '  type: wireguard',
  '- name: wg-2',
  '  type: wireguard',
  'proxy-groups:',
  '  - name: YouTube',
  '    type: select',
  '    proxies: [DIRECT]',
  'rule-providers: &rp',
  '  youtube:',
  '    url: https://example.org/youtube.mrs',
  'rules:',
  '  - RULE-SET,youtube,YouTube',
  '  - MATCH,DIRECT'
];
const r = yamlSections(doc);
eq(r.secs.map(s => [s.name, s.line, s.items]),
  [['Общие настройки', 1, 3], ['dns', 3, 2], ['proxies', 8, 2], ['proxy-groups', 13, 1], ['rule-providers', 17, 1], ['rules', 20, 2]],
  'разделы');
eq(r.lineSec[7].name, 'Общие настройки', 'скалярный ключ после блока - в общих');
eq(r.lineSec[10].name, 'proxies', 'строка списка на нулевом отступе - в своём разделе');
eq(r.secs[4].ru, 'наборы правил', 'русская подпись раздела');

const get = n => doc[n];
eq(yamlCrumbs(get, 15), ['proxy-groups', 'YouTube', 'type'], 'крошки элемента списка');
eq(yamlCrumbs(get, 10), ['proxies', 'wg-home', 'type'], 'крошки списка на нулевом отступе');
eq(yamlCrumbs(get, 19), ['rule-providers', 'youtube', 'url'], 'крошки вложенного ключа');
eq(yamlCrumbs(get, 2), ['mode'], 'крошки ключа верхнего уровня');
eq(yamlCrumbs(get, 0), [], 'комментарий без крошек');

const hits = findAllText(doc, 'youtube', false);
eq(hits.map(h => [h.line, h.col]), [[14, 10], [18, 2], [19, 29], [21, 13], [21, 21]], 'поиск без учёта регистра');
eq(findAllText(doc, 'YouTube', true).length, 2, 'поиск с учётом регистра');
eq(findAllText(doc, '', false).length, 0, 'пустой запрос');

// Шаблон проекта целиком: разделы находятся, у каждой строки есть раздел.
const tpl = fs.readFileSync(process.argv[3], 'utf8').split('\n');
const t = yamlSections(tpl);
const names = t.secs.map(s => s.name);
['proxy-groups', 'rule-providers', 'rules'].forEach(n => { if (names.indexOf(n) < 0) { console.error('FAIL: в шаблоне не найден раздел ' + n); process.exit(1); } });
for (let i = 0; i < tpl.length; i++) { if (t.secs.indexOf(t.lineSec[i]) < 0) { console.error('FAIL: строка ' + (i + 1) + ' шаблона без раздела'); process.exit(1); } }
JS
echo "test_config_nav: OK"
