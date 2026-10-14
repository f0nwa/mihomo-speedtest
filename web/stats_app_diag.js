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

// fullChain - показывать и саму группу (у проверки домена это other).
function diagTable(list, firstCol, fullChain) {
    var scroll = el('div', 'table-scroll');
    var table = el('table', 'diag-table');
    var head = el('tr');
    [firstCol, 'Текущая нода', 'Результат', 'Что видно', 'Работает через'].forEach(function (h) { head.appendChild(el('th', null, h)); });
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead);
    var tbody = el('tbody');
    list.forEach(function (s) {
      var tr = el('tr', isProblem(s.verdict) ? 'diag-problem' : '');
      tr.appendChild(el('td', null, s.name));
      var chain = el('td', 'diag-chain');
      var parts = s.chain || [];
      parts.slice(fullChain ? 0 : 1, -1).forEach(function (p) { chain.appendChild(document.createTextNode(p + ' → ')); });
      if (parts.length > (fullChain ? 0 : 1)) { chain.appendChild(el('b', null, parts[parts.length - 1])); } else { chain.textContent = '—'; }
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
    return scroll;
}

var POLL_MS = 1500;
var pollTimer = null;
var oneTimer = null;

export function stopDiagPolling() {
  if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
  if (oneTimer) { clearTimeout(oneTimer); oneTimer = null; }
}

export function renderDiag() {
  var alive = viewGuard();
  clearApp();
  var top = el('div');
  var oneBox = el('div');
  var root = el('div');
  app.appendChild(top);
  app.appendChild(oneBox);
  app.appendChild(root);
  var msgBox = el('p', 'hint');
  msgBox.hidden = true;

  function load() {
    fetchJson('/api/diag').then(function (d) {
      if (!alive()) { return; }
      draw(d);
      if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
      if (d.running) { pollTimer = setTimeout(load, POLL_MS); }
    })['catch'](function (e) { if (alive()) { showError('Не удалось получить состояние диагностики', e); } });
  }

  function start(btn) {
    btn.disabled = true;
    msgBox.hidden = true;
    fetchJson('/api/diag/start', { method: 'POST' }).then(function () { load(); })['catch'](function (e) {
      btn.disabled = false;
      if (e.data && e.data.error === 'diag_running') {
        msgBox.textContent = 'Сейчас идёт другая проверка (полная или домена). Дождитесь её окончания.';
        msgBox.hidden = false; load(); return;
      }
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
    while (top.firstChild) { top.removeChild(top.firstChild); }
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
    top.appendChild(bar);
    top.appendChild(msgBox);

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
      '«Не пускает ноду» — сервис отвечает отказом (403 или 451), хотя сама нода работает.'));
    c.appendChild(diagTable(sortServices(list), 'Сервис'));
    var legend = el('div', 'diag-legend');
    [['blocked', 'ответ 403 или 451 - доступ запрещён'],
      ['suspect', 'сервис ответил ошибкой или не ответил, но сама нода отвечает'],
      ['node_dead', 'проблема в ноде, а не в сервисе']].forEach(function (x) {
      var item = el('span');
      item.appendChild(el('span', 'v ' + x[0], verdictLabel(x[0])));
      item.appendChild(document.createTextNode(' ' + x[1]));
      legend.appendChild(item);
    });
    c.appendChild(legend);
    root.appendChild(c);
  }

  // ----- ручная проверка домена через группу other -----
  var oneCard = card('Проверить домен');
  oneCard.appendChild(el('p', 'hint', 'Домен или адрес, которого нет в группах сервисов: он проверяется через группу other - ' +
    'сначала через её текущую ноду, а если не открылся, перебираются другие ноды other.'));
  var oneRow = el('div', 'xk-add');
  var oneInp = el('input'); oneInp.type = 'text'; oneInp.placeholder = 'rutracker.org или https://example.com/page';
  oneInp.setAttribute('aria-label', 'Домен или адрес');
  var oneBtn = el('button', 'submit', 'Проверить'); oneBtn.type = 'button';
  oneRow.appendChild(oneInp); oneRow.appendChild(oneBtn);
  oneCard.appendChild(oneRow);
  var oneMsg = el('p', 'hint'); oneMsg.hidden = true;
  oneCard.appendChild(oneMsg);
  var oneRes = el('div');
  oneCard.appendChild(oneRes);
  oneBox.appendChild(oneCard);

  function drawOne(d) {
    while (oneRes.firstChild) { oneRes.removeChild(oneRes.firstChild); }
    oneBtn.disabled = !!d.running;
    if (d.stage === 'none') { return; }
    if (d.running) {
      var st = el('div', 'run-bar-row');
      st.appendChild(el('span', 'run-meta', d.current || 'Идёт проверка'));
      var sb = el('button', 'small muted', 'Остановить'); sb.type = 'button';
      sb.addEventListener('click', function () { stop(sb); });
      st.appendChild(sb);
      oneRes.appendChild(st);
    }
    if (d.stage === 'error') { oneRes.appendChild(el('p', 'diag-one-error', d.error || 'Проверка не удалась.')); return; }
    if ((d.services || []).length) { oneRes.appendChild(diagTable(d.services, 'Домен', true)); }
  }

  function loadOne() {
    fetchJson('/api/diag/one').then(function (d) {
      if (!alive()) { return; }
      drawOne(d);
      if (oneTimer) { clearTimeout(oneTimer); oneTimer = null; }
      if (d.running) { oneTimer = setTimeout(loadOne, POLL_MS); }
    })['catch'](function () { /* результат домена - необязательная часть вкладки */ });
  }

  oneBtn.addEventListener('click', function () {
    var v = oneInp.value.trim();
    if (!v) { return; }
    oneBtn.disabled = true; oneMsg.hidden = true;
    fetchJson('/api/diag/check?url=' + encodeURIComponent(v), { method: 'POST' }).then(function () { loadOne(); })['catch'](function (e) {
      oneBtn.disabled = false;
      oneMsg.textContent = (e.data && e.data.message) || ('Не удалось запустить проверку: ' + e.message);
      oneMsg.hidden = false;
    });
  });
  oneInp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { oneBtn.click(); } });

  load();
  loadOne();
}
