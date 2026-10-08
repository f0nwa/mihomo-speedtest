#!/bin/sh
# Кнопка «Определить» у поля User-Agent в блоке «Подписки» конструктора
# (web/stats_app_constructor_modules.js, uaField): проводка проверяется grep-ом,
# поведение - node с заглушками document и fetch. Нет node - часть с
# поведением пропускается (на роутере его нет).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
MOD=$ROOT/web/stats_app_constructor_modules.js
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q '/api/constructor/detect-ua' "$MOD" || fail "UI не вызывает /api/constructor/detect-ua"
grep -q '"api/constructor/detect-ua": ("stats_constructor.sh"' "$ROOT/web/stats_httpd.py" || fail "нет маршрута detect-ua в stats_httpd.py"
grep -q 'uaField(s.ua, function' "$MOD" || fail "в редакторе подписки нет кнопки «Определить»"
grep -q 'uaField(UA_PRESETS\[0\], function' "$MOD" || fail "в форме новой подписки нет кнопки «Определить»"
# адрес уходит телом, а не строкой запроса: ключ доступа не попадает в журналы
grep -q "post('/api/constructor/detect-ua', url)" "$MOD" || fail "адрес подписки должен уходить телом POST"
grep -q "detect-ua?" "$MOD" && fail "адрес подписки не должен попадать в строку запроса"
grep -q '/api/constructor/probe-nodes' "$MOD" || fail "UI не вызывает /api/constructor/probe-nodes"
grep -q '"api/constructor/probe-nodes": ("stats_constructor.sh"' "$ROOT/web/stats_httpd.py" || fail "нет маршрута probe-nodes в stats_httpd.py"
grep -q "probe-nodes?" "$MOD" && fail "адрес подписки не должен попадать в строку запроса probe-nodes"

command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_detect_ui (поведение): нет node"; echo "test_constructor_detect_ui: OK"; exit 0; }
TMPD=$(mktemp -d /tmp/test-constructor-detect-ui.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT INT TERM
# На диске файлы называются stats_app_*.js, а импорты идут по URL-именам
# app-*.js (их сопоставляет stats_httpd.py) - копируем под URL-именами.
cp "$ROOT/web/stats_app_core.js" "$TMPD/app-core.js"
cp "$ROOT/web/stats_app_constructor_modules_model.js" "$TMPD/app-constructor-modules-model.js"
cp "$MOD" "$TMPD/app-constructor-modules.js"
node --input-type=module - "$TMPD/app-constructor-modules.js" <<'JS'
import { pathToFileURL } from 'node:url';

// Минимальный DOM: узлы с детьми, атрибутами и обработчиками.
class Node_ {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.listeners = {}; this.className = ''; this._text = ''; this.hidden = false; this.disabled = false; this.value = ''; }
  get firstChild() { return this.children[0] || null; }
  appendChild(c) { this.children.push(c); return c; }
  removeChild(c) { this.children.splice(this.children.indexOf(c), 1); return c; }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  click() { (this.listeners.click || []).forEach((f) => f({})); }
  focus() {}
  set textContent(t) { this._text = t; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
}
globalThis.document = {
  getElementById() { return null; },
  createElement(tag) {
    const n = new Node_(tag);
    if (tag === 'select') {
      // как в браузере: value = выбранный option, неизвестное значение сбрасывает выбор
      let v = '';
      Object.defineProperty(n, 'value', {
        get() { return v; },
        set(x) { v = n.children.some((o) => o.value === x) ? x : ''; },
      });
    }
    return n;
  },
  createTextNode(t) { const n = new Node_('#text'); n._text = t; return n; },
};

const M = await import(pathToFileURL(process.argv[2]).href);
let failed = 0;
function eq(a, b, what) { const A = JSON.stringify(a), B = JSON.stringify(b); if (A !== B) { console.error('FAIL: ' + what + '\n  ожидалось ' + B + '\n  получено  ' + A); failed = 1; } }
const find = (n, pred) => { if (pred(n)) { return n; } for (const c of n.children) { const r = find(c, pred); if (r) { return r; } } return null; };
const findAll = (n, pred, out = []) => { if (pred(n)) { out.push(n); } n.children.forEach((c) => findAll(c, pred, out)); return out; };
const tick = () => new Promise((r) => setTimeout(r, 0));

let requests = [];
// reply - ответ detect-ua; probe - ответ probe-nodes (или {status, body} для ошибки)
function mockServer(reply, status = 200, probe = null) {
  requests = [];
  globalThis.fetch = (url, opts) => {
    requests.push({ url, opts });
    let body = reply, st = status;
    if (url.indexOf('probe-nodes') >= 0) { body = probe ? probe.body : { ok: true, verdict: 'alive', alive: 1, tested: 1, total: 1, mlkem: '' }; st = probe && probe.status ? probe.status : 200; }
    return Promise.resolve({ ok: st < 400, status: st, json: () => Promise.resolve(body) });
  };
}

function build(urlValue, value = 'v2rayNG/1.8.0') {
  const url = { value: urlValue };
  const f = M.uaField(value, () => url.value);
  const btn = find(f, (n) => n.tag === 'button');
  const sel = find(f, (n) => n.tag === 'select');
  const custom = find(f, (n) => n.tag === 'input');
  const notes = findAll(f, (n) => /cx-ua-note/.test(n.className));
  return { f, btn, sel, custom, note: notes[0], probe: notes[1], url };
}

// без кнопки, если адрес не передан (прежнее поведение поля)
eq(find(M.uaField('clash.meta'), (n) => n.tag === 'button'), null, 'без getUrl кнопки нет');

// пустой адрес: запрос не уходит
mockServer({});
let t = build('  ');
t.btn.click(); await tick();
eq(requests.length, 0, 'пустой адрес - без запроса');
eq(t.note.hidden, false, 'пустой адрес - есть сообщение');
if (!/адрес/.test(t.note.textContent)) { console.error('FAIL: нет подсказки про адрес'); failed = 1; }

// успех: UA из готового списка выбирается в списке
mockServer({ ok: true, ua: 'clash-verge/v2.0.5', quality: 'full', kind: 'clash YAML, полный (подходит)', reason: '', tried: [{ ua: 'a', http: '200', bytes: 1, kind: 'x' }] });
t = build(' https://panel.test/KEY ');
t.btn.click();
eq(t.btn.disabled, true, 'кнопка занята, пока идёт перебор');
await tick();
eq(requests.length, 2, 'детект и проверка нод');
eq(requests[0].url, '/api/constructor/detect-ua', 'маршрут без адреса в строке запроса');
eq(requests[1].url, '/api/constructor/probe-nodes', 'маршрут проверки нод без адреса в строке запроса');
eq(requests[1].opts.body, 'https://panel.test/KEY\nclash-verge/v2.0.5', 'проверка нод: адрес и UA - телом');
eq(requests[0].opts.method, 'POST', 'POST');
eq(requests[0].opts.body, 'https://panel.test/KEY', 'адрес - в теле, без пробелов по краям');
eq(t.f.value(), 'clash-verge/v2.0.5', 'UA подставлен');
eq(t.sel.value, 'clash-verge/v2.0.5', 'выбран в списке');
eq(t.btn.disabled, false, 'кнопка свободна после ответа');
eq(t.btn.textContent, 'Определить', 'подпись кнопки возвращена');
if (!/Выбран clash-verge\/v2\.0\.5/.test(t.note.textContent)) { console.error('FAIL: нет итога: ' + t.note.textContent); failed = 1; }

// успех: UA вне списка уходит в поле «другой...»
mockServer({ ok: true, ua: 'v2rayNG/1.10.10', quality: 'full', kind: 'k', reason: '', tried: [] });
t = build('https://panel.test/k');
t.btn.click(); await tick();
eq(t.f.value(), 'v2rayNG/1.10.10', 'нестандартный UA подставлен');
eq(t.custom.value, 'v2rayNG/1.10.10', 'нестандартный UA - в поле «другой»');

// укороченный YAML - с предупреждением
mockServer({ ok: true, ua: 'ClashX/1.95.1', quality: 'short', kind: 'k', reason: '', tried: [] });
t = build('https://panel.test/k');
t.btn.click(); await tick();
eq(t.f.value(), 'ClashX/1.95.1', 'укороченный: UA подставлен');
if (!/укороченный/.test(t.note.textContent) || /msg-ok-text/.test(t.note.className)) { console.error('FAIL: укороченный YAML без предупреждения'); failed = 1; }

// ничего не подошло: прежний выбор остаётся, видно, что вернула панель
mockServer({ ok: true, ua: '', quality: '', kind: '', reason: 'none', tried: [{ ua: 'a', http: '403', bytes: 5, kind: 'html' }, { ua: 'b', http: '200', bytes: 7, kind: 'json' }] });
t = build('https://panel.test/k', 'clash.meta');
t.btn.click(); await tick();
eq(t.f.value(), 'clash.meta', 'не подошло: выбор не тронут');
eq(findAll(t.note, (n) => n.tag === 'div' && n !== t.note).length, 2, 'не подошло: список ответов панели');
if (!/Ни один из 2/.test(t.note.textContent)) { console.error('FAIL: нет итога «ни один»: ' + t.note.textContent); failed = 1; }

// адрес не открылся
mockServer({ ok: true, ua: '', quality: '', kind: '', reason: 'unreachable', tried: [{ ua: 'a', http: '000', bytes: 0, kind: 'пусто' }] });
t = build('https://panel.test/k');
t.btn.click(); await tick();
if (!/не открылся/.test(t.note.textContent)) { console.error('FAIL: нет сообщения «не открылся»: ' + t.note.textContent); failed = 1; }

// проверка нод: ноды отвечают
mockServer({ ok: true, ua: 'clash-verge/v2.0.5', quality: 'full', kind: 'k', reason: '', tried: [] }, 200,
  { body: { ok: true, verdict: 'alive', alive: 2, tested: 3, total: 3, mlkem: '', nodes: [] } });
t = build('https://panel.test/k');
t.btn.click(); await tick(); await tick();
if (!/отвечают: 2 из 3/.test(t.probe.textContent) || !/msg-ok-text/.test(t.probe.className)) { console.error('FAIL: нет итога «ноды отвечают»: ' + t.probe.textContent); failed = 1; }
eq(t.btn.disabled, false, 'после проверки нод кнопка свободна');

// Reality отклоняет клиента Mihomo: понятный вердикт, UA остаётся выбранным
mockServer({ ok: true, ua: 'v2rayNG/1.8.0', quality: 'full', kind: 'k', reason: '', tried: [] }, 200,
  { body: { ok: true, verdict: 'reality_rejected', alive: 0, tested: 3, total: 3, mlkem: 'false', nodes: [] } });
t = build('https://panel.test/k', 'clash.meta');
t.btn.click(); await tick(); await tick();
eq(t.f.value(), 'v2rayNG/1.8.0', 'вердикт Reality не отменяет найденный UA');
if (!/REALITY/.test(t.probe.textContent) || !/X25519MLKEM768/.test(t.probe.textContent) || !/msg-err-text/.test(t.probe.className)) { console.error('FAIL: нет вердикта про REALITY: ' + t.probe.textContent); failed = 1; }
if (!/Happ/.test(t.probe.textContent)) { console.error('FAIL: вердикт не объясняет, что клиенты на Xray могут работать'); failed = 1; }

// ноды молчат без признаков Reality
mockServer({ ok: true, ua: 'v2rayNG/1.8.0', quality: 'full', kind: 'k', reason: '', tried: [] }, 200,
  { body: { ok: true, verdict: 'unreachable', alive: 0, tested: 2, total: 2, mlkem: '', nodes: [] } });
t = build('https://panel.test/k');
t.btn.click(); await tick(); await tick();
if (!/ни одна из 2 нод/.test(t.probe.textContent)) { console.error('FAIL: нет вердикта «не отвечают»: ' + t.probe.textContent); failed = 1; }

// сбой самой проверки нод: UA остаётся, причина показана
mockServer({ ok: true, ua: 'clash-verge/v2.0.5', quality: 'full', kind: 'k', reason: '', tried: [] }, 200,
  { status: 422, body: { ok: false, error: 'unsupported', message: 'Проверка нод понимает только clash YAML' } });
t = build('https://panel.test/k');
t.btn.click(); await tick(); await tick();
eq(t.f.value(), 'clash-verge/v2.0.5', 'сбой проверки нод не отменяет UA');
if (!/не удалось: Проверка нод понимает/.test(t.probe.textContent)) { console.error('FAIL: причина сбоя проверки нод не показана: ' + t.probe.textContent); failed = 1; }
eq(t.btn.disabled, false, 'после сбоя проверки нод кнопка свободна');

// UA не найден - проверка нод не запускается
mockServer({ ok: true, ua: '', quality: '', kind: '', reason: 'none', tried: [{ ua: 'a', http: '403', bytes: 5, kind: 'html' }] });
t = build('https://panel.test/k');
t.btn.click(); await tick(); await tick();
eq(requests.length, 1, 'UA не найден - без проверки нод');

// ошибка сервера: текст ошибки показан, кнопка снова доступна
mockServer({ ok: false, error: 'bad_url', message: 'Адрес подписки должен начинаться с http://' }, 400);
t = build('ftp://x');
t.btn.click(); await tick();
if (!/должен начинаться/.test(t.note.textContent)) { console.error('FAIL: ошибка сервера не показана: ' + t.note.textContent); failed = 1; }
eq(t.btn.disabled, false, 'после ошибки кнопка свободна');
eq(t.f.value(), 'v2rayNG/1.8.0', 'после ошибки выбор не тронут');
process.exit(failed);
JS
echo "test_constructor_detect_ui: OK"
