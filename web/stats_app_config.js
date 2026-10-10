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
export function leaveConfig() { configView = null; leaveConstructor(); }

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
    resetTplBtn.title = 'Оставляет только подписки и свои ноды, всё остальное берётся из шаблона; применяется сразу, старый конфиг уходит в бэкап';
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
    var editorHost = el('div', 'config-editor');
    var output = el('div');
    var diffHost = el('div', 'config-sdiff-host');
    diffHost.hidden = true;
    main.appendChild(msgBox);
    main.appendChild(editorHost);
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
      diffHost.hidden = true; editorHost.hidden = false;
      while (diffHost.firstChild) { diffHost.removeChild(diffHost.firstChild); }
      if (view.editor) { view.editor.refresh(); }
    }
    function openDiff(b, labelB) {
      editorHost.hidden = true; diffHost.hidden = false;
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
    }
    function showCheck(check, okText) {
      if (!check) { return; }
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
        ['catch'](function (e) { msg('Ошибка проверки: ' + e.message, 'err'); })
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
      var lines = ['Останется: ' + (k.subscriptions || 0) + ' подписок, ' + (k.nodes || 0) + ' своих нод.',
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
            msg('В config.yaml нет ни подписок, ни своих нод - заменять нечем. Сначала добавьте подписку в конструкторе или ноды в YAML.', 'err');
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
      if (alive() && check && check.ok === false) { renderBrokenBanner(check); }
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
