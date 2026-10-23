#!/bin/sh
# Имя новой группы следует за выбранными наборами, пока пользователь не правит его сам.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_group_name_ui: нет node"; exit 0; }
TMPD=$(mktemp -d /tmp/test-constructor-group-name-ui.XXXXXX)
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
  get nextSibling() {
    if (!this.parentNode) { return null; }
    return this.parentNode.children[this.parentNode.children.indexOf(this) + 1] || null;
  }
  get offsetHeight() { return 0; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; return child; }
  insertBefore(child, before) {
    if (!before) { return this.appendChild(child); }
    child.parentNode = this; this.children.splice(this.children.indexOf(before), 0, child); return child;
  }
  setAttribute(key, value) { this.attrs[key] = value; }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  fire(type) { (this.listeners[type] || []).forEach(listener => listener({ preventDefault() {} })); }
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
globalThis.fetch = async url => ({ ok: true, json: async () => {
  if (url === '/api/constructor/catalog') {
    return { text: 'alpha\tdomain\tmetacubex\thttps://example.org/a.mrs\tAlpha\n' +
      'beta\tdomain\tmetacubex\thttps://example.org/b.mrs\tBeta\n' };
  }
  if (url === '/api/constructor/icons') { return { text: '' }; }
  return { defaults: '', services: '', user_rules: '', template_base: '', subscriptions: '', proxies: '',
    geofilter: '', geofilter_default: '', block: '' };
} });
const { renderConstructor } = await import(pathToFileURL(process.argv[2]).href);
renderConstructor(new Element('div'));
function all(node, match) { return (match(node) ? [node] : []).concat(node.children.flatMap(child => all(child, match))); }
function one(node, match, message) { const found = all(node, match)[0]; if (!found) { throw new Error(message); } return found; }
function button(text) { return one(app, n => n.tag === 'button' && n.textContent === text, 'нет кнопки ' + text); }
function field(label) { return one(body, n => n.attrs['aria-label'] === label, 'нет поля ' + label); }
function pick(name, checked) {
  const cb = one(body, n => n.tag === 'input' && n.type === 'checkbox' &&
    n.parentNode?.textContent.includes(name), 'нет набора ' + name);
  cb.checked = checked; cb.fire('change');
}
function assertName(expected, step) {
  const actual = field('Имя группы').value;
  if (actual !== expected) { throw new Error(step + ': имя группы ' + JSON.stringify(actual) + ', ожидалось ' + JSON.stringify(expected)); }
}
await new Promise(resolve => setTimeout(resolve, 0));
button('+ Добавить сервис из базы').click();
await new Promise(resolve => setTimeout(resolve, 0));
const search = field('Поиск по базе');
search.value = 'alpha'; search.fire('input'); pick('alpha', true);
assertName('Alpha', 'выбран первый набор');
search.value = 'beta'; search.fire('input'); pick('beta', true);
search.value = 'alpha'; search.fire('input'); pick('alpha', false);
assertName('Beta', 'после снятия первого набора');
search.value = 'beta'; search.fire('input'); pick('beta', false);
assertName('', 'после снятия всех наборов');
search.value = 'alpha'; search.fire('input'); pick('alpha', true);
const name = field('Имя группы'); name.value = 'Моя группа'; name.fire('input');
search.value = 'beta'; search.fire('input'); pick('beta', true);
search.value = 'alpha'; search.fire('input'); pick('alpha', false);
assertName('Моя группа', 'введённое вручную имя сохранено');
console.log('OK test_constructor_group_name_ui');
JS
