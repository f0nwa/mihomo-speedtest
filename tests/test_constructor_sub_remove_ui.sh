#!/bin/sh
# Убранная подписка остаётся в списке конструктора до применения (красной) и возвращается на месте.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_sub_remove_ui: нет node"; exit 0; }
TMPD=$(mktemp -d /tmp/test-constructor-sub-remove-ui.XXXXXX)
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
const source = ['first', 'middle', 'last'].map(name => 'https://' + name + '.example/x' + T + T + name).join('\n') + '\n';
const mods = createModules({ subscriptions: source, proxies: '', geofilter: null, geofilter_default: '' });
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
function names() { return rows().map(row => findAll(row, n => n.tag === 'input' && n.className === 'cx-name')[0].value); }
function btn(row, text) { return findAll(row, n => n.tag === 'button' && n.textContent === text)[0]; }
function assert(value, message) { if (!value) { throw new Error(message); } }
assert(names().join(',') === 'first,middle,last', 'исходный порядок подписок');
btn(rows()[1], 'Убрать').click();
assert(names().join(',') === 'first,middle,last', 'убранная подписка осталась на месте');
assert(rows()[1].className.includes('cx-sub-removed'), 'убранная подписка отмечена красным классом');
assert(findAll(rows()[1], n => n.tag === 'input' && n.className === 'cx-name')[0].disabled, 'имя убранной подписки нельзя менять');
assert(!btn(rows()[1], 'Изменить'), 'убранную подписку нельзя редактировать');
assert(!mods.serialize().subscriptions.includes('middle'), 'убранной подписки нет в конфиге для проверки');
assert(mods.summary({ subscriptions: source, proxies: '', geofilter: '' }).join() === 'Убрать подписку middle', 'убранная подписка в сводке');
let threw = false; try { mods.addSub('https://z.example/', '', 'middle'); } catch (e) { threw = true; }
assert(threw, 'имя убранной подписки занято до применения');
btn(rows()[1], 'Вернуть').click();
assert(names().join(',') === 'first,middle,last', 'после возврата порядок прежний');
assert(!rows()[1].className.includes('cx-sub-removed'), 'после возврата красная пометка снята');
assert(mods.serialize().subscriptions === source, 'после возврата подписка снова входит в конфиг');
console.log('OK test_constructor_sub_remove_ui');
JS
