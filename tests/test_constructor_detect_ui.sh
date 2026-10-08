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
grep -q "body: url" "$MOD" || fail "адрес подписки должен уходить телом POST"
grep -q "detect-ua?" "$MOD" && fail "адрес подписки не должен попадать в строку запроса"

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
function mockServer(reply, status = 200) {
  requests = [];
  globalThis.fetch = (url, opts) => { requests.push({ url, opts }); return Promise.resolve({ ok: status < 400, status, json: () => Promise.resolve(reply) }); };
}

function build(urlValue, value = 'v2rayNG/1.8.0') {
  const url = { value: urlValue };
  const f = M.uaField(value, () => url.value);
  const btn = find(f, (n) => n.tag === 'button');
  const sel = find(f, (n) => n.tag === 'select');
  const custom = find(f, (n) => n.tag === 'input');
  const note = find(f, (n) => /cx-ua-note/.test(n.className));
  return { f, btn, sel, custom, note, url };
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
eq(requests.length, 1, 'один запрос');
eq(requests[0].url, '/api/constructor/detect-ua', 'маршрут без адреса в строке запроса');
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
