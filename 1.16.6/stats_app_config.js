// Вкладка «Конфиг» (/config): редактор config.yaml на CodeMirror 5.

import { app, card, clearApp, el, fetchJson, nextView, setLoading, showError, viewGuard } from './app-core.js';
import { constructorDirty, leaveConstructor, renderConstructor } from './app-constructor.js';

// ----- раздел "Конфиг" (/api/config/*, stats_config.sh) -----
//
// Редактор config.yaml Mihomo на CodeMirror 5 (stats_codemirror.js,
// вендоренная сборка, раздаётся как codemirror.js). Библиотека грузится
// только при открытии вкладки, остальные разделы её не ждут. Если она
// не загрузилась - редактор работает на обычном textarea.
// Сохранение, откат и починка выполняются на роутере (stats_config.sh):
// mihomo -t, бэкап, атомарная замена, xkeen -restart, автооткат.

var configView = null;   // {dirty:bool} - есть несохранённые правки

export function configDirty() { return !!(configView && configView.dirty) || constructorDirty(); }

// Вызывается при уходе с вкладки (render() в app.js).
var activeNav = null;    // createConfigNav() открытой вкладки YAML
export function leaveConfig() {
  configView = null;
  if (activeNav) { activeNav.destroy(); activeNav = null; }
  leaveConstructor();
}

// Режим вкладки: «YAML» (редактор ниже, по умолчанию) или «Конструктор»
// (stats_app_constructor.js). Выбор запоминается в браузере; миграция с
// карточки «Обновлений» всегда открывает YAML.
var MODE_KEY = 'mst-config-mode';
function savedMode() {
  try { return localStorage.getItem(MODE_KEY) === 'constructor' ? 'constructor' : 'yaml'; } catch (e) { return 'yaml'; }
}
function saveMode(m) { try { localStorage.setItem(MODE_KEY, m); } catch (e) { /* без запоминания */ } }

function modeBar(current) {
  var bar = el('div', 'config-mode-bar');
  var group = el('div', 'xk-mode');
  group.setAttribute('role', 'group');
  group.setAttribute('aria-label', 'Режим редактирования конфига');
  [['constructor', 'Конструктор'], ['yaml', 'YAML']].forEach(function (m) {
    var b = el('button', null, m[1]);
    b.type = 'button';
    b.setAttribute('aria-pressed', m[0] === current ? 'true' : 'false');
    b.addEventListener('click', function () {
      if (m[0] === current) { return; }
      if (configDirty() && !window.confirm('Несохранённые правки пропадут. Переключить режим?')) { return; }
      saveMode(m[0]);
      leaveConfig();
      nextView();   // запоздалый ответ прежнего режима не перерисует новый
      renderConfig();
    });
    group.appendChild(b);
  });
  bar.appendChild(group);
  bar.appendChild(el('span', 'hint', current === 'yaml'
    ? 'Ручная правка config.yaml. Изменения групп и правил отсюда конструктор заметит и предложит перенести.'
    : 'Сервисы, домены и правила без правки кода.'));
  return bar;
}

export function renderConfig() {
  if (pendingMigration || pendingAction || savedMode() !== 'constructor') { renderYaml(modeBar('yaml')); return; }
  renderConstructor(modeBar('constructor'), { renderDiff: renderDiff, templateAction: templateActionFromConstructor });
}

// Карточка «Доступно обновление конфига» (вкладка «Обновления») просит
// сразу после открытия вкладки запустить «Миграцию к шаблону» - без
// повторного подтверждения, всё объяснено в карточке.
var pendingMigration = false;
export function requestTemplateMigration() { pendingMigration = true; }

// «Миграция к шаблону» / «Заменить шаблоном…» нажали в панели конструктора:
// действия работают с текстом и применением config.yaml, поэтому открывается
// режим YAML и действие запускается там (со своими подтверждениями).
var pendingAction = null;
function templateActionFromConstructor(name) {
  if (configDirty() && !window.confirm('Несохранённые правки конструктора пропадут. Перейти в YAML и выполнить действие?')) { return; }
  pendingAction = name;
  saveMode('yaml');
  leaveConfig();
  nextView();
  renderConfig();
}
var codeMirrorPromise = null;

function loadCodeMirror() {
  if (window.CodeMirror) { return Promise.resolve(window.CodeMirror); }
  if (codeMirrorPromise) { return codeMirrorPromise; }
  // Стили ждём вместе со скриптом: CodeMirror меряет строки при создании,
  // и без своих стилей рисует пустое поле до первой прокрутки.
  var cssReady = new Promise(function (resolve) {
    var link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = 'codemirror.css';
    link.onload = resolve;
    link.onerror = resolve;
    document.head.appendChild(link);
  });
  codeMirrorPromise = cssReady.then(function () { return new Promise(function (resolve, reject) {
    var s = document.createElement('script');
    s.src = 'codemirror.js';
    s.onload = function () {
      if (window.CodeMirror) { defineYamlMode(window.CodeMirror); resolve(window.CodeMirror); }
      else { reject(new Error('CodeMirror не загрузился')); }
    };
    s.onerror = function () { codeMirrorPromise = null; reject(new Error('codemirror.js не загрузился')); };
    document.head.appendChild(s);
  }); });
  return codeMirrorPromise;
}

// Упрощённая подсветка YAML (ключи, комментарии, строки, числа,
// true/false/null, якоря, теги). Разбор YAML не нужен - проверку делает
// сам mihomo -t на роутере.
function defineYamlMode(CM) {
  CM.defineMode('mst-yaml', function () {
    var END = /^(?=\s*(#|$|,|\]|\}))/;
    function quoted(stream, q) {
      while (!stream.eol()) {
        var c = stream.next();
        if (q === '"' && c === '\\') { stream.next(); }
        else if (c === q) { if (q === "'" && stream.peek() === "'") { stream.next(); } else { break; } }
      }
    }
    return {
      startState: function () { return { keyDone: false }; },
      token: function (stream, state) {
        if (stream.sol()) { state.keyDone = false; }
        if (stream.eatSpace()) { return null; }
        var ch = stream.peek();
        var prev = stream.pos > 0 ? stream.string.charAt(stream.pos - 1) : ' ';
        if (ch === '#' && /\s/.test(prev)) { stream.skipToEnd(); return 'comment'; }
        if (stream.sol() && stream.match(/^(---|\.\.\.)\s*$/)) { return 'def'; }
        if (stream.match(/^-(?=\s|$)/)) { return 'meta'; }
        if (stream.match(/^:(?=\s|$)/)) { state.keyDone = true; return 'meta'; }
        if (ch === '"' || ch === "'") {
          stream.next(); quoted(stream, ch);
          return (!state.keyDone && stream.match(/^\s*:(?=\s|$)/, false)) ? 'property' : 'string';
        }
        if (stream.match(/^[&*][^\s,\[\]{}]+/)) { return 'variable-2'; }
        if (stream.match(/^![^\s]*/)) { return 'tag'; }
        if (/[\[\]{},]/.test(ch)) { stream.next(); return 'bracket'; }
        if (!state.keyDone && stream.match(/^[^\s#'"\[\]{},][^#]*?(?=:(\s|$))/)) { return 'property'; }
        var start = stream.pos;
        if (stream.match(/^(true|false|yes|no|on|off|null|~)/i)) {
          if (stream.match(END, false)) { return 'atom'; }
          stream.pos = start;
        }
        if (stream.match(/^[-+]?(0x[0-9a-fA-F]+|\d+(\.\d+)?)/)) {
          if (stream.match(END, false)) { return 'number'; }
          stream.pos = start;
        }
        var flow = /[\[{]/.test(stream.string);
        while (!stream.eol()) {
          var c = stream.peek();
          if (/\s/.test(c) && /^\s+#/.test(stream.string.slice(stream.pos))) { break; }
          if (flow && /[,\]}]/.test(c)) { break; }
          stream.next();
        }
        if (stream.pos === start) { stream.next(); }
        return 'string';
      }
    };
  });
}

// Обёртка, одинаковая для CodeMirror и запасного textarea.
function createEditor(host, text, onChange) {
  return loadCodeMirror().then(function (CM) {
    var cm = CM(host, {
      value: text, mode: 'mst-yaml', lineNumbers: true,
      indentUnit: 2, tabSize: 2, indentWithTabs: false, viewportMargin: Infinity,
      extraKeys: { Tab: function (c) { c.replaceSelection('  '); } }
    });
    var marked = null;
    var importMarks = [];
    if (onChange) { cm.on('change', onChange); }
    return {
      cm: cm,
      getValue: function () { return cm.getValue(); },
      setValue: function (v) { cm.setValue(v); },
      markLine: function (n) {
        if (marked !== null) { cm.removeLineClass(marked, 'background', 'cm-err-line'); marked = null; }
        if (!n || n < 1 || n > cm.lineCount()) { return; }
        marked = n - 1;
        cm.addLineClass(marked, 'background', 'cm-err-line');
        cm.setCursor({ line: marked, ch: 0 });
        cm.scrollIntoView({ line: marked, ch: 0 }, 120);
      },
      // Подсветка импорта: list - [номер строки с 0, 'add'|'mod']; полоса
      // слева (фоновый слой строки, как cm-err-line), снимается clearImport() и setValue().
      markImport: function (list) {
        importMarks.forEach(function (h) { cm.removeLineClass(h[0], 'background', h[1]); });
        importMarks = [];
        (list || []).forEach(function (m) {
          var cls = m[1] === 'mod' ? 'cm-import-mod' : 'cm-import-add';
          var h = cm.addLineClass(m[0], 'background', cls);
          if (h) { importMarks.push([h, cls]); }
        });
      },
      clearImport: function () {
        importMarks.forEach(function (h) { cm.removeLineClass(h[0], 'background', h[1]); });
        importMarks = [];
      },
      refresh: function () { cm.refresh(); }
    };
  })['catch'](function () {
    var ta = el('textarea', 'config-textarea');
    ta.value = text; ta.spellcheck = false;
    if (onChange) { ta.addEventListener('input', onChange); }
    host.appendChild(ta);
    return {
      cm: null,
      getValue: function () { return ta.value; },
      setValue: function (v) { ta.value = v; },
      markLine: function (n) {
        if (!n || n < 1) { return; }
        var lines = ta.value.split('\n');
        var pos = lines.slice(0, n - 1).join('\n').length + (n > 1 ? 1 : 0);
        ta.focus(); ta.setSelectionRange(pos, pos + (lines[n - 1] || '').length);
      },
      markImport: function () {},   // в textarea подсветки нет - только сводка
      clearImport: function () {},
      refresh: function () {}
    };
  });
}

// Построчный diff (LCS). Для конфигов в сотни строк этого достаточно;
// для очень больших текстов показывается только предупреждение.
function lineDiff(a, b) {
  var x = a.split('\n'), y = b.split('\n');
  if (x.length * y.length > 9000000) { return null; }
  var n = x.length, m = y.length, i, j;
  var t = new Array(n + 1);
  for (i = 0; i <= n; i++) { t[i] = new Uint32Array(m + 1); }
  for (i = n - 1; i >= 0; i--) {
    for (j = m - 1; j >= 0; j--) {
      t[i][j] = x[i] === y[j] ? t[i + 1][j + 1] + 1 : Math.max(t[i + 1][j], t[i][j + 1]);
    }
  }
  var out = [];
  i = 0; j = 0;
  while (i < n && j < m) {
    if (x[i] === y[j]) { out.push([' ', x[i]]); i++; j++; }
    else if (t[i + 1][j] >= t[i][j + 1]) { out.push(['-', x[i]]); i++; }
    else { out.push(['+', y[j]]); j++; }
  }
  while (i < n) { out.push(['-', x[i++]]); }
  while (j < m) { out.push(['+', y[j++]]); }
  return out;
}

// Строки нового текста, которых не было в старом: [номер с 0, 'add'|'mod'].
// 'mod' - добавленная строка сразу на месте удалённой (замена), 'add' - новая.
// null - тексты слишком большие для сравнения.
function importLineMarks(before, after) {
  var d = lineDiff(before, after);
  if (d === null) { return null; }
  var out = [], j = 0, del = false;
  d.forEach(function (r) {
    if (r[0] === '-') { del = true; return; }
    if (r[0] === '+') { out.push([j, del ? 'mod' : 'add']); j++; return; }
    del = false; j++;
  });
  return out;
}

// Ограничения импорта WireGuard (см. stats_config.sh import-wg).
var WG_MAX_FILES = 20;
var WG_MAX_BYTES = 65536;

// Отчёт import-wg -> статус для каждой записи окна (по имени ноды; сначала
// ADDED/REPLACED, потом ERROR - так повтор имени отметит ошибкой второй файл).
function importStatuses(entries, report) {
  var lines = (report || []).map(function (l) { return l.split('|'); });
  entries.forEach(function (e) { if (!e.localErr) { e.status = null; e.skipped = []; } });
  function take(name) {
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i];
      if (!e.localErr && e.status === null && e.name === name) { return e; }
    }
    return null;
  }
  lines.forEach(function (p) {
    if (p[0] !== 'ADDED' && p[0] !== 'REPLACED') { return; }
    var e = take(p.slice(1).join('|'));
    if (e) { e.status = p[0] === 'ADDED' ? ['ok', 'новая'] : ['ok', 'заменит существующую']; }
  });
  lines.forEach(function (p) {
    if (p[0] !== 'ERROR') { return; }
    var e = take(p.slice(1, -1).join('|'));
    if (e) { e.status = ['err', 'ошибка: ' + p[p.length - 1]]; }
  });
  lines.forEach(function (p) {
    if (p[0] !== 'SKIPPED_KEY') { return; }
    var name = p.slice(1, -1).join('|');
    entries.forEach(function (e) { if (e.name === name && e.skipped) { e.skipped.push(p[p.length - 1]); } });
  });
}

// Рисует diff: только изменённые строки с 3 строками контекста.
function renderDiff(container, a, b, labelA, labelB) {
  while (container.firstChild) { container.removeChild(container.firstChild); }
  var d = lineDiff(a, b);
  if (d === null) { container.appendChild(el('p', 'hint', 'Файлы слишком большие для сравнения в браузере.')); return; }
  var changed = d.some(function (r) { return r[0] !== ' '; });
  container.appendChild(el('p', 'hint', changed ? ('- ' + labelA + '   + ' + labelB) : 'Отличий нет.'));
  if (!changed) { return; }
  var show = new Array(d.length);
  d.forEach(function (r, k) {
    if (r[0] !== ' ') { for (var q = Math.max(0, k - 3); q <= Math.min(d.length - 1, k + 3); q++) { show[q] = true; } }
  });
  var pre = el('div', 'update-console config-diff');
  var gap = false;
  d.forEach(function (r, k) {
    if (!show[k]) { if (!gap) { pre.appendChild(el('div', 'log-line diff-gap', '...')); gap = true; } return; }
    gap = false;
    var cls = r[0] === '+' ? ' diff-add' : (r[0] === '-' ? ' diff-del' : '');
    pre.appendChild(el('div', 'log-line' + cls, r[0] + ' ' + r[1]));
  });
  container.appendChild(pre);
}

// Двухколоночный diff на месте редактора: слева a (текущий), справа b.
// Весь файл целиком, изменённые строки подсвечены; идущие подряд удаления
// и добавления выстраиваются парами в одну строку таблицы.
function renderSideDiff(container, a, b, labelA, labelB, onClose) {
  while (container.firstChild) { container.removeChild(container.firstChild); }
  var head = el('div', 'config-sdiff-head');
  var close = el('button', 'theme-btn', 'Вернуться к редактору');
  close.type = 'button';
  close.addEventListener('click', onClose);
  head.appendChild(close);
  container.appendChild(head);
  var d = lineDiff(a, b);
  if (d === null) { container.appendChild(el('p', 'hint', 'Файлы слишком большие для сравнения в браузере.')); return; }
  var rows = [], k = 0, li = 0, ri = 0;
  while (k < d.length) {
    if (d[k][0] === ' ') { rows.push([++li, d[k][1], ++ri, d[k][1], '']); k++; continue; }
    var dels = [], adds = [];
    while (k < d.length && d[k][0] === '-') { dels.push(d[k++][1]); }
    while (k < d.length && d[k][0] === '+') { adds.push(d[k++][1]); }
    for (var q = 0; q < Math.max(dels.length, adds.length); q++) {
      var hasL = q < dels.length, hasR = q < adds.length;
      rows.push([hasL ? ++li : '', hasL ? dels[q] : '', hasR ? ++ri : '', hasR ? adds[q] : '',
        hasL && hasR ? 'mod' : (hasL ? 'del' : 'add')]);
    }
  }
  var changed = rows.filter(function (r) { return r[4]; }).length;
  head.appendChild(el('span', 'hint', changed ? ('Изменённых строк: ' + changed) : 'Отличий нет.'));
  var wrap = el('div', 'config-sdiff');
  var table = el('table');
  var th = el('tr', 'config-sdiff-title');
  th.appendChild(el('th', null, ''));
  th.appendChild(el('th', null, labelA));
  th.appendChild(el('th', null, ''));
  th.appendChild(el('th', null, labelB));
  table.appendChild(th);
  var first = null;
  rows.forEach(function (r) {
    var tr = el('tr', r[4] ? 'sd-' + r[4] : null);
    tr.appendChild(el('td', 'sd-n', String(r[0])));
    tr.appendChild(el('td', 'sd-l' + (r[4] === 'del' || r[4] === 'mod' ? ' sd-del' : ''), r[1]));
    tr.appendChild(el('td', 'sd-n', String(r[2])));
    tr.appendChild(el('td', 'sd-r' + (r[4] === 'add' || r[4] === 'mod' ? ' sd-add' : ''), r[3]));
    if (r[4] && !first) { first = tr; }
    table.appendChild(tr);
  });
  wrap.appendChild(table);
  container.appendChild(wrap);
  if (first) { wrap.scrollTop = Math.max(0, first.offsetTop - 60); }
}

var REPAIR_FIX_LABELS = {
  bom: 'убрана метка BOM', crlf: 'переводы строк Windows (CRLF) заменены на LF',
  nbsp: 'неразрывные пробелы заменены обычными', tabs: 'табуляция в отступах заменена пробелами',
  trailing: 'убраны пробелы в конце строк'
};

function fmtBackupName(name) {
  var m = /^config\.yaml\.(\d{4})-(\d\d)-(\d\d)_(\d\d)(\d\d)(\d\d)/.exec(name || '');
  return m ? (m[3] + '.' + m[2] + '.' + m[1] + ' ' + m[4] + ':' + m[5] + ':' + m[6]) : (name || '');
}

// GET /api/config* с проверкой, что пришёл именно JSON редактора.
// fetchJson() молча превращает не-JSON в {} (так задумано для
// /api/stats), а здесь это дало бы пустой редактор, который можно
// сохранить поверх настоящего конфига. Поэтому ответ без поля field -
// ошибка с подробностями (код, тип, начало тела) для диагностики.
function fetchConfigJson(url, field) {
  return fetch(url, { credentials: 'same-origin' }).then(function (r) {
    return r.text().then(function (body) {
      var data = null;
      try { data = JSON.parse(body); } catch (e) { data = null; }
      if (r.status === 401) { return fetchJson(url); }
      if (data && !r.ok) {
        var err = new Error(data.error || ('HTTP ' + r.status));
        err.status = r.status; err.data = data;
        throw err;
      }
      if (!data || typeof data[field] !== 'string') {
        var snippet = String(body || '').replace(/\s+/g, ' ').slice(0, 160);
        throw new Error('неожиданный ответ сервера ' + url + ' (HTTP ' + r.status + ', ' +
          (r.headers.get('Content-Type') || 'без типа') + '): ' + (snippet || 'пустое тело') +
          '. Похоже, stats_config.sh не установлен или завершился с ошибкой - ' +
          'перезапустите веб-службу (/opt/etc/init.d/S80speedtest-stats restart).');
      }
      return data;
    });
  });
}

function postText(url, text) {
  return fetchJson(url, { method: 'POST', body: text, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
}

// ----- Навигатор разделов, поиск и полноэкранный режим (вкладка YAML) -----
//
// Слева от редактора - дерево разделов config.yaml (клик - прокрутка к
// разделу) и поиск: найденные строки показываются прямо под своими
// разделами. Кнопка «На весь экран» разворачивает редактор на всё окно:
// сверху панель с действиями, плавающее окно поиска и замены, снизу строка
// состояния. Поиск - простой подстрокой (без regexp), подсветка через
// markText CodeMirror. На запасном textarea работает только полноэкранный режим.

var SECTION_RU = {
  dns: 'DNS', hosts: 'хосты', tun: 'TUN', sniffer: 'сниффер', listeners: 'входы', profile: 'профиль',
  'proxy-providers': 'подписки', proxies: 'ноды', 'proxy-groups': 'группы',
  'rule-providers': 'наборы правил', rules: 'правила', 'sub-rules': 'подправила',
  'geox-url': 'гео-базы', experimental: 'экспериментальное', ntp: 'время', tunnels: 'туннели'
};
var SEARCH_MARK_LIMIT = 3000;   // больше совпадений не подсвечиваем (счётчик - полный)
var TREE_HITS_LIMIT = 30;       // строк результатов под одним разделом

// Разделы верхнего уровня: ключ-блок («proxies:») - свой раздел, скалярные
// ключи верхнего уровня («mode: rule») собраны в «Общие настройки».
// lineSec[i] - раздел строки i; items - число элементов первого уровня.
export function yamlSections(lines) {
  var general = { name: 'Общие настройки', ru: '', line: -1, items: 0 };
  var secs = [], lineSec = new Array(lines.length), cur = general, childIndent = -1;
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i];
    if (/^[A-Za-z_"'][^:#]*:(\s|$)/.test(l)) {
      var key = l.slice(0, l.indexOf(':')).replace(/^["']|["']$/g, '');
      var val = l.slice(l.indexOf(':') + 1).trim();
      if (/^(&\S+)?\s*(#.*)?$/.test(val)) {
        cur = { name: key, ru: SECTION_RU[key] || '', line: i, items: 0 };
        secs.push(cur);
      } else {
        general.items++;
        if (general.line < 0) { general.line = i; }
        cur = general;
      }
      childIndent = -1;
      lineSec[i] = cur;
      continue;
    }
    lineSec[i] = cur;
    if (cur === general || /^\s*(#|$)/.test(l)) { continue; }
    var ind = /^ */.exec(l)[0].length;
    if (childIndent < 0) { childIndent = ind; }
    if (ind === childIndent && (/^\s*-(\s|$)/.test(l) || (ind > 0 && /^\s*[^\s#-][^:]*:(\s|$)/.test(l)))) { cur.items++; }
  }
  if (general.items > 0 || !secs.length || secs[0].line > 0) {
    if (general.line < 0) { general.line = 0; }
    secs.unshift(general);
  }
  return { secs: secs, lineSec: lineSec };
}

// Подпись строки для «хлебных крошек»: имя элемента списка (- name: X) или ключ.
function crumbLabel(l) {
  var t = l.trim(), m = /^- name:\s*["']?(.+?)["']?\s*(#.*)?$/.exec(t);
  if (m) { return m[1]; }
  m = /^(?:- )?["']?([^"':#\s][^:#]*?)["']?:(\s|$)/.exec(t);
  if (m) { return m[1]; }
  if (/^- /.test(t)) { return t.length > 32 ? t.slice(2, 32) + '…' : t.slice(2); }
  return null;
}

// Путь до строки по отступам: proxy-groups › YouTube › type.
export function yamlCrumbs(getLine, line) {
  var text = getLine(line) || '', out = [], ind = /^ */.exec(text)[0].length;
  var lab = /^\s*(#|$)/.test(text) ? null : crumbLabel(text);
  if (lab) { out.unshift(lab); }
  var needKey = ind === 0 && /^- /.test(text);
  for (var j = line - 1, steps = 0; j >= 0 && (ind > 0 || needKey) && steps < 3000; j--, steps++) {
    var l = getLine(j);
    if (/^\s*(#|$)/.test(l)) { continue; }
    var d = /^ */.exec(l)[0].length;
    if (d < ind || (needKey && d === 0 && !/^- /.test(l))) {
      var lb = crumbLabel(l);
      if (lb) { out.unshift(lb); }
      ind = d;
      needKey = d === 0 && /^- /.test(l);
    }
  }
  return out.slice(-4);
}

export function findAllText(lines, q, cs) {
  var res = [];
  if (!q) { return res; }
  var qq = cs ? q : q.toLowerCase();
  for (var i = 0; i < lines.length; i++) {
    var s = cs ? lines[i] : lines[i].toLowerCase(), p = 0;
    while ((p = s.indexOf(qq, p)) >= 0) { res.push({ line: i, col: p, len: qq.length }); p += qq.length; }
  }
  return res;
}

function svgIcon(d, size) {
  var ns = 'http://www.w3.org/2000/svg';
  var s = document.createElementNS(ns, 'svg');
  s.setAttribute('width', size || 16); s.setAttribute('height', size || 16);
  s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('fill', 'none');
  s.setAttribute('stroke', 'currentColor'); s.setAttribute('stroke-width', '2');
  s.setAttribute('aria-hidden', 'true');
  var p = document.createElementNS(ns, 'path');
  p.setAttribute('d', d);
  s.appendChild(p);
  return s;
}
var ICON = {
  search: 'M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14zM20 20l-3.5-3.5', up: 'M6 15l6-6 6 6', down: 'M6 9l6 6 6-6',
  close: 'M6 6l12 12M18 6L6 18', expand: 'M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5',
  shrink: 'M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5', right: 'M9 6l6 6-6 6'
};

// hooks: { diff, check, save } - кнопки панели полноэкранного режима.
// Возвращает { root, host, attach(editor), setDirty(bool), setCheck(text, kind),
// setBusy(bool), exitFs(), destroy() }; host - куда createEditor() ставит редактор.
function createConfigNav(hooks) {
  var st = { cm: null, editor: null, q: '', cs: false, hits: [], cur: -1, marks: [], curMark: null,
    secs: [], lineSec: [], fs: false, timer: null, secTimer: null, tree: [] };

  function iconBtn(cls, label, icon, size) {
    var b = el('button', cls);
    b.type = 'button';
    b.setAttribute('aria-label', label);
    b.title = label;
    if (icon) { b.appendChild(svgIcon(ICON[icon], size)); }
    return b;
  }
  function csToggle() {
    var b = iconBtn('config-ib', 'Учитывать регистр');
    b.textContent = 'Aa';
    b.setAttribute('aria-pressed', 'false');
    return b;
  }

  var root = el('div', 'config-work');

  // --- левая панель: поиск + дерево разделов
  var aside = el('aside', 'config-nav');
  aside.setAttribute('aria-label', 'Разделы конфига и поиск');
  var navTop = el('div', 'config-nav-top');
  var row = el('div', 'config-nav-row');
  var s1wrap = el('div', 'config-search');
  s1wrap.appendChild(svgIcon(ICON.search, 14));
  var q1 = el('input');
  q1.type = 'text'; q1.spellcheck = false; q1.placeholder = 'Поиск по конфигу (Ctrl+F)';
  q1.setAttribute('aria-label', 'Поиск по конфигу');
  s1wrap.appendChild(q1);
  var cs1 = csToggle();
  row.appendChild(s1wrap); row.appendChild(cs1);
  navTop.appendChild(row);
  var summaryRow = el('div', 'config-nav-row config-nav-summary');
  var summary = el('span', 'hint');
  var clearBtn = el('button', 'config-link', 'очистить');
  clearBtn.type = 'button'; clearBtn.hidden = true;
  summaryRow.appendChild(summary); summaryRow.appendChild(clearBtn);
  navTop.appendChild(summaryRow);
  aside.appendChild(navTop);
  var tree = el('div', 'config-nav-tree');
  aside.appendChild(tree);
  root.appendChild(aside);

  // --- правая часть: панель полноэкранного режима, шапка, редактор, строка состояния
  var pane = el('div', 'config-pane');
  var fsBar = el('div', 'config-fs-bar');
  var exitBtn = el('button', 'theme-btn config-fs-exit');
  exitBtn.type = 'button';
  exitBtn.appendChild(svgIcon(ICON.shrink, 14));
  exitBtn.appendChild(document.createTextNode(' Выйти '));
  exitBtn.appendChild(el('span', 'hint', 'Esc'));
  fsBar.appendChild(exitBtn);
  fsBar.appendChild(el('span', 'config-fs-title', 'config.yaml'));
  var fsDirty = el('span', 'config-fs-dirty', '● есть несохранённые изменения');
  fsDirty.hidden = true;
  fsBar.appendChild(fsDirty);
  var secLabel = el('label', 'config-fs-sec', 'Раздел ');
  var secSelect = el('select');
  secLabel.appendChild(secSelect);
  fsBar.appendChild(secLabel);
  fsBar.appendChild(el('span', 'config-spacer'));
  function fsAction(text, primary, fn) {
    var b = el('button', 'submit' + (primary ? '' : ' secondary'), text);
    b.type = 'button';
    b.addEventListener('click', fn);
    fsBar.appendChild(b);
    return b;
  }
  var fsBtns = [
    fsAction('Изменения', false, function () { exitFs(); hooks.diff(); }),
    fsAction('Проверить', false, function () { setCheck('проверка...', ''); hooks.check(); }),
    fsAction('Сохранить и применить', true, function () { exitFs(); hooks.save(); })
  ];
  pane.appendChild(fsBar);

  var head = el('div', 'config-pane-head');
  var crumbs = el('span', 'config-crumbs', 'config.yaml');
  head.appendChild(crumbs);
  var fsOpen = el('button', 'theme-btn config-fs-open');
  fsOpen.type = 'button';
  fsOpen.title = 'Редактор на всё окно (Esc - выйти)';
  fsOpen.appendChild(svgIcon(ICON.expand, 14));
  fsOpen.appendChild(document.createTextNode(' На весь экран'));
  head.appendChild(fsOpen);
  pane.appendChild(head);

  var edWrap = el('div', 'config-ed-wrap');
  var host = el('div', 'config-editor');
  edWrap.appendChild(host);

  // плавающее окно поиска и замены (только в полноэкранном режиме)
  var find = el('div', 'config-find');
  find.setAttribute('role', 'search');
  find.setAttribute('aria-label', 'Поиск и замена');
  var repToggle = iconBtn('config-ib config-find-toggle', 'Показать замену (Ctrl+H)', 'right', 14);
  repToggle.setAttribute('aria-expanded', 'false');
  find.appendChild(repToggle);
  var findRows = el('div', 'config-find-rows');
  var fr1 = el('div', 'config-find-row');
  var q2 = el('input', 'config-find-input');
  q2.type = 'text'; q2.spellcheck = false; q2.placeholder = 'Найти';
  q2.setAttribute('aria-label', 'Найти');
  var cs2 = csToggle();
  var count2 = el('span', 'config-find-count hint');
  var prevBtn = iconBtn('config-ib', 'Предыдущее (Shift+Enter)', 'up');
  var nextBtn = iconBtn('config-ib', 'Следующее (Enter)', 'down');
  var closeFind = iconBtn('config-ib', 'Очистить поиск', 'close', 14);
  [q2, cs2, count2, prevBtn, nextBtn, closeFind].forEach(function (n) { fr1.appendChild(n); });
  findRows.appendChild(fr1);
  var fr2 = el('div', 'config-find-row');
  fr2.hidden = true;
  var repInput = el('input', 'config-find-input');
  repInput.type = 'text'; repInput.spellcheck = false; repInput.placeholder = 'Заменить на';
  repInput.setAttribute('aria-label', 'Заменить на');
  var repOne = el('button', 'theme-btn', 'Заменить'); repOne.type = 'button';
  var repAll = el('button', 'theme-btn', 'Все'); repAll.type = 'button';
  [repInput, repOne, repAll].forEach(function (n) { fr2.appendChild(n); });
  findRows.appendChild(fr2);
  find.appendChild(findRows);
  edWrap.appendChild(find);
  pane.appendChild(edWrap);

  var statusBar = el('div', 'config-statusbar');
  var stPos = el('span', null, 'Стр 1, кол 1');
  var stLines = el('span');
  var stInfo = el('span', 'config-statusbar-help', 'Ctrl+F поиск · Ctrl+H замена · Enter / Shift+Enter - дальше / назад');
  var stCheck = el('span');
  var stCheckVal = el('span', null, 'не проверялся');
  stCheck.appendChild(document.createTextNode('mihomo -t: '));
  stCheck.appendChild(stCheckVal);
  [stPos, stLines, el('span', 'config-spacer'), stInfo, stCheck].forEach(function (n) { statusBar.appendChild(n); });
  pane.appendChild(statusBar);
  root.appendChild(pane);

  // --- поиск
  function lines() { return st.cm.getValue().split('\n'); }
  function clearMarks() {
    st.marks.forEach(function (m) { m.clear(); });
    st.marks = [];
    if (st.curMark) { st.curMark.clear(); st.curMark = null; }
  }
  function cmpPos(h, line, ch) { return h.line - line || h.col - ch; }
  // keep - оставить номер текущего совпадения (после правки текста);
  // after - {line, ch}: текущим станет первое совпадение не раньше этой позиции
  // (по умолчанию - от курсора).
  function run(opt) {
    if (!st.cm) { return; }
    opt = opt || {};
    var prev = st.cur;
    st.cm.operation(function () {
      clearMarks();
      st.hits = findAllText(lines(), st.q, st.cs);
      for (var i = 0; i < st.hits.length && i < SEARCH_MARK_LIMIT; i++) {
        var h = st.hits[i];
        st.marks.push(st.cm.markText({ line: h.line, ch: h.col }, { line: h.line, ch: h.col + h.len }, { className: 'cm-hit' }));
      }
    });
    if (!st.hits.length) { st.cur = -1; }
    else if (opt.keep && prev >= 0) { st.cur = Math.min(prev, st.hits.length - 1); }
    else {
      var after = opt.after || st.cm.getCursor('from');
      st.cur = 0;
      for (var k = 0; k < st.hits.length; k++) {
        if (cmpPos(st.hits[k], after.line, after.ch) >= 0) { st.cur = k; break; }
      }
    }
    renderTree();
    select(st.cur, !opt.keep);
  }
  function schedule() {
    clearTimeout(st.timer);
    st.timer = setTimeout(function () { st.timer = null; run(); }, 150);
  }
  function select(i, scroll) {
    if (st.curMark) { st.curMark.clear(); st.curMark = null; }
    st.cur = i;
    var n = st.hits.length;
    count2.textContent = !st.q ? '' : (n ? (i + 1) + ' из ' + n : 'нет');
    count2.classList.toggle('config-none', !!st.q && !n);
    Array.prototype.forEach.call(tree.querySelectorAll('.config-nav-hit.on'), function (b) { b.classList.remove('on'); });
    if (i < 0 || !st.cm) { return; }
    var h = st.hits[i];
    var from = { line: h.line, ch: h.col }, to = { line: h.line, ch: h.col + h.len };
    st.curMark = st.cm.markText(from, to, { className: 'cm-hit-cur' });
    if (scroll !== false) {
      st.cm.setCursor(from, null, { scroll: false });
      st.cm.scrollIntoView({ from: from, to: to }, 120);
    }
    var hb = tree.querySelector('.config-nav-hit[data-i="' + i + '"]');
    if (hb) {
      hb.classList.add('on');
      if (scroll !== false) { tree.scrollTop = Math.max(0, hb.offsetTop - tree.offsetTop - tree.clientHeight / 2); }
    }
  }
  function step(d) {
    if (!st.hits.length) { return; }
    select(((st.cur < 0 ? 0 : st.cur + d) % st.hits.length + st.hits.length) % st.hits.length);
  }
  function setQuery(q, from) {
    st.q = q;
    if (from !== q1) { q1.value = q; }
    if (from !== q2) { q2.value = q; }
    clearBtn.hidden = !q;
    schedule();
  }
  function setCs(on) {
    st.cs = on;
    [cs1, cs2].forEach(function (b) { b.setAttribute('aria-pressed', on ? 'true' : 'false'); });
    run();
  }
  function onSearchKey(ev) {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      if (st.timer) { clearTimeout(st.timer); st.timer = null; run(); return; }
      step(ev.shiftKey ? -1 : 1);
    } else if (ev.key === 'Escape') {
      ev.preventDefault(); ev.stopPropagation();
      if (st.q) { setQuery('', null); } else if (st.fs) { exitFs(); } else if (st.cm) { st.cm.focus(); }
    }
  }
  [q1, q2].forEach(function (inp) {
    inp.addEventListener('input', function () { setQuery(inp.value, inp); });
    inp.addEventListener('keydown', onSearchKey);
  });
  [cs1, cs2].forEach(function (b) { b.addEventListener('click', function () { setCs(!st.cs); }); });
  clearBtn.addEventListener('click', function () { setQuery('', null); q1.focus(); });
  closeFind.addEventListener('click', function () { setQuery('', null); q2.focus(); });
  prevBtn.addEventListener('click', function () { step(-1); });
  nextBtn.addEventListener('click', function () { step(1); });

  // --- замена (в полноэкранном режиме)
  function showReplace(on) {
    fr2.hidden = !on;
    repToggle.setAttribute('aria-expanded', on ? 'true' : 'false');
    repToggle.firstChild.firstChild.setAttribute('d', on ? ICON.down : ICON.right);
  }
  repToggle.addEventListener('click', function () { showReplace(fr2.hidden); });
  repInput.addEventListener('keydown', function (ev) {
    if (ev.key === 'Enter') { ev.preventDefault(); repOne.click(); }
    if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); exitFs(); }
  });
  repOne.addEventListener('click', function () {
    if (!st.cm || st.cur < 0) { return; }
    var h = st.hits[st.cur], rep = repInput.value;
    st.cm.replaceRange(rep, { line: h.line, ch: h.col }, { line: h.line, ch: h.col + h.len }, '+mst-replace');
    clearTimeout(st.timer); st.timer = null;
    run({ after: { line: h.line, ch: h.col + rep.length } });
  });
  repAll.addEventListener('click', function () {
    if (!st.cm || !st.hits.length) { return; }
    var rep = repInput.value, list = st.hits.slice();
    st.cm.operation(function () {
      for (var i = list.length - 1; i >= 0; i--) {
        var h = list[i];
        st.cm.replaceRange(rep, { line: h.line, ch: h.col }, { line: h.line, ch: h.col + h.len }, '+mst-replace');
      }
    });
    clearTimeout(st.timer); st.timer = null;
    run({ keep: true });
    setCheck('заменено ' + list.length + ', не проверялся', '');
  });

  // --- дерево разделов
  function renderSections() {
    var r = yamlSections(lines());
    st.secs = r.secs; st.lineSec = r.lineSec;
    while (secSelect.firstChild) { secSelect.removeChild(secSelect.firstChild); }
    st.secs.forEach(function (s, k) {
      var o = el('option', null, s.name + (s.ru ? ' - ' + s.ru : ''));
      o.value = String(k);
      secSelect.appendChild(o);
    });
    stLines.textContent = st.cm.lineCount() + ' строк';
  }
  function goLine(line) {
    st.cm.setCursor({ line: line, ch: 0 }, null, { scroll: false });
    st.cm.scrollTo(null, st.cm.heightAtLine(line, 'local'));
    st.cm.focus();
  }
  function snippet(btn, h) {
    var line = st.cm.getLine(h.line) || '', lead = /^\s*/.exec(line)[0].length, t = line.slice(lead), p = h.col - lead;
    var a = t.slice(Math.max(0, p - 18), p), b = t.slice(p + h.len, p + h.len + 30);
    var span = el('span', 'config-nav-snip');
    span.appendChild(document.createTextNode((p > 18 ? '…' : '') + a));
    span.appendChild(el('mark', null, t.slice(p, p + h.len)));
    span.appendChild(document.createTextNode(b + (p + h.len + 30 < t.length ? '…' : '')));
    btn.appendChild(span);
  }
  function renderTree() {
    while (tree.firstChild) { tree.removeChild(tree.firstChild); }
    var bySec = st.secs.map(function () { return []; });
    st.hits.forEach(function (h, i) {
      var k = st.secs.indexOf(st.lineSec[h.line]);
      if (k >= 0) { bySec[k].push(i); }
    });
    var withHits = 0;
    st.tree = [];
    st.secs.forEach(function (s, k) {
      var b = el('button', 'config-nav-sec');
      b.type = 'button';
      b.appendChild(el('span', 'config-nav-name', s.name));
      if (s.ru) { b.appendChild(el('span', 'config-nav-ru', s.ru)); }
      b.appendChild(el('span', 'config-spacer'));
      if (s.items) { b.appendChild(el('span', 'config-nav-items', String(s.items))); }
      var hits = bySec[k];
      if (hits.length) { withHits++; b.appendChild(el('span', 'config-nav-badge', String(hits.length))); }
      if (st.q && !hits.length) { b.classList.add('dim'); }
      b.addEventListener('click', function () { goLine(s.line); });
      tree.appendChild(b);
      st.tree.push(b);
      hits.slice(0, TREE_HITS_LIMIT).forEach(function (i) {
        var h = st.hits[i];
        var hb = el('button', 'config-nav-hit');
        hb.type = 'button';
        hb.setAttribute('data-i', String(i));
        hb.appendChild(el('span', 'config-nav-ln', String(h.line + 1)));
        snippet(hb, h);
        hb.addEventListener('click', function () { select(i); });
        tree.appendChild(hb);
      });
      if (hits.length > TREE_HITS_LIMIT) {
        tree.appendChild(el('div', 'config-nav-more hint', 'ещё ' + (hits.length - TREE_HITS_LIMIT) + ' - переход по Enter в поле поиска'));
      }
    });
    summary.textContent = !st.q ? (st.secs.length + ' разделов · ' + st.cm.lineCount() + ' строк')
      : (st.hits.length ? st.hits.length + ' совпадений в ' + withHits + ' разделах' : 'ничего не найдено');
    summary.classList.toggle('config-none', !!st.q && !st.hits.length);
    markActiveSection();
  }
  function markActiveSection() {
    if (!st.cm) { return; }
    var k = st.secs.indexOf(st.lineSec[st.cm.getCursor().line]);
    st.tree.forEach(function (b, j) { b.classList.toggle('on', j === k); });
    if (k >= 0) { secSelect.value = String(k); }
  }
  secSelect.addEventListener('change', function () {
    var s = st.secs[Number(secSelect.value)];
    if (s) { goLine(s.line); }
  });

  function onCursor() {
    var c = st.cm.getCursor();
    var path = yamlCrumbs(function (n) { return st.cm.getLine(n); }, c.line);
    crumbs.textContent = ['config.yaml'].concat(path).join(' › ');
    stPos.textContent = 'Стр ' + (c.line + 1) + ', кол ' + (c.ch + 1);
    markActiveSection();
  }

  // --- полноэкранный режим: тот же редактор, развёрнутый на всё окно
  function onDocKey(ev) { if (ev.key === 'Escape' && st.fs) { exitFs(); } }
  function enterFs() {
    if (st.fs) { return; }
    st.fs = true;
    root.classList.add('fs');
    document.body.classList.add('config-fs-on');
    document.addEventListener('keydown', onDocKey);
    if (st.editor) { st.editor.refresh(); }
    if (st.cm) { st.cm.scrollIntoView(null, 120); st.cm.focus(); }
  }
  function exitFs() {
    if (!st.fs) { return; }
    st.fs = false;
    root.classList.remove('fs');
    document.body.classList.remove('config-fs-on');
    document.removeEventListener('keydown', onDocKey);
    if (st.editor) { st.editor.refresh(); }
    if (st.cm) { st.cm.scrollIntoView(null, 120); }
  }
  fsOpen.addEventListener('click', enterFs);
  exitBtn.addEventListener('click', exitFs);

  function focusFind(withReplace) {
    var sel = st.cm.getSelection();
    if (sel && sel.indexOf('\n') < 0) { setQuery(sel, null); }
    if (withReplace) { enterFs(); showReplace(true); }
    var inp = st.fs ? q2 : q1;
    inp.focus(); inp.select();
  }

  function setCheck(text, kind) {
    stCheckVal.textContent = text;
    stCheckVal.className = kind === 'ok' ? 'config-ok' : (kind === 'err' ? 'config-none' : '');
  }

  return {
    root: root, host: host,
    attach: function (editor) {
      st.editor = editor;
      st.cm = editor.cm || null;
      if (!st.cm) {   // запасной textarea: без дерева и поиска
        aside.hidden = true; find.hidden = true; secLabel.hidden = true; stInfo.textContent = '';
        return;
      }
      st.cm.addKeyMap({
        'Ctrl-F': function () { focusFind(false); }, 'Cmd-F': function () { focusFind(false); },
        'Ctrl-H': function () { focusFind(true); }, 'Cmd-Alt-F': function () { focusFind(true); },
        'Esc': function () { if (!st.fs) { return window.CodeMirror.Pass; } exitFs(); }
      });
      st.cm.on('change', function () {
        clearTimeout(st.secTimer);
        st.secTimer = setTimeout(function () {
          st.secTimer = null;
          renderSections();
          if (st.q) { run({ keep: true }); } else { renderTree(); }
        }, 300);
      });
      st.cm.on('cursorActivity', onCursor);
      renderSections();
      renderTree();
      onCursor();
    },
    setDirty: function (on) { fsDirty.hidden = !on; },
    setCheck: setCheck,
    setBusy: function (on) {
      fsBtns.forEach(function (b) { b.disabled = on; });
      repOne.disabled = on; repAll.disabled = on;
    },
    exitFs: exitFs,
    destroy: function () { exitFs(); clearTimeout(st.timer); clearTimeout(st.secTimer); }
  };
}

function renderYaml(bar) {
  setLoading();
  configView = { dirty: false };
  var view = configView;
  var alive = viewGuard();
  fetchConfigJson('/api/config', 'text').then(function (data) {
    if (!alive()) { return; }
    clearApp();
    app.appendChild(bar);
    view.base = data.base;
    view.saved = data.text || '';
    // Схема шаблона, если текст в редакторе получен «Миграцией к шаблону»:
    // передаётся в save (?schema=N) и после успешного применения
    // записывается как применённая - карточка на «Обновлениях» исчезает.
    // Любая другая замена текста (загрузка, бэкап, импорт, отмена) сбрасывает.
    var migrationSchema = null;

    var main = card('Конфиг Mihomo');
    main.appendChild(el('p', 'hint', data.path + ' - перед применением конфиг проверяется mihomo -t, ' +
      'текущая версия сохраняется в бэкап; если ядро после перезапуска не поднимется, конфиг откатится сам.'));
    var status = el('p', 'hint config-status', 'Изменений нет.');
    main.appendChild(status);
    // Баннер «конфиг не проходит mihomo -t»: заполняется после открытия вкладки.
    var brokenBox = el('div', 'config-broken');
    brokenBox.hidden = true;
    main.appendChild(brokenBox);

    function btn(row, text, secondary) {
      var b = el('button', 'submit' + (secondary ? ' secondary' : ''), text);
      b.type = 'button'; row.appendChild(b); return b;
    }
    var row1 = el('div', 'btn-row config-toolbar');
    var saveBtn = btn(row1, 'Сохранить и применить');
    var checkBtn = btn(row1, 'Проверить', true);
    var diffBtn = btn(row1, 'Изменения', true);
    var resetBtn = btn(row1, 'Отменить правки', true);
    // Починка конфига шаблоном - на самой панели, а не в меню «Ещё»: нужна
    // новичку первой. Те же две кнопки есть в панели конструктора.
    var tplBtn = btn(row1, 'Миграция к шаблону', true);
    tplBtn.title = 'Только меняет текст в редакторе: служебные разделы из шаблона, подписки и локальные настройки сохраняются; после применения карточка обновления конфига исчезнет';
    var resetTplBtn = btn(row1, 'Заменить шаблоном…', true);
    resetTplBtn.title = 'Оставляет только подписки и прокси, всё остальное берётся из шаблона; применяется сразу, старый конфиг уходит в бэкап';
    // «Ещё»: редкие действия (починка, откат, журнал) - меню справа в той же панели.
    var moreWrap = el('div', 'config-more');
    var moreBtn = btn(moreWrap, 'Ещё ▾', true);
    moreBtn.setAttribute('aria-haspopup', 'true');
    moreBtn.setAttribute('aria-expanded', 'false');
    var moreMenu = el('div', 'config-more-menu');
    moreMenu.hidden = true;
    function menuGroup(title) { moreMenu.appendChild(el('div', 'config-more-title', title)); }
    function menuItem(text, danger, tip) {
      var b = el('button', 'config-more-item' + (danger ? ' danger' : ''), text);
      b.type = 'button';
      if (tip) { b.title = tip; }
      moreMenu.appendChild(b);
      return b;
    }
    menuGroup('Починка');
    var fmtBtn = menuItem('Исправить формат', false, 'Только меняет текст в редакторе: BOM, CRLF, табы, пробелы в конце строк');
    var wgBtn = menuItem('Импорт WireGuard…', false, 'Добавляет ноды из .conf (WireGuard и AmneziaWG) в proxies и группы; только меняет текст в редакторе');
    moreMenu.appendChild(el('div', 'config-more-sep'));
    menuGroup('История');
    var logBtn = menuItem('Журнал применения');
    var workBtn = menuItem('Откат к рабочему бэкапу', true, 'Сразу применяет самый свежий бэкап, который проходит mihomo -t');
    moreWrap.appendChild(moreMenu);
    row1.appendChild(moreWrap);
    function closeMore() { moreMenu.hidden = true; moreBtn.setAttribute('aria-expanded', 'false'); }
    moreBtn.addEventListener('click', function (ev) {
      ev.stopPropagation();
      moreMenu.hidden = !moreMenu.hidden;
      moreBtn.setAttribute('aria-expanded', moreMenu.hidden ? 'false' : 'true');
    });
    moreMenu.addEventListener('click', function (ev) { if (ev.target.tagName === 'BUTTON') { closeMore(); } });
    function outsideMore(ev) {
      if (!document.body.contains(moreWrap)) { document.removeEventListener('click', outsideMore); document.removeEventListener('keydown', escMore); return; }
      if (!moreWrap.contains(ev.target)) { closeMore(); }
    }
    function escMore(ev) { if (ev.key === 'Escape' && !moreMenu.hidden) { closeMore(); moreBtn.focus(); } }
    document.addEventListener('click', outsideMore);
    document.addEventListener('keydown', escMore);
    main.appendChild(row1);

    var msgBox = el('div', 'config-msg');
    // Навигатор разделов, поиск и полноэкранный режим вокруг редактора;
    // кнопки полноэкранной панели нажимают кнопки основной панели.
    var nav = createConfigNav({
      diff: function () { diffBtn.click(); },
      check: function () { checkBtn.click(); },
      save: function () { saveBtn.click(); }
    });
    activeNav = nav;
    var editorHost = nav.host;
    var output = el('div');
    var diffHost = el('div', 'config-sdiff-host');
    diffHost.hidden = true;
    main.appendChild(msgBox);
    main.appendChild(nav.root);
    main.appendChild(diffHost);
    main.appendChild(output);

    // Журнал применения (stats_config.sh, действие log): этапы проверки,
    // записи, xkeen -restart, проверки ядра и отката. Пока ждём ответа на
    // save/restore/restore-working - опрашиваем раз в секунду.
    var applyBox = el('div', 'config-apply');
    applyBox.hidden = true;
    var applyHead = el('div', 'config-apply-head');
    applyHead.appendChild(el('h2', null, 'Журнал применения'));
    var applyStatus = el('span', 'hint');
    applyHead.appendChild(applyStatus);
    applyBox.appendChild(applyHead);
    var applyPre = el('div', 'update-console config-apply-log');
    applyPre.setAttribute('role', 'log');
    applyPre.setAttribute('aria-live', 'polite');
    applyBox.appendChild(applyPre);
    main.appendChild(applyBox);
    app.appendChild(main);

    // Импорт WireGuard: скрытый выбор файлов и окно со списком - в основной карточке.
    var wgInput = el('input');
    wgInput.type = 'file'; wgInput.accept = '.conf'; wgInput.multiple = true; wgInput.hidden = true;
    main.appendChild(wgInput);
    var importHost = el('div');
    main.appendChild(importHost);

    var backupsCard = card('Бэкапы');
    var backupsBody = el('div');
    var backupView = el('div');
    backupsCard.appendChild(backupsBody);
    backupsCard.appendChild(backupView);
    app.appendChild(backupsCard);

    var all = [checkBtn, saveBtn, diffBtn, resetBtn, fmtBtn, tplBtn, workBtn, wgBtn];  // logBtn - доступна и во время применения
    function busy(on) {
      all.forEach(function (b) { b.disabled = on; });
      nav.setBusy(on);
      var rb = backupsBody.querySelectorAll('button');
      for (var i = 0; i < rb.length; i++) { rb[i].disabled = on; }
    }
    function msg(text, kind) {
      while (msgBox.firstChild) { msgBox.removeChild(msgBox.firstChild); }
      if (text) { msgBox.appendChild(el('p', kind === 'ok' ? 'msg-ok' : (kind === 'err' ? 'msg-err' : 'hint'), text)); }
      if (text) { main.scrollIntoView({ block: 'start', behavior: 'smooth' }); }
    }
    function clearOutput() { while (output.firstChild) { output.removeChild(output.firstChild); } }
    // Сравнение открывается вместо редактора: слева текущий конфиг, справа b.
    function closeDiff() {
      if (diffHost.hidden) { return; }
      diffHost.hidden = true; nav.root.hidden = false;
      while (diffHost.firstChild) { diffHost.removeChild(diffHost.firstChild); }
      if (view.editor) { view.editor.refresh(); }
    }
    function openDiff(b, labelB) {
      nav.exitFs(); nav.root.hidden = true; diffHost.hidden = false;
      renderSideDiff(diffHost, view.saved, b, 'текущий config.yaml', labelB, closeDiff);
      main.scrollIntoView({ block: 'start', behavior: 'smooth' });
    }

    var applyTimer = null;
    function applyLineClass(line) {
      if (/===/.test(line)) { return 'log-line sep'; }
      if (/ОШИБКА|ERROR|FAIL|не удалось|не поднял/i.test(line)) { return 'log-line err'; }
      if (/ГОТОВО|[Яя]дро работает/.test(line)) { return 'log-line ok'; }
      return 'log-line';
    }
    function renderApplyLog(text) {
      var atBottom = applyPre.scrollHeight - applyPre.scrollTop - applyPre.clientHeight < 24;
      while (applyPre.firstChild) { applyPre.removeChild(applyPre.firstChild); }
      var lines = String(text || '').split('\n');
      if (lines[lines.length - 1] === '') { lines.pop(); }
      if (!lines.length) { applyPre.appendChild(el('div', 'log-line', 'Журнал пуст - конфиг из этой вкладки ещё не применялся (журнал хранится до перезагрузки роутера).')); }
      lines.forEach(function (l) { applyPre.appendChild(el('div', applyLineClass(l), l === '' ? ' ' : l)); });
      if (atBottom || applyTimer) { applyPre.scrollTop = applyPre.scrollHeight; }
    }
    function fetchApplyLog() {
      return fetchJson('/api/config/log').then(function (d) { renderApplyLog(d.text); return d; })
        ['catch'](function () { return null; });
    }
    function startApplyLog() {
      applyBox.hidden = false;
      applyStatus.textContent = 'идёт применение...';
      while (applyPre.firstChild) { applyPre.removeChild(applyPre.firstChild); }
      clearInterval(applyTimer);
      applyTimer = setInterval(fetchApplyLog, 1000);
      fetchApplyLog();
    }
    function stopApplyLog() {
      clearInterval(applyTimer);
      applyTimer = null;
      return fetchApplyLog().then(function () {
        applyStatus.textContent = 'завершено в ' + new Date().toLocaleTimeString('ru-RU');
        applyBox.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      });
    }
    logBtn.addEventListener('click', function () {
      if (!applyBox.hidden && !applyTimer) { applyBox.hidden = true; return; }
      applyBox.hidden = false;
      if (!applyTimer) { applyStatus.textContent = 'последнее применение'; }
      fetchApplyLog().then(function () { applyBox.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); });
    });
    // Применение уже идёт (из другой вкладки или до перезагрузки страницы) -
    // сразу показываем журнал и ждём окончания.
    fetchJson('/api/config/log').then(function (d) {
      if (!d.running) { return; }
      startApplyLog();
      var waitDone = setInterval(function () {
        fetchJson('/api/config/log').then(function (x) {
          if (!x.running) { clearInterval(waitDone); stopApplyLog(); reload(); }
        })['catch'](function () {});
      }, 1500);
    })['catch'](function () {});
    function showOutput(title, lines) {
      clearOutput();
      output.appendChild(el('h2', null, title));
      var pre = el('div', 'update-console');
      lines.forEach(function (l) { pre.appendChild(el('div', 'log-line', l)); });
      output.appendChild(pre);
    }
    function setDirty() {
      view.dirty = view.editor ? view.editor.getValue() !== view.saved : false;
      status.textContent = view.dirty ? 'Есть несохранённые изменения.' : 'Изменений нет.';
      status.classList.toggle('config-dirty', view.dirty);
      nav.setDirty(view.dirty);
    }
    function showCheck(check, okText) {
      if (!check) { return; }
      nav.setCheck(check.ok ? 'пройдена' : ('ошибка' + (check.line ? ', строка ' + check.line : '')), check.ok ? 'ok' : 'err');
      if (check.ok) {
        view.editor.markLine(0);
        msg(okText || 'Проверка mihomo -t пройдена.', 'ok');
        return;
      }
      msg('Конфиг не прошёл проверку mihomo -t' + (check.line ? ' (строка ' + check.line + ')' : '') + '.', 'err');
      showOutput('Вывод mihomo -t', String(check.output || '').replace(/\n$/, '').split('\n'));
      view.editor.markLine(check.line);
    }
    function applyText(resp, what) {
      var t = what;
      if (resp.unchanged) { return 'Конфиг не изменился, перезапуск не нужен.'; }
      if (resp.restarted === false) { t += ' XKeen не найден - перезапустите ядро вручную.'; }
      else { t += ' Ядро перезапущено.'; }
      if (resp.backup) { t += ' Предыдущая версия сохранена в бэкап ' + fmtBackupName(resp.backup) + '.'; }
      return t;
    }
    // keepEditor - не трогать текст в редакторе (после автоотката правки
    // пользователя не должны пропасть), только обновить base/сохранённое.
    function reload(okText, kind, keepEditor) {
      fetchConfigJson('/api/config', 'text').then(function (d) {
        view.base = d.base; view.saved = d.text || '';
        if (!keepEditor) { closeDiff(); migrationSchema = null; view.editor.clearImport(); view.editor.setValue(view.saved); view.editor.markLine(0); }
        setDirty();
        if (okText) { msg(okText, kind || 'ok'); }
        loadBackups();
      })['catch'](function (e) { msg('Не удалось перечитать конфиг: ' + e.message, 'err'); });
    }
    function handleApplyError(err) {
      var d = err.data || {};
      if (err.message === 'check_failed') { showCheck(d.check); return; }
      if (err.message === 'conflict') {
        msg('config.yaml изменили с момента открытия редактора (setup.sh, обновление или другая вкладка). ' +
          'Скопируйте свои правки и откройте раздел заново.', 'err');
        return;
      }
      if (err.message === 'restart_failed') {
        if (d.rolled_back) {
          reload('Ядро не поднялось с новым конфигом - возвращена предыдущая версия, ядро перезапущено. ' +
            'Ваши правки остались в редакторе.', 'err', true);
        } else {
          msg('Ядро не поднялось, и автоматический откат не удался - проверьте конфиг по SSH.', 'err');
        }
        return;
      }
      if (err.message === 'busy') { msg('Конфиг уже применяется из другой вкладки - подождите.', 'err'); return; }
      msg('Ошибка: ' + (d.message || err.message), 'err');
    }
    function applyRequest(url, body, what) {
      busy(true);
      startApplyLog();
      var p = body === null ? fetchJson(url, { method: 'POST' }) : postText(url, body);
      return p.then(function (resp) { reload(applyText(resp, typeof what === 'function' ? what(resp) : what)); })
        ['catch'](handleApplyError)
        .then(function () { busy(false); return stopApplyLog(); });
    }

    function loadBackups() {
      fetchJson('/api/config/backups').then(function (d) {
        while (backupsBody.firstChild) { backupsBody.removeChild(backupsBody.firstChild); }
        var list = d.backups || [];
        if (!list.length) { backupsBody.appendChild(el('p', 'hint', 'Бэкапов пока нет.')); return; }
        backupsBody.appendChild(el('p', 'hint', '«Редактор» - бэкапы этой вкладки (хранятся последние ' + d.keep +
          '), «setup.sh» - бэкапы, сделанные при установке.'));
        var table = el('table', 'config-backups');
        list.forEach(function (b) {
          var tr = el('tr');
          tr.appendChild(el('td', null, fmtBackupName(b.name)));
          tr.appendChild(el('td', 'hint', b.kind === 'edit' ? 'редактор' : 'setup.sh'));
          tr.appendChild(el('td', 'hint', b.size < 1024 ? (b.size + ' Б') : ((Math.round(b.size / 102.4) / 10) + ' КБ')));
          var td = el('td', 'config-backup-actions');
          var q = '?kind=' + encodeURIComponent(b.kind) + '&name=' + encodeURIComponent(b.name);
          function act(text, fn) {
            var x = el('button', 'theme-btn', text); x.type = 'button';
            x.addEventListener('click', fn); td.appendChild(x);
          }
          function withBackup(fn) {
            fetchConfigJson('/api/config/backup' + q, 'text').then(fn)
              ['catch'](function (e) { msg('Не удалось прочитать бэкап: ' + e.message, 'err'); });
          }
          act('Сравнить', function () {
            withBackup(function (bd) {
              openDiff(bd.text || '', 'бэкап ' + fmtBackupName(b.name));
            });
          });
          act('В редактор', function () {
            withBackup(function (bd) {
              closeDiff();
              migrationSchema = null; view.editor.setValue(bd.text || ''); setDirty();
              msg('Бэкап ' + fmtBackupName(b.name) + ' загружен в редактор. Проверьте и нажмите «Сохранить и применить».', 'ok');
            });
          });
          act('Откатить', function () {
            if (!window.confirm('Откатить config.yaml к бэкапу ' + fmtBackupName(b.name) + ' и перезапустить ядро?' +
              (view.dirty ? '\nНесохранённые правки в редакторе будут потеряны.' : ''))) { return; }
            msg('Откат и перезапуск ядра...', '');
            applyRequest('/api/config/restore' + q + '&base=' + encodeURIComponent(view.base), null,
              'Конфиг откачен к бэкапу ' + fmtBackupName(b.name) + '.');
          });
          tr.appendChild(td);
          table.appendChild(tr);
        });
        backupsBody.appendChild(table);
      })['catch'](function (e) {
        while (backupsBody.firstChild) { backupsBody.removeChild(backupsBody.firstChild); }
        backupsBody.appendChild(el('p', 'msg-err', 'Не удалось загрузить список бэкапов: ' + e.message));
      });
    }

    createEditor(editorHost, view.saved, setDirty).then(function (ed) {
      view.editor = ed;
      nav.attach(ed);
      ed.refresh();
      loadBackups();
      if (pendingMigration) { pendingMigration = false; repair('template'); }
      if (pendingAction) {
        var pa = pendingAction; pendingAction = null;
        (pa === 'reset' ? resetTplBtn : tplBtn).click();
      }
    });

    checkBtn.addEventListener('click', function () {
      busy(true); clearOutput(); msg('Проверка...', '');
      postText('/api/config/check', view.editor.getValue()).then(function (c) { showCheck(c); })
        ['catch'](function (e) { nav.setCheck('ошибка запроса', 'err'); msg('Ошибка проверки: ' + e.message, 'err'); })
        .then(function () { busy(false); });
    });
    saveBtn.addEventListener('click', function () {
      clearOutput(); msg('Проверка, сохранение и перезапуск ядра...', '');
      applyRequest('/api/config/save?base=' + encodeURIComponent(view.base) +
        (migrationSchema !== null ? '&schema=' + migrationSchema : ''), view.editor.getValue(), 'Конфиг сохранён.');
    });
    diffBtn.addEventListener('click', function () {
      openDiff(view.editor.getValue(), 'в редакторе (будет применено)');
    });
    resetBtn.addEventListener('click', function () {
      if (view.dirty && !window.confirm('Отменить все несохранённые правки?')) { return; }
      closeDiff();
      migrationSchema = null; view.editor.clearImport(); view.editor.setValue(view.saved); view.editor.markLine(0); setDirty(); msg('', ''); clearOutput();
    });
    function repair(mode) {
      busy(true); clearOutput(); msg('Починка...', '');
      var before = view.editor.getValue();
      postText('/api/config/repair?mode=' + mode, before).then(function (r) {
        migrationSchema = (mode === 'template' && typeof r.schema === 'number') ? r.schema : null;
        view.editor.setValue(r.text || ''); setDirty();
        var lines = (r.fixes || []).map(function (f) {
          var p = f.split('|'); return (REPAIR_FIX_LABELS[p[0]] || p[0]) + ' (строк: ' + p[1] + ')';
        });
        // Отчёт migrate_config.sh: REVIEW - на что стоит посмотреть,
        // PRESERVED (перенесено как было) - только общим числом.
        var kept = 0;
        (r.report || []).forEach(function (l) {
          var p = l.split('|');
          if (p[0] === 'REVIEW') { lines.push('проверьте: ' + p.slice(1).join(' ')); } else { kept++; }
        });
        if (kept) { lines.push('перенесено из вашего конфига без изменений: ' + kept + ' (подписки, локальные ключи, разделы)'); }
        if (!lines.length) { lines.push('Исправлять нечего.'); }
        showCheck(r.check, 'Текст в редакторе исправлен и проходит mihomo -t. Проверьте изменения и сохраните.');
        var box = el('div');
        output.insertBefore(box, output.firstChild);
        box.appendChild(el('h2', null, 'Что изменено'));
        var ul = el('ul', 'config-fixes');
        lines.forEach(function (l) { ul.appendChild(el('li', null, l)); });
        box.appendChild(ul);
        var dHost = el('div');
        box.appendChild(dHost);
        if (before !== r.text) { renderDiff(dHost, before, r.text || '', 'до починки', 'после'); }
      })['catch'](function (e) {
        var d = e.data || {};
        msg('Починка не удалась: ' + (d.message || e.message), 'err');
      }).then(function () { busy(false); });
    }
    fmtBtn.addEventListener('click', function () { repair('format'); });

    // ----- Импорт WireGuard (.conf -> ноды, stats_config.sh import-wg) -----
    // Окно со списком файлов: имя ноды правится, статус - ответ роутера
    // (запрос после выбора файлов и через 400 мс после правки имени).
    // «Добавить в конфиг» ставит текст из ответа в редактор и подсвечивает
    // новое; до «Сохранить и применить» ничего не применяется.
    wgBtn.addEventListener('click', function () { wgInput.value = ''; wgInput.click(); });
    wgInput.addEventListener('change', function () {
      var files = Array.prototype.slice.call(wgInput.files || []);
      if (!files.length) { return; }
      if (files.length > WG_MAX_FILES) { msg('За один раз можно импортировать не больше ' + WG_MAX_FILES + ' файлов.', 'err'); return; }
      Promise.all(files.map(function (f) {
        var e = { file: f.name, name: f.name.replace(/\.conf$/i, ''), text: '', localErr: '', status: null, skipped: [] };
        if (f.size > WG_MAX_BYTES) { e.localErr = 'файл больше 64 КБ'; return Promise.resolve(e); }
        return f.text().then(function (s) {
          e.text = s;
          if (/^### MST-/m.test(s)) { e.localErr = 'недопустимая строка ### MST- в файле'; }
          return e;
        });
      })).then(openImport)['catch'](function (err) { msg('Не удалось прочитать файлы: ' + err.message, 'err'); });
    });
    function openImport(entries) {
      while (importHost.firstChild) { importHost.removeChild(importHost.firstChild); }
      var box = el('div', 'config-import');
      box.appendChild(el('h2', null, 'Импорт WireGuard'));
      box.appendChild(el('p', 'hint', 'Имя ноды можно поправить. Нода с таким же именем в конфиге будет заменена.'));
      var list = el('div', 'config-import-list');
      box.appendChild(list);
      var row = el('div', 'btn-row');
      var addBtn = btn(row, 'Добавить в конфиг');
      var cancelBtn = btn(row, 'Отмена', true);
      box.appendChild(row);
      importHost.appendChild(box);
      var seq = 0, last = null, lastBody = null, timer = null;
      entries.forEach(function (e) {
        var r = el('div', 'config-import-row');
        r.appendChild(el('span', 'config-import-file', e.file));
        e.input = el('input'); e.input.type = 'text'; e.input.value = e.name; e.input.maxLength = 64;
        e.input.setAttribute('aria-label', 'Имя ноды для ' + e.file);
        e.input.disabled = !!e.localErr;
        e.input.addEventListener('input', function () {
          e.name = e.input.value.trim();
          clearTimeout(timer); timer = setTimeout(function () { timer = null; request(); }, 400);
          addBtn.disabled = true;
        });
        r.appendChild(e.input);
        e.statusEl = el('span', 'config-import-status hint');
        r.appendChild(e.statusEl);
        list.appendChild(r);
      });
      function paint() {
        var good = false;
        entries.forEach(function (e) {
          var s = e.localErr ? ['err', 'ошибка: ' + e.localErr] : (e.status || ['', 'проверка...']);
          if (s[0] === 'ok') { good = true; }
          e.statusEl.textContent = s[1] + (e.skipped && e.skipped.length && s[0] === 'ok' ? ' (пропущены ключи: ' + e.skipped.join(', ') + ')' : '');
          e.statusEl.className = 'config-import-status ' + (s[0] === 'ok' ? 'msg-ok' : (s[0] === 'err' ? 'msg-err' : 'hint'));
        });
        // Пока ждём пересчёта после правки имени - статусы устарели.
        addBtn.disabled = !good || timer !== null;
      }
      function body() {
        var b = '';
        entries.forEach(function (e) {
          if (e.localErr) { return; }
          b += '### MST-WG ' + e.name + '\n' + e.text + (/\n$/.test(e.text) ? '' : '\n');
        });
        return b + '### MST-CONFIG\n' + view.editor.getValue();
      }
      function request() {
        var my = ++seq, b = body();
        entries.forEach(function (e) { if (!e.localErr) { e.status = null; } });
        paint(); addBtn.disabled = true;
        return postText('/api/config/import-wg', b).then(function (r) {
          if (my !== seq) { return null; }
          last = r; lastBody = b;
          importStatuses(entries, r.report);
          paint();
          return r;
        })['catch'](function (err) {
          if (my !== seq) { return null; }
          var d = err.data || {};
          entries.forEach(function (e) { if (!e.localErr) { e.status = ['err', 'ошибка: ' + (d.message || err.message)]; } });
          paint();
          return null;
        });
      }
      function hasNodes(r) {
        return (r.report || []).some(function (l) { return /^(ADDED|REPLACED)\|/.test(l); });
      }
      cancelBtn.addEventListener('click', function () {
        seq++; clearTimeout(timer); timer = null;
        while (importHost.firstChild) { importHost.removeChild(importHost.firstChild); }
      });
      addBtn.addEventListener('click', function () {
        // Имя правили только что или текст редактора поменялся, пока окно
        // было открыто, - сначала пересчитать (отложенный пересчёт отменяется).
        var pending = timer !== null;
        clearTimeout(timer); timer = null;
        var p = (!pending && last && lastBody === body()) ? Promise.resolve(last) : request();
        p.then(function (r) {
          if (!r || !hasNodes(r)) { return; }   // нечего добавлять - статусы уже в окне
          seq++;
          applyImport(r);
          while (importHost.firstChild) { importHost.removeChild(importHost.firstChild); }
        });
      });
      request();
    }
    function applyImport(r) {
      var before = view.editor.getValue();
      view.editor.clearImport();
      migrationSchema = null; view.editor.setValue(r.text || '');
      var marks = importLineMarks(before, r.text || '');
      if (marks) { view.editor.markImport(marks); }
      setDirty();
      var n = { ADDED: 0, REPLACED: 0 }, groups = [], missing = [];
      (r.report || []).forEach(function (l) {
        var p = l.split('|');
        if (p[0] in n) { n[p[0]]++; }
        if (p[0] === 'GROUP') { groups.push(p[1]); }
        if (p[0] === 'GROUP_MISSING') { missing.push(p[1]); }
      });
      clearOutput();
      showCheck(r.check, 'Ноды добавлены в редактор, конфиг проходит mihomo -t. Проверьте подсвеченное и нажмите «Сохранить и применить».');
      var box = el('div');
      output.insertBefore(box, output.firstChild);
      box.appendChild(el('h2', null, 'Импорт WireGuard'));
      var ul = el('ul', 'config-fixes');
      ul.appendChild(el('li', null, 'добавлено нод: ' + n.ADDED + ', заменено: ' + n.REPLACED));
      if (groups.length) { ul.appendChild(el('li', null, 'дописано в группы: ' + groups.join(', '))); }
      if (missing.length) { ul.appendChild(el('li', 'msg-err', 'группы не найдены или их proxies: записан не в одну строку - добавьте ноды вручную: ' + missing.join(', '))); }
      if (!marks) { ul.appendChild(el('li', 'hint', 'конфиг слишком большой для подсветки изменений')); }
      box.appendChild(ul);
      var undoRow = el('div', 'btn-row');
      var undoBtn = btn(undoRow, 'Отменить импорт', true);
      box.appendChild(undoRow);
      undoBtn.addEventListener('click', function () {
        migrationSchema = null; view.editor.clearImport(); view.editor.setValue(before); view.editor.markLine(0); setDirty();
        clearOutput(); msg('Импорт отменён - текст в редакторе как до импорта.', '');
      });
    }
    // Замена шаблоном: из config.yaml остаются только подписки и свои ноды.
    // Сначала предпросмотр (ничего не пишет), потом подтверждение и применение.
    function resetPreviewLines(r) {
      var k = r.kept || {};
      var lines = ['Останется: ' + (k.subscriptions || 0) + ' подписок, ' + (k.nodes || 0) + ' прокси.',
        'Будет из шаблона: dns, listeners, secret, порты, группы, правила, гео-фильтр.'];
      (r.report || []).forEach(function (l) {
        var p = String(l).split('|');
        if (p[0] === 'REVIEW' && p[1] === 'file-provider-dropped') { lines.push('Не переносится провайдер type: file: ' + p[2]); }
      });
      return lines;
    }
    function applyReset() {
      return applyRequest('/api/constructor/reset?base=' + encodeURIComponent(view.base), null,
        'Конфиг заменён шаблоном: подписки и ноды сохранены.');
    }
    function resetFromTemplate() {
      if (view.dirty && !window.confirm('Несохранённые правки в редакторе будут потеряны. Продолжить?')) { return; }
      clearOutput(); msg('Собираю замену из шаблона...', '');
      busy(true);
      var preview = null;
      fetchJson('/api/constructor/reset-preview', { method: 'POST' })
        .then(function (r) { preview = r; })
        ['catch'](function (e) {
          if (e.message === 'nothing_to_keep') {
            msg('В config.yaml нет ни подписок, ни прокси - заменять нечем. Сначала добавьте подписку или прокси в конструкторе.', 'err');
          } else {
            msg('Не удалось подготовить замену: ' + ((e.data && e.data.message) || e.message), 'err');
          }
        })
        .then(function () {
          busy(false);
          if (!preview) { return; }
          showOutput('Замена шаблоном', resetPreviewLines(preview));
          if (!preview.check || !preview.check.ok) {
            msg('Новый конфиг не прошёл проверку mihomo -t - замена не применена.', 'err');
            output.appendChild(el('h2', null, 'Вывод mihomo -t'));
            var pre = el('div', 'update-console');
            String((preview.check && preview.check.output) || '').replace(/\n$/, '').split('\n').forEach(function (l) { pre.appendChild(el('div', 'log-line', l)); });
            output.appendChild(pre);
            return;
          }
          var k = preview.kept || {};
          if (!window.confirm('Заменить config.yaml шаблоном? Останется ' + (k.subscriptions || 0) + ' подписок и ' +
            (k.nodes || 0) + ' нод; dns, listeners, secret, порты, группы и правила будут из шаблона. ' +
            'Старый конфиг сохранится в бэкап, ядро перезапустится.')) { msg('Замена отменена.', ''); return; }
          return applyReset();
        });
    }
    resetTplBtn.addEventListener('click', resetFromTemplate);
    tplBtn.addEventListener('click', function () {
      if (!window.confirm('Миграция заменит служебные разделы проекта (группы, правила, провайдеры) на версии из ' +
        'шаблона, сохранив подписки и локальные настройки. Результат попадёт в редактор, применение - отдельно. Продолжить?')) { return; }
      repair('template');
    });
    workBtn.addEventListener('click', function () {
      if (!window.confirm('Найти самый свежий бэкап, проходящий mihomo -t, применить его и перезапустить ядро?' +
        (view.dirty ? '\nНесохранённые правки в редакторе будут потеряны.' : ''))) { return; }
      clearOutput(); msg('Поиск рабочего бэкапа и перезапуск ядра (может занять пару минут)...', '');
      busy(true);
      startApplyLog();
      fetchJson('/api/config/restore-working?base=' + encodeURIComponent(view.base), { method: 'POST' })
        .then(function (resp) { reload(applyText(resp, 'Применён бэкап ' + fmtBackupName(resp.restored) + '.')); })
        ['catch'](function (e) {
          if (e.message === 'no_working_backup') { msg('Среди последних бэкапов нет ни одного, проходящего mihomo -t.', 'err'); return; }
          handleApplyError(e);
        })
        .then(function () { busy(false); return stopApplyLog(); });
    });
    // Конфиг, не проходящий mihomo -t (или ещё без нод), - сразу предложить
    // починку; проверка идёт один раз при открытии и ничего не пишет.
    function renderBrokenBanner(check) {
      while (brokenBox.firstChild) { brokenBox.removeChild(brokenBox.firstChild); }
      brokenBox.appendChild(el('p', 'msg-err', 'Конфиг не проходит проверку mihomo -t' +
        (check.line ? ' (строка ' + check.line + ')' : '') + '. Если вы ещё не добавили подписку или ноды, это нормально.'));
      var first = String(check.output || '').split('\n').filter(function (l) { return l.trim(); })[0];
      if (first) { brokenBox.appendChild(el('p', 'hint', first)); }
      var row = el('div', 'btn-row');
      [['Исправить формат', fmtBtn], ['Миграция к шаблону', tplBtn], ['Заменить шаблоном…', resetTplBtn]].forEach(function (a) {
        var b = btn(row, a[0], true);
        b.addEventListener('click', function () { a[1].click(); });
      });
      brokenBox.appendChild(row);
      brokenBox.hidden = false;
    }
    postText('/api/config/check', data.text || '').then(function (check) {
      if (!alive() || !check) { return; }
      nav.setCheck(check.ok ? 'пройдена' : ('ошибка' + (check.line ? ', строка ' + check.line : '')), check.ok ? 'ok' : 'err');
      if (check.ok === false) { renderBrokenBanner(check); }
    })['catch'](function () {});
  })['catch'](function (err) {
    pendingAction = null;
    pendingMigration = false;   // миграцию с карточки «Обновлений» не откладываем до следующего открытия
    if (!alive()) { return; }
    var d = err.data || {};
    showError('Не удалось загрузить конфиг: ', d.message ? new Error(d.message) : err);
  });
}

window.addEventListener('beforeunload', function (e) {
  if (configDirty()) { e.preventDefault(); e.returnValue = ''; }
});
