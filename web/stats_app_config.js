// Вкладка «Конфиг» (/config): редактор config.yaml на CodeMirror 5.

import { app, card, clearApp, el, fetchJson, setLoading, showError, viewGuard } from './app-core.js';

// ----- раздел "Конфиг" (/api/config/*, stats_config.sh) -----
//
// Редактор config.yaml Mihomo на CodeMirror 5 (stats_codemirror.js,
// вендоренная сборка, раздаётся как codemirror.js). Библиотека грузится
// только при открытии вкладки, остальные разделы её не ждут. Если она
// не загрузилась - редактор работает на обычном textarea.
// Сохранение, откат и починка выполняются на роутере (stats_config.sh):
// mihomo -t, бэкап, атомарная замена, xkeen -restart, автооткат.

var configView = null;   // {dirty:bool} - есть несохранённые правки

export function configDirty() { return !!(configView && configView.dirty); }

// Вызывается при уходе с вкладки (render() в app.js).
export function leaveConfig() { configView = null; }
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

export function renderConfig() {
  setLoading();
  configView = { dirty: false };
  var view = configView;
  var alive = viewGuard();
  fetchConfigJson('/api/config', 'text').then(function (data) {
    if (!alive()) { return; }
    clearApp();
    view.base = data.base;
    view.saved = data.text || '';

    var main = card('Конфиг Mihomo');
    main.appendChild(el('p', 'hint', data.path + ' - перед применением конфиг проверяется mihomo -t, ' +
      'текущая версия сохраняется в бэкап; если ядро после перезапуска не поднимется, конфиг откатится сам.'));
    var status = el('p', 'hint config-status', 'Изменений нет.');
    main.appendChild(status);

    function btn(row, text, secondary) {
      var b = el('button', 'submit' + (secondary ? ' secondary' : ''), text);
      b.type = 'button'; row.appendChild(b); return b;
    }
    var row1 = el('div', 'btn-row');
    var checkBtn = btn(row1, 'Проверить', true);
    var saveBtn = btn(row1, 'Сохранить и применить');
    var diffBtn = btn(row1, 'Сравнить с сохранённым', true);
    var resetBtn = btn(row1, 'Отменить правки', true);
    var logBtn = btn(row1, 'Журнал применения', true);
    main.appendChild(row1);

    var msgBox = el('div', 'config-msg');
    var editorHost = el('div', 'config-editor');
    var output = el('div');
    main.appendChild(msgBox);
    main.appendChild(editorHost);
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

    var repairCard = card('Починка');
    var row2 = el('div', 'btn-row');
    var fmtBtn = btn(row2, 'Исправить формат', true);
    var tplBtn = btn(row2, 'Миграция к шаблону', true);
    var workBtn = btn(row2, 'Откат к рабочему бэкапу', true);
    repairCard.appendChild(el('p', 'hint', 'Исправление формата и миграция только меняют текст в редакторе - ' +
      'проверьте результат и нажмите «Сохранить и применить». Откат к рабочему бэкапу сразу применяет ' +
      'самый свежий бэкап, который проходит mihomo -t.'));
    repairCard.appendChild(row2);
    app.appendChild(repairCard);

    var backupsCard = card('Бэкапы');
    var backupsBody = el('div');
    var backupView = el('div');
    backupsCard.appendChild(backupsBody);
    backupsCard.appendChild(backupView);
    app.appendChild(backupsCard);

    var all = [checkBtn, saveBtn, diffBtn, resetBtn, fmtBtn, tplBtn, workBtn];  // logBtn - доступна и во время применения
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
        if (!keepEditor) { view.editor.setValue(view.saved); view.editor.markLine(0); }
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
              renderDiff(backupView, bd.text || '', view.editor.getValue(), 'бэкап ' + fmtBackupName(b.name), 'редактор');
              backupView.scrollIntoView({ block: 'nearest' });
            });
          });
          act('В редактор', function () {
            withBackup(function (bd) {
              view.editor.setValue(bd.text || ''); setDirty();
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
    });

    checkBtn.addEventListener('click', function () {
      busy(true); clearOutput(); msg('Проверка...', '');
      postText('/api/config/check', view.editor.getValue()).then(function (c) { showCheck(c); })
        ['catch'](function (e) { msg('Ошибка проверки: ' + e.message, 'err'); })
        .then(function () { busy(false); });
    });
    saveBtn.addEventListener('click', function () {
      clearOutput(); msg('Проверка, сохранение и перезапуск ядра...', '');
      applyRequest('/api/config/save?base=' + encodeURIComponent(view.base), view.editor.getValue(), 'Конфиг сохранён.');
    });
    diffBtn.addEventListener('click', function () {
      renderDiff(output, view.saved, view.editor.getValue(), 'сохранённый', 'редактор');
    });
    resetBtn.addEventListener('click', function () {
      if (view.dirty && !window.confirm('Отменить все несохранённые правки?')) { return; }
      view.editor.setValue(view.saved); view.editor.markLine(0); setDirty(); msg('', ''); clearOutput();
    });
    function repair(mode) {
      busy(true); clearOutput(); msg('Починка...', '');
      var before = view.editor.getValue();
      postText('/api/config/repair?mode=' + mode, before).then(function (r) {
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
  })['catch'](function (err) {
    if (!alive()) { return; }
    var d = err.data || {};
    showError('Не удалось загрузить конфиг: ', d.message ? new Error(d.message) : err);
  });
}

window.addEventListener('beforeunload', function (e) {
  if (configView && configView.dirty) { e.preventDefault(); e.returnValue = ''; }
});
