#!/bin/sh
# Фильтры бэкапов: чистая фильтрация и DOM без сетевых запросов при вводе.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_config_backups_ui: нет node"; exit 0; }
node - "$ROOT/web/stats_app_config.js" <<'JS'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function assert(value, message) { if (!value) { throw new Error(message); } }
function eq(actual, expected, message) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message + ': ' + JSON.stringify(actual) + ' != ' + JSON.stringify(expected));
  }
}
const a = src.indexOf('function fmtBackupName');
const b = src.indexOf('// GET /api/config*', a);
assert(a >= 0 && b > a, 'не найден блок форматирования и фильтров бэкапов');
assert(src.slice(a, b).includes('function filterBackups'), 'нет filterBackups()');
assert(src.slice(a, b).includes('function createBackupBrowser'), 'нет createBackupBrowser()');

class Element {
  constructor(tag) {
    this.tag = tag; this.children = []; this.listeners = {}; this.attrs = {};
    this.className = ''; this.value = ''; this.type = ''; this.hidden = false;
    this.disabled = false; this.parentNode = null; this._text = '';
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; return child; }
  setAttribute(key, value) { this.attrs[key] = String(value); }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
  fire(type) { (this.listeners[type] || []).forEach(listener => listener({ preventDefault() {} })); }
  click() { this.fire('click'); }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
}
function el(tag, className, text) {
  const node = new Element(tag);
  if (className) { node.className = className; }
  if (text !== undefined && text !== null) { node.textContent = text; }
  return node;
}
const { filterBackups, createBackupBrowser } = new Function('el', src.slice(a, b) +
  '\nreturn { filterBackups, createBackupBrowser };')(el);
function all(node, match) { return (match(node) ? [node] : []).concat(node.children.flatMap(child => all(child, match))); }
function one(node, match, message) { const found = all(node, match)[0]; assert(found, message); return found; }
function field(body, label) { return one(body, n => n.attrs['aria-label'] === label, 'нет поля ' + label); }
function rows(body) { return all(body, n => n.tag === 'tr'); }
function action(body, text) {
  return one(rows(body)[0], n => n.tag === 'button' && n.textContent === text, 'нет кнопки ' + text);
}

const sample = [
  { kind: 'edit', name: 'config.yaml.2026-11-02_134400-2.bak', size: 20 },
  { kind: 'setup', name: 'config.yaml.2026-11-02_134400.bak', size: 30 },
  { kind: 'edit', name: 'config.yaml.2026-11-01_235959.bak', size: 40 },
  { kind: 'edit', name: 'config.yaml.not-a-date.bak', size: 50 },
  { kind: 'edit', name: 'config.yaml.2026-02-30_000000.bak', size: 60 },
  { kind: 'edit', name: 'config.yaml.2026-11-02_134400-0.bak', size: 70 }
];
eq(filterBackups(sample, { from: '2026-11-02', to: '2026-11-02', kind: 'edit', query: '-2.BAK' }), [sample[0]], 'независимый пример сочетания фильтров');
eq(filterBackups(sample, { from: '2026-11-01', to: '2026-11-02', kind: 'all', query: '' }), sample.slice(0, 3), 'границы периода включены');
eq(filterBackups(sample, { from: '2026-11-02', to: '', kind: 'all', query: '' }), sample.slice(0, 2), 'открытая нижняя граница');
eq(filterBackups(sample, { from: '', to: '2026-11-01', kind: 'all', query: '' }), [sample[2]], 'открытая верхняя граница');
eq(filterBackups(sample, { from: '', to: '', kind: 'setup', query: '' }), [sample[1]], 'фильтр источника');
eq(filterBackups(sample, { from: '', to: '', kind: 'all', query: 'NOT-A-DATE' }), [sample[3]], 'поиск без учёта регистра');
eq(filterBackups(sample, { from: '2026-11-03', to: '2026-11-01', kind: 'all', query: '' }), [], 'диапазон наоборот');
const unfiltered = filterBackups(sample, {});
eq(unfiltered, sample, 'без фильтров видны все копии и порядок сохранён');
assert(unfiltered[0] === sample[0] && unfiltered[4] === sample[4], 'фильтр возвращает исходные объекты');

const domRows = sample.slice(0, 4);
let loadCalls = 0;
const compared = [], edited = [], restored = [], errors = [];
const body = new Element('div');
const browser = createBackupBrowser({
  body,
  load() { loadCalls++; return Promise.resolve({ backups: domRows, keep: 20 }); },
  compare(b) { compared.push(b); },
  edit(b) { edited.push(b); },
  restore(b) { restored.push(b); },
  error(text) { errors.push(text); }
});
async function main() {
  await browser.load();
  eq(loadCalls, 1, 'первая загрузка');
  eq(rows(body).length, 4, 'все строки после загрузки');
  assert(!field(body, 'С').hidden, 'поле даты «С» доступно');
  assert(!field(body, 'По').hidden, 'поле даты «По» доступно');
  field(body, 'С').value = '2026-11-02'; field(body, 'С').fire('input');
  field(body, 'По').value = '2026-11-02'; field(body, 'По').fire('input');
  field(body, 'Источник').value = 'edit'; field(body, 'Источник').fire('change');
  field(body, 'Имя файла').value = '-2.BAK'; field(body, 'Имя файла').fire('input');
  eq(loadCalls, 1, 'ввод фильтров не вызывает запросы');
  eq(rows(body).length, 1, 'сочетание фильтров в DOM');
  assert(rows(body)[0].textContent.includes(domRows[0].name), 'показана исходная первая строка');
  one(body, n => n.className.includes('config-backup-count'), 'нет счётчика');
  action(body, 'Сравнить').click();
  action(body, 'В редактор').click();
  action(body, 'Откатить').click();
  assert(compared[0] === domRows[0], 'сравнение использует исходный kind/name');
  assert(edited[0] === domRows[0], 'редактор использует исходный kind/name');
  assert(restored[0] === domRows[0], 'откат использует исходный kind/name');

  field(body, 'Имя файла').value = 'no-match'; field(body, 'Имя файла').fire('input');
  eq(rows(body).length, 0, 'нет строк без совпадений');
  assert(body.textContent.includes('Нет подходящих бэкапов'), 'отдельное сообщение об отсутствии совпадений');
  assert(!body.textContent.includes('Бэкапов пока нет'), 'пустой результат не выглядит как отсутствие бэкапов');
  assert(restored.length === 1, 'изменение фильтра не запускает восстановление');

  one(body, n => n.tag === 'button' && n.textContent === 'Сбросить', 'нет кнопки сброса').click();
  eq(rows(body).length, 4, 'сброс возвращает все строки');
  eq(field(body, 'Имя файла').value, '', 'сброс очищает поиск');
  field(body, 'Имя файла').value = '-2.bak'; field(body, 'Имя файла').fire('input');
  await browser.load();
  eq(field(body, 'Имя файла').value, '-2.bak', 'обновление списка сохраняет фильтр');
  eq(rows(body).length, 1, 'обновление применяет сохранённый фильтр');

  field(body, 'С').value = '2026-11-03'; field(body, 'С').fire('input');
  field(body, 'По').value = '2026-11-01'; field(body, 'По').fire('input');
  assert(body.textContent.includes('Дата «С» позже даты «По»'), 'диапазон наоборот показывает ошибку');
  eq(rows(body).length, 0, 'диапазон наоборот не показывает таблицу');
  eq(errors, [], 'локальная фильтрация не вызывает сетевых ошибок');

  const emptyBody = new Element('div');
  const empty = createBackupBrowser({
    body: emptyBody,
    load() { return Promise.resolve({ backups: [], keep: 20 }); },
    compare() {}, edit() {}, restore() {}, error() {}
  });
  await empty.load();
  assert(emptyBody.textContent.includes('Бэкапов пока нет'), 'пустой исходный список имеет своё сообщение');
  assert(!emptyBody.textContent.includes('Нет подходящих бэкапов'), 'пустой исходный список не сообщает о фильтрах');
  console.log('OK test_config_backups_ui');
}
main().catch(error => { console.error('FAIL: ' + error.message); process.exit(1); });
JS
