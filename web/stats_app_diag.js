// Вкладка «Диагностика»: по кнопке проверяет, пускают ли сервисы ноду,
// которая сейчас выбрана в их группах, и (порция 4) ищет ноды, через
// которые сервис работает. Данные - /api/diag (stats_diag.sh), опрос раз в
// 1,5 с, пока проверка идёт. См. docs/superpowers/specs/
// 2026-10-14-service-diagnostics-design.md.

import { app, card, clearApp, el, fetchJson, showError, viewGuard } from './app-core.js';

var LABELS = {
  ok: 'Работает',
  blocked: 'Не пускает ноду',
  suspect: 'Похоже на блокировку',
  node_dead: 'Нода не отвечает',
  direct: 'Идёт напрямую, без ноды',
  rejected: 'Заблокировано правилом конфига',
  lb: 'Нода выбирается на каждый запрос',
  no_url: 'Нет адреса проверки',
  missing: 'Группы нет в ядре',
  error: 'Ошибка проверки',
  pending: 'Проверяется…',
  skipped: 'Не проверено'
};
// Порядок строк: сначала то, что требует внимания.
var ORDER = ['blocked', 'suspect', 'node_dead', 'lb', 'error', 'missing', 'no_url', 'pending', 'skipped', 'rejected', 'direct', 'ok'];
var PROBLEM = { blocked: 1, suspect: 1, node_dead: 1, error: 1, missing: 1 };

export function verdictLabel(code) { return LABELS[code] || code; }
export function isProblem(code) { return !!PROBLEM[code]; }

export function sortServices(list) {
  return list.slice().sort(function (a, b) {
    var x = ORDER.indexOf(a.verdict), y = ORDER.indexOf(b.verdict);
    if (x < 0) { x = ORDER.length; }
    if (y < 0) { y = ORDER.length; }
    if (x !== y) { return x - y; }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  });
}

export function countKpi(list) {
  var k = { ok: 0, blocked: 0, suspect: 0, node_dead: 0 };
  list.forEach(function (s) {
    if (s.verdict === 'ok' || s.verdict === 'direct') { k.ok++; }
    else if (k[s.verdict] !== undefined) { k[s.verdict]++; }
  });
  return k;
}

export function altText(alt) {
  if (!alt || !alt.state || alt.state === 'none') { return '—'; }
  var found = (alt.found || []).join(', ');
  if (alt.state === 'searching') {
    return found ? found + ' · ищу ещё… ' + alt.checked + '/' + alt.limit : 'ищу… ' + alt.checked + '/' + alt.limit;
  }
  if (alt.state === 'skipped') { return 'не искали: проверку остановили или кончилось время'; }
  if (alt.state === 'stopped') {
    return (found ? found + ' · ' : '') + 'поиск остановлен (проверено ' + alt.checked + ')';
  }
  if (!found && !alt.limit) { return 'других нод в группе нет'; }
  return found || 'ни одна из ' + alt.checked + ' проверенных нод не подошла';
}

export function fmtElapsed(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  var s = sec % 60;
  return Math.floor(sec / 60) + ':' + (s < 10 ? '0' : '') + s;
}

function fmtTime(epoch) {
  if (!epoch) { return '—'; }
  var d = new Date(epoch * 1000);
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return p(d.getDate()) + '.' + p(d.getMonth() + 1) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

var POLL_MS = 1500;
var pollTimer = null;

export function stopDiagPolling() {
  if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
}

export function renderDiag() {
  var alive = viewGuard();
  clearApp();
  var root = el('div');
  app.appendChild(root);
  var msgBox = el('p', 'hint');
  msgBox.hidden = true;

  function load() {
    fetchJson('/api/diag').then(function (d) {
      if (!alive()) { return; }
      draw(d);
      stopDiagPolling();
      if (d.running) { pollTimer = setTimeout(load, POLL_MS); }
    })['catch'](function (e) { if (alive()) { showError('Не удалось получить состояние диагностики', e); } });
  }

  function start(btn) {
    btn.disabled = true;
    msgBox.hidden = true;
    fetchJson('/api/diag/start', { method: 'POST' }).then(function () { load(); })['catch'](function (e) {
      btn.disabled = false;
      if (e.data && e.data.error === 'diag_running') { load(); return; }
      msgBox.textContent = (e.data && e.data.message) || ('Не удалось запустить диагностику: ' + e.message);
      msgBox.hidden = false;
    });
  }

  function stop(btn) {
    btn.disabled = true;
    fetchJson('/api/diag/cancel', { method: 'POST' })['catch'](function () { btn.disabled = false; });
  }

  function draw(d) {
    while (root.firstChild) { root.removeChild(root.firstChild); }
    var list = d.services || [];
    var problems = list.filter(function (s) { return isProblem(s.verdict); }).length;

    var bar = el('div', 'run-bar' + (d.running ? ' running' : ''));
    var row = el('div', 'run-bar-row');
    var state = el('span', 'run-state');
    state.appendChild(el('span', 'run-led'));
    if (d.running) {
      state.appendChild(el('span', null, d.current || 'Идёт проверка'));
      row.appendChild(state);
      var meta = el('span', 'run-meta', 'прошло ');
      meta.appendChild(el('b', null, fmtElapsed(Date.now() / 1000 - d.started)));
      if (d.total) { meta.appendChild(document.createTextNode(' · проверено сервисов ')); meta.appendChild(el('b', null, d.done + ' / ' + d.total)); }
      row.appendChild(meta);
      var stopBtn = el('button', 'small muted', 'Остановить');
      stopBtn.type = 'button';
      stopBtn.addEventListener('click', function () { stop(stopBtn); });
      row.appendChild(stopBtn);
    } else {
      state.appendChild(el('span', null, d.stage === 'none' ? 'Проверок ещё не было' : 'Последняя проверка'));
      row.appendChild(state);
      if (d.stage !== 'none') {
        var m2 = el('span', 'run-meta', '');
        m2.appendChild(el('b', null, fmtTime(d.finished || d.started)));
        m2.appendChild(document.createTextNode(' · ' + (problems ? 'проблем: ' + problems : 'проблем нет') +
          (d.stage === 'cancelled' ? ' · остановлена' : '')));
        row.appendChild(m2);
      }
    }
    var runBtn = el('button', 'submit', 'Проверить сервисы');
    runBtn.type = 'button';
    runBtn.addEventListener('click', function () { start(runBtn); });
    if (!d.running) { row.appendChild(runBtn); }
    bar.appendChild(row);
    if (d.running) {
      var track = el('div', 'run-progress');
      var fill = el('div', 'run-progress-fill');
      fill.style.width = (d.total ? Math.round(100 * d.done / d.total) : 0) + '%';
      track.appendChild(fill);
      bar.appendChild(track);
    }
    root.appendChild(bar);
    root.appendChild(msgBox);

    if (d.stage === 'error') {
      var ec = card('Проверка не удалась');
      ec.classList.add('diag-error');
      ec.appendChild(el('p', null, d.error || 'Неизвестная ошибка.'));
      root.appendChild(ec);
    }

    if (!list.length) {
      if (d.stage === 'none') {
        var empty = card('Доступность сервисов');
        empty.appendChild(el('p', 'hint', 'Проверок ещё не было. Нажмите «Проверить сервисы» — проверка займёт до нескольких минут. ' +
          'Каждый сервис открывается через ноду, которая сейчас выбрана в его группе; выбор нод не меняется.'));
        root.appendChild(empty);
      }
      return;
    }

    var k = countKpi(list);
    var kpis = el('div', 'kpi-row');
    [['РАБОТАЮТ', k.ok, 'kpi-ok'], ['СЕРВИС НЕ ПУСКАЕТ НОДУ', k.blocked, 'kpi-danger'],
      ['ПОХОЖЕ НА БЛОКИРОВКУ', k.suspect, 'kpi-warn'], ['НОДА НЕ ОТВЕЧАЕТ', k.node_dead, '']].forEach(function (x) {
      var t = el('div', 'kpi' + (x[2] && x[1] ? ' ' + x[2] : ''));
      t.appendChild(el('div', 'kpi-label', x[0]));
      t.appendChild(el('div', 'kpi-value', String(x[1])));
      kpis.appendChild(t);
    });
    root.appendChild(kpis);

    var c = card('Доступность сервисов');
    c.appendChild(el('p', 'hint', 'Каждый сервис проверен через ноду, которая сейчас выбрана в его группе. ' +
      '«Не пускает ноду» — сервис отвечает отказом или страницей блокировки, хотя сама нода работает.'));
    var scroll = el('div', 'table-scroll');
    var table = el('table', 'diag-table');
    var head = el('tr');
    ['Сервис', 'Текущая нода', 'Результат', 'Что видно', 'Работает через'].forEach(function (h) { head.appendChild(el('th', null, h)); });
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead);
    var tbody = el('tbody');
    sortServices(list).forEach(function (s) {
      var tr = el('tr', isProblem(s.verdict) ? 'diag-problem' : '');
      tr.appendChild(el('td', null, s.name));
      var chain = el('td', 'diag-chain');
      var parts = s.chain || [];
      parts.slice(1, -1).forEach(function (p) { chain.appendChild(document.createTextNode(p + ' → ')); });
      if (parts.length > 1) { chain.appendChild(el('b', null, parts[parts.length - 1])); } else { chain.textContent = '—'; }
      tr.appendChild(chain);
      var vt = el('td');
      vt.appendChild(el('span', 'v ' + s.verdict, verdictLabel(s.verdict)));
      tr.appendChild(vt);
      var det = el('td', 'diag-detail');
      if (s.url) { det.appendChild(el('code', null, s.url)); det.appendChild(document.createTextNode(' → ')); }
      det.appendChild(document.createTextNode(s.detail || ''));
      if (s.control_ms !== null && s.control_ms !== undefined) {
        det.appendChild(document.createTextNode('; контрольный запрос через ноду: ' + s.control_ms + ' мс'));
      }
      tr.appendChild(det);
      tr.appendChild(el('td', 'diag-alt', altText(s.alt)));
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    scroll.appendChild(table);
    c.appendChild(scroll);
    var legend = el('div', 'diag-legend');
    [['blocked', 'ответ 403/451, капча или «страна не поддерживается»'],
      ['suspect', 'обрыв или таймаут, но сама нода отвечает'],
      ['node_dead', 'проблема в ноде, а не в сервисе']].forEach(function (x) {
      var item = el('span');
      item.appendChild(el('span', 'v ' + x[0], verdictLabel(x[0])));
      item.appendChild(document.createTextNode(' ' + x[1]));
      legend.appendChild(item);
    });
    c.appendChild(legend);
    root.appendChild(c);
  }

  load();
}
