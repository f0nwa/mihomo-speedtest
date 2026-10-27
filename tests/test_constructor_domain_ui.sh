#!/bin/sh
# Свои домены редактируются в строке, а «Убрать» оставляет красную строку с «Вернуть».
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_domain_ui: нет node"; exit 0; }
TMPD=$(mktemp -d /tmp/test-constructor-domain-ui.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT INT TERM
cp "$ROOT/web/stats_app_core.js" "$TMPD/app-core.js"
cp "$ROOT/web/stats_app_constructor_model.js" "$TMPD/app-constructor-model.js"
cp "$ROOT/web/stats_app_constructor_modules_model.js" "$TMPD/app-constructor-modules-model.js"
cp "$ROOT/web/stats_app_constructor_modules.js" "$TMPD/app-constructor-modules.js"
cp "$ROOT/web/stats_app_constructor.js" "$TMPD/app-constructor.js"
node --input-type=module - "$TMPD/app-constructor.js" <<'JS'
import { pathToFileURL } from 'node:url';

class Element {
  constructor(tag) {
    this.tag = tag; this.children = []; this.listeners = {}; this.attrs = {};
    this.className = ''; this.value = ''; this.hidden = false; this.disabled = false;
    this.style = {}; this._text = ''; this.parentNode = null;
    this.classList = { toggle: (name, on) => {
      this.className = this.className.replace(new RegExp('(?:^| )' + name + '(?= |$)', 'g'), '').trim() + (on ? ' ' + name : '');
    } };
  }
  get firstChild() { return this.children[0] || null; }
  get nextSibling() { return this.parentNode?.children[this.parentNode.children.indexOf(this) + 1] || null; }
  get offsetHeight() { return 0; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; return child; }
  insertBefore(child, before) {
    if (!before) { return this.appendChild(child); }
    child.parentNode = this; this.children.splice(this.children.indexOf(before), 0, child); return child;
  }
  setAttribute(key, value) { this.attrs[key] = value; }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  fire(type, event = {}) { (this.listeners[type] || []).forEach(listener => listener({ preventDefault() {}, ...event })); }
  click() { this.fire('click'); }
  focus() {}
  showModal() {}
  close() {}
  scrollIntoView() {}
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
}
const app = new Element('div');
const body = new Element('body');
globalThis.document = {
  body,
  getElementById(id) { return id === 'app' ? app : null; },
  createElement(tag) { return new Element(tag); },
  createTextNode(text) { const n = new Element('#text'); n.textContent = text; return n; },
};
globalThis.window = { pageYOffset: 0, pageXOffset: 0, scrollTo() {} };
globalThis.fetch = async () => ({ ok: true, json: async () => ({
  defaults: 'section\tother\tПрочее\nsvc\tweb\tWeb\tother\n',
  services: 'dom\tweb\tsuffix\tfirst.example\ndom\tweb\tfull\tsecond.example\n',
  user_rules: '', template_base: '', subscriptions: '', proxies: '',
  geofilter: '', geofilter_default: '', block: ''
}) });
const { renderConstructor } = await import(pathToFileURL(process.argv[2]).href);
renderConstructor(new Element('div'));
await new Promise(resolve => setTimeout(resolve, 0));
function all(node, match) { return (match(node) ? [node] : []).concat(node.children.flatMap(child => all(child, match))); }
function one(node, match, message) { const found = all(node, match)[0]; if (!found) { throw new Error(message); } return found; }
function field(value) { return one(app, n => n.tag === 'input' && n.attrs['aria-label'] === 'Домен ' + value, 'нет поля домена ' + value); }
function row(value) { return field(value).parentNode; }
function action(value, title) { return one(row(value), n => n.tag === 'button' && n.textContent === title, 'нет кнопки ' + title + ' для ' + value); }
function assert(value, message) { if (!value) { throw new Error(message); } }
let input = field('first.example');
assert(input.value === 'first.example', 'существующий домен показан в поле');
let save = action('first.example', 'Сохранить');
assert(save.hidden, 'сохранение скрыто до изменения');
input.value = 'other.example'; input.fire('input');
assert(!save.hidden, 'сохранение появляется после изменения');
input.fire('keydown', { key: 'Escape' });
assert(input.value === 'first.example' && save.hidden, 'Esc отменяет правку');
input.value = 'edited.example'; input.fire('input');
input.fire('keydown', { key: 'Enter' });
assert(field('edited.example').value === 'edited.example', 'Enter сохраняет домен в той же строке');
assert(field('second.example').value === 'second.example', 'соседний домен не изменился');
action('second.example', 'Убрать').click();
assert(row('second.example').className.includes('cx-domain-removed'), 'убранный домен выделен красным классом');
assert(field('second.example').disabled, 'убранный домен нельзя редактировать');
assert(action('second.example', 'Вернуть'), 'кнопка возврата осталась в строке');
action('second.example', 'Вернуть').click();
assert(!row('second.example').className.includes('cx-domain-removed'), 'после возврата красная пометка снята');
assert(!field('second.example').disabled, 'возвращённый домен снова редактируется');
console.log('OK test_constructor_domain_ui');
JS
grep -q '\.cx-row\.cx-domain-removed' "$ROOT/web/stats_style.css" || {
  echo 'FAIL: нет красной пометки убранного домена' >&2
  exit 1
}
