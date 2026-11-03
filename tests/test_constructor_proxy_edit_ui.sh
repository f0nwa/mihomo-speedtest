#!/bin/sh
# Обычный редактор собственных AWG/TrustTunnel меняет только черновик конструктора.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_proxy_edit_ui: нет node"; exit 0; }
TMPD=$(mktemp -d /tmp/test-constructor-proxy-edit-ui.XXXXXX)
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
    this.checked = false; this.type = ''; this.classList = { toggle: () => {} };
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; }
  setAttribute(key, value) { this.attrs[key] = String(value); }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  fire(type) { (this.listeners[type] || []).forEach(listener => listener({ preventDefault() {}, key: '' })); }
  click() { if (!this.disabled) { this.fire('click'); } }
  focus() {}
  blur() { this.fire('change'); }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
}
globalThis.document = {
  getElementById() { return null; },
  createElement(tag) { return new Element(tag); },
  createTextNode(text) { const n = new Element('#text'); n.textContent = text; return n; },
};
const requests = [];
globalThis.fetch = async (url, opts) => {
  requests.push({ url, method: (opts && opts.method) || 'GET' });
  return { ok: true, status: 200, json: async () => ({ manual: {} }) };
};
const { createModuleCards } = await import(pathToFileURL(process.argv[2]).href);
const { createModules } = await import(pathToFileURL(process.argv[3]).href);
const WG = "  - name: 'WG test'\n    type: wireguard\n    server: 192.0.2.1\n    port: 51820\n    ip: 10.0.0.2\n    private-key: 'SECRET-WG-PRIVATE'\n    mtu: 1400\n    persistent-keepalive: 0\n    amnezia-wg-option:\n      jc: 3\n";
const TT = "  - name: 'TT test'\n    type: trusttunnel\n    server: 192.0.2.2\n    port: 443\n    username: test\n    password: 'SECRET-TT-PASSWORD'\n    sni: tt.example\n    quic: false\n    client-fingerprint: firefox\n    alpn: ['h2', 'h3']\n";
const SOURCE = WG + TT;
function findAll(node, match) { return (match(node) ? [node] : []).concat(node.children.flatMap(child => findAll(child, match))); }
function assert(value, message) { if (!value) { throw new Error(message); } }
function one(root, match, message) { const found = findAll(root, match); assert(found.length === 1, message + ': найдено ' + found.length); return found[0]; }
function byLabel(root, label) { return one(root, n => n.attrs['aria-label'] === label, 'элемент ' + label); }
function byButton(root, text) { return one(root, n => n.tag === 'button' && n.textContent === text, 'кнопка ' + text); }
function visibleText(node) { return node.hidden ? '' : node._text + (node.tag === 'textarea' ? node.value : '') + node.children.map(child => visibleText(child)).join(''); }

function setup(source) {
  const mods = createModules({ subscriptions: '', proxies: source, geofilter: null, geofilter_default: '' });
  const bodies = {}, messages = [];
  let cards;
  const ctx = {
    mods, model: { ownScope: () => false, baseGroups: () => [], routes: () => [] }, savedWords: [],
    layout: { add(num) { const body = new Element('div'); bodies[num] = body; return { body, summary() {}, changed() {} }; } },
    edit(fn) { try { fn(); } catch (e) { messages.push(e.message); } cards.render(); },
    msg(text, kind) { messages.push(kind + ':' + text); }, redraw() {}, changed() {},
  };
  cards = createModuleCards(ctx);
  cards.render();
  return { mods, root: bodies[2], messages, initial: mods.serialize() };
}
function edit(app, name) { byLabel(app.root, 'Изменить ноду ' + name).click(); assert(app.root.textContent.includes(name), 'редактор ноды ' + name); return one(app.root, n => n.className.includes('cx-proxy-editor'), 'форма редактора'); }

const app = setup(SOURCE);
assert(!visibleText(app.root).includes('SECRET-WG-PRIVATE') && !visibleText(app.root).includes('SECRET-TT-PASSWORD'), 'секреты не видны в списке');
let form = edit(app, 'WG test');
const mtu = byLabel(form, 'MTU ноды WG test');
assert(mtu.value === '1400', 'MTU прочитано из YAML');
mtu.value = '1280'; mtu.fire('input');
byButton(form, 'Готово').click();
assert(app.mods.getProxyYaml('WG test').includes('mtu: 1280'), 'Готово меняет MTU в черновике');
assert(app.mods.getProxyYaml('WG test').includes('persistent-keepalive: 0'), 'no-op существующего keepalive 0');
assert(!app.mods.getProxyYaml('WG test').includes('client-fingerprint'), 'форма не добавляет чужие defaults');
assert(app.mods.getProxyYaml('WG test').includes('amnezia-wg-option:\n      jc: 3'), 'вложенные AWG-поля сохранены');
assert(app.mods.summary(app.initial).join('\n') === 'Нода WG test: изменены mtu', 'сводка называет изменённое поле без значения');
assert(!app.mods.summary(app.initial).join('\n').includes('SECRET'), 'секреты не попадают в сводку');

form = edit(app, 'WG test');
byLabel(form, 'MTU ноды WG test').value = '576';
byButton(form, 'Отмена').click();
assert(app.mods.getProxyYaml('WG test').includes('mtu: 1280'), 'Отмена не меняет черновик');
assert(!findAll(app.root, n => n.className.includes('cx-proxy-editor')).length, 'форма закрыта после отмены');

form = edit(app, 'WG test');
byLabel(form, 'MTU ноды WG test').value = '576';
byLabel(form, 'Вернуть сохранённый MTU').click();
assert(byLabel(form, 'MTU ноды WG test').value === '1280', 'MTU возвращается к сохранённому значению отдельно');
byLabel(form, 'MTU ноды WG test').value = '';
byButton(form, 'Готово').click();
assert(app.mods.getProxyYaml('WG test').includes('mtu: 1280'), 'пустое MTU не означает удаление или ноль');
assert(app.messages.some(x => x.includes('MTU')), 'пустое MTU объясняет ошибку');
form = one(app.root, n => n.className.includes('cx-proxy-editor'), 'форма остаётся после ошибки');
byLabel(form, 'Удалить поле MTU').checked = true;
byButton(form, 'Готово').click();
assert(!app.mods.getProxyYaml('WG test').includes('mtu:') && !app.mods.getProxyYaml('WG test').includes('1408'), 'удаление MTU явное и без подстановки default');

form = edit(app, 'WG test');
const keepOn = byLabel(form, 'Включить Persistent Keepalive');
keepOn.checked = true; keepOn.fire('change');
const keep = byLabel(form, 'Keepalive ноды WG test');
keep.value = '25';
byButton(form, 'Готово').click();
assert(app.mods.getProxyYaml('WG test').includes('persistent-keepalive: 25'), 'keepalive включается числом');
form = edit(app, 'WG test');
byLabel(form, 'Включить Persistent Keepalive').checked = false;
byLabel(form, 'Вернуть сохранённый Keepalive').click();
assert(byLabel(form, 'Включить Persistent Keepalive').checked && byLabel(form, 'Keepalive ноды WG test').value === '25', 'keepalive возвращается к сохранённому значению отдельно');
byLabel(form, 'Включить Persistent Keepalive').checked = false;
byButton(form, 'Готово').click();
assert(!app.mods.getProxyYaml('WG test').includes('persistent-keepalive:'), 'keepalive выключается удалением');

form = edit(app, 'TT test');
const transport = byLabel(form, 'Транспорт TrustTunnel');
assert(transport.value === 'h2', 'исходный транспорт HTTP/2');
transport.value = 'h3'; transport.fire('change');
assert(byLabel(form, 'Client Fingerprint').disabled, 'fingerprint неактивен для QUIC');
assert(form.textContent.includes('1.19.32'), 'есть пояснение для проверенной версии Mihomo');
byButton(form, 'Готово').click();
assert(app.mods.getProxyYaml('TT test').includes('quic: true'), 'включён QUIC');
assert(app.mods.getProxyYaml('TT test').includes('client-fingerprint: firefox'), 'QUIC сохраняет fingerprint');
form = edit(app, 'TT test');
byLabel(form, 'Транспорт TrustTunnel').value = 'h2';
byLabel(form, 'Client Fingerprint').value = 'chrome';
byButton(form, 'Готово').click();
assert(app.mods.getProxyYaml('TT test').includes('quic: false') && app.mods.getProxyYaml('TT test').includes('client-fingerprint: chrome'), 'HTTP/2 и fingerprint меняются независимо');
form = edit(app, 'TT test');
const fp = byLabel(form, 'Client Fingerprint');
fp.value = 'safari'; fp.value = '__saved__';
byButton(form, 'Готово').click();
assert(app.mods.getProxyYaml('TT test').includes('client-fingerprint: chrome'), '«Как в сохранённом конфиге» отменяет изменение поля');

byLabel(app.root, 'Убрать WG test').click();
assert(!app.mods.serialize().proxies.includes('WG test'), 'ноду можно убрать после редактирования');
byLabel(app.root, 'Вернуть WG test').click();
assert(app.mods.getProxyYaml('WG test').includes('persistent-keepalive') === false, 'возврат сохраняет отредактированный черновик');
assert(requests.every(r => r.method === 'GET'), 'редактор не отправляет записи до общего применения');
assert(!app.messages.join('\n').includes('SECRET') && !visibleText(app.root).includes('SECRET'), 'секреты не попадают в сообщения и видимый DOM');

const incompatible = setup(SOURCE.replace("alpn: ['h2', 'h3']", "alpn: ['h2']"));
form = edit(incompatible, 'TT test');
byLabel(form, 'Транспорт TrustTunnel').value = 'h3';
byButton(form, 'Готово').click();
assert(incompatible.mods.getProxyYaml('TT test').includes('quic: false'), 'несовместимый ALPN не меняет транспорт');
assert(incompatible.messages.some(x => x.includes('h3') && x.includes('ALPN')), 'несовместимость ALPN показана');
assert(!incompatible.mods.getProxyYaml('TT test').includes("alpn: ['h3']"), 'форма не меняет ALPN молча');

const custom = setup(SOURCE.replace('client-fingerprint: firefox', 'client-fingerprint: provider-custom'));
form = edit(custom, 'TT test');
assert(byLabel(form, 'Client Fingerprint').value === '__custom__', 'неизвестный fingerprint показан как пользовательский');
byButton(form, 'Готово').click();
assert(custom.mods.getProxyYaml('TT test').includes('client-fingerprint: provider-custom'), 'пользовательский fingerprint сохраняется без действия');

const unsupported = setup(SOURCE.replace('mtu: 1400', 'mtu: { value: 1400 }'));
form = edit(unsupported, 'WG test');
assert(byLabel(form, 'MTU ноды WG test').disabled, 'сложный MTU недоступен в обычной форме');
byButton(form, 'Готово').click();
assert(unsupported.mods.getProxyYaml('WG test').includes('mtu: { value: 1400 }'), 'неподдерживаемое поле не переписывается');

const advanced = setup(SOURCE);
form = edit(advanced, 'WG test');
assert(!visibleText(form).includes('SECRET-WG-PRIVATE'), 'обычная вкладка не показывает секреты');
byLabel(form, 'MTU ноды WG test').value = '576';
byButton(form, 'Расширенный YAML').click();
let yaml = byLabel(form, 'YAML ноды WG test');
assert(yaml.value === WG, 'расширенная вкладка показывает полный исходный блок');
assert(visibleText(form).includes('SECRET-WG-PRIVATE'), 'секрет виден только после явного открытия YAML');
const changedYaml = WG.replace('mtu: 1400', 'mtu: 1280').replace('jc: 3', 'jc: 4').replace('SECRET-WG-PRIVATE', 'NEW-YAML-SECRET');
yaml.value = changedYaml;
byButton(form, 'Обычные поля').click();
assert(byLabel(form, 'MTU ноды WG test').value === '576', 'переключение вкладок не стирает черновик обычной формы');
byButton(form, 'Расширенный YAML').click();
assert(byLabel(form, 'YAML ноды WG test').value === changedYaml, 'переключение вкладок не стирает черновик YAML');
byButton(form, 'Готово').click();
assert(advanced.mods.getProxyYaml('WG test') === changedYaml, 'Готово сохраняет расширенный YAML атомарно');
const advancedSummary = advanced.mods.summary(advanced.initial).join('\n');
assert(advancedSummary === 'Нода WG test: изменены private-key, mtu, amnezia-wg-option', 'DOM-сводка содержит только имена полей');
assert(!advancedSummary.includes('SECRET') && !advancedSummary.includes('1280') && !advancedSummary.includes('jc: 4'), 'DOM-сводка не содержит значений');
assert(!advanced.messages.join('\n').includes('SECRET'), 'значения секретов не попадают в сообщения');

form = edit(advanced, 'WG test');
byButton(form, 'Расширенный YAML').click();
yaml = byLabel(form, 'YAML ноды WG test');
assert(yaml.value === changedYaml, 'повторное открытие показывает сохранённый расширенный черновик');
yaml.value = changedYaml.replace('mtu: 1280', 'mtu: 1500');
byButton(form, 'Отмена').click();
assert(advanced.mods.getProxyYaml('WG test') === changedYaml, 'Отмена не применяет несохранённый YAML');
assert(!visibleText(advanced.root).includes('SECRET'), 'после закрытия редактора секреты исчезают из видимого DOM');

form = edit(advanced, 'WG test');
byButton(form, 'Расширенный YAML').click();
yaml = byLabel(form, 'YAML ноды WG test');
yaml.value = changedYaml.replace('type: wireguard', 'type: trusttunnel');
byButton(form, 'Готово').click();
assert(advanced.mods.getProxyYaml('WG test') === changedYaml, 'ошибочный YAML не меняет модель');
assert(advanced.messages.some(x => /type|протокол/i.test(x)), 'смена type отклонена с понятным сообщением');
form = one(advanced.root, n => n.className.includes('cx-proxy-editor'), 'расширенный редактор остаётся после ошибки');
byButton(form, 'Отмена').click();
assert(requests.every(r => r.method === 'GET'), 'расширенный редактор не отправляет записи до общего применения');

// Ответ фонового GET не должен стереть поля открытого редактора.
let providerResolve;
globalThis.fetch = async () => new Promise(resolve => {
  providerResolve = () => resolve({ ok: true, status: 200, json: async () => ({ manual: {} }) });
});
const pending = setup(SOURCE);
form = edit(pending, 'WG test');
byLabel(form, 'MTU ноды WG test').value = '1280';
providerResolve();
await new Promise(resolve => setTimeout(resolve, 0));
assert(byLabel(pending.root, 'MTU ноды WG test').value === '1280', 'фоновый ответ провайдеров не стирает несохранённый MTU');

console.log('OK test_constructor_proxy_edit_ui');
JS
