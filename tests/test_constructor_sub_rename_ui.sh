#!/bin/sh
# Имя подписки правится прямо в строке, как имя ноды в «Прокси»: кнопка
# «Сохранить имя» появляется только при изменённом имени, Enter - сохранить,
# Esc - вернуть как было. Адрес и User-Agent по-прежнему в «Изменить».
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_sub_rename_ui: нет node"; exit 0; }
TMPD=$(mktemp -d /tmp/test-constructor-sub-rename-ui.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT INT TERM
cp "$ROOT/web/stats_app_core.js" "$TMPD/app-core.js"
cp "$ROOT/web/stats_app_constructor_modules_model.js" "$TMPD/app-constructor-modules-model.js"
cp "$ROOT/web/stats_app_constructor_modules.js" "$TMPD/app-constructor-modules.js"
node --input-type=module - "$TMPD/app-constructor-modules.js" "$TMPD/app-constructor-modules-model.js" <<'JS'
import { pathToFileURL } from 'node:url';

class Element {
  constructor(tag) {
    this.tag = tag; this.children = []; this.listeners = {}; this.attrs = {};
    this.className = ''; this.value = ''; this.hidden = false; this.disabled = false; this._text = '';
    this.classList = { toggle: (name, on) => { this.className = this.className.replace(new RegExp('(?:^| )' + name + '(?= |$)', 'g'), '').trim() + (on ? ' ' + name : ''); } };
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; }
  setAttribute(key, value) { this.attrs[key] = value; }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  click() { (this.listeners.click || []).forEach(listener => listener({})); }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
}
globalThis.document = {
  getElementById() { return null; },
  createElement(tag) { return new Element(tag); },
  createTextNode(text) { const n = new Element('#text'); n.textContent = text; return n; },
};
const { createModuleCards } = await import(pathToFileURL(process.argv[2]).href);
const { createModules } = await import(pathToFileURL(process.argv[3]).href);
const T = '\t';
const SUBS = ['https://a.example/T1' + T + 'v2rayNG/1.8.0' + T + 'alpha', 'https://b.example/T2' + T + T + 'beta'].join('\n') + '\n';
const mods = createModules({ subscriptions: SUBS, proxies: '', geofilter: null, geofilter_default: '' });
const bodies = {};
let cards;
const ctx = {
  mods, model: { ownScope: () => false, baseGroups: () => [], routes: () => [] }, savedWords: [],
  layout: { add(num) { const body = new Element('div'); bodies[num] = body; return { body, summary() {}, changed() {} }; } },
  edit(fn) { fn(); cards.render(); }, msg() {}, redraw() {}, changed() {},
};
cards = createModuleCards(ctx);
cards.render();
function findAll(node, match) { return (match(node) ? [node] : []).concat(node.children.flatMap(child => findAll(child, match))); }
function rows() { return findAll(bodies[1], n => n.className.includes('cx-row') && n.className.includes('xk-row')); }
function nameInput(row) { return findAll(row, n => n.tag === 'input' && n.className === 'cx-name')[0]; }
function saveBtn(row) { return findAll(row, n => n.tag === 'button' && n.textContent === 'Сохранить имя')[0]; }
function fire(node, type, ev) { (node.listeners[type] || []).forEach(l => l(ev || {})); }
function assert(value, message) { if (!value) { throw new Error(message); } }
assert(rows().length === 2, 'две подписки в списке');
let inp = nameInput(rows()[0]);
assert(inp && inp.value === 'alpha', 'имя подписки - поле ввода в строке');
assert(saveBtn(rows()[0]) && saveBtn(rows()[0]).hidden, '«Сохранить имя» скрыта, пока имя не менялось');
inp.value = 'alpha2'; fire(inp, 'input');
assert(!saveBtn(rows()[0]).hidden, '«Сохранить имя» появилась после правки');
fire(inp, 'keydown', { key: 'Escape' });
assert(inp.value === 'alpha' && saveBtn(rows()[0]).hidden, 'Esc вернул имя и спрятал кнопку');
inp.value = 'alpha2'; fire(inp, 'input');
saveBtn(rows()[0]).click();
assert(mods.subs().map(s => s.name).join(',') === 'alpha2,beta', 'кнопка сохранила новое имя');
assert(mods.subs()[0].url === 'https://a.example/T1' && mods.subs()[0].ua === 'v2rayNG/1.8.0', 'адрес и UA не тронуты');
inp = nameInput(rows()[1]); inp.value = 'beta2'; fire(inp, 'input');
fire(inp, 'keydown', { key: 'Enter', preventDefault() {} });
assert(mods.subs().map(s => s.name).join(',') === 'alpha2,beta2', 'Enter сохранил новое имя');
assert(nameInput(rows()[1]).value === 'beta2', 'строка перерисована с новым именем');
findAll(rows()[0], n => n.tag === 'button' && n.textContent === 'Изменить')[0].click();
const editor = findAll(bodies[1], n => n.className === 'cx-editor')[0];
assert(editor && !findAll(editor, n => n.attrs['aria-label'] === 'Имя подписки').length, 'в «Изменить» имени больше нет - только адрес и UA');
console.log('OK test_constructor_sub_rename_ui');
JS
