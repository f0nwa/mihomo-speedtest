// Раздел «Статистика» (/stats): KPI, кнопка запуска, живой прогресс,
// лента доступности по нодам и таблица доступности нод.

import { app, bytesToMbit, card, clearApp, el, fetchJson, fmtMbit, fmtSigned, setLoading, showError, showNotYetMoved, statusLabel, viewGuard } from './app-core.js';
import { refreshUpdatesBadge } from './app-updates.js';

// ----- кнопка "Запустить сейчас" (уже полностью рабочая часть, шаг 1) -----

function renderRunButton(container, onRunning) {
  // onRunning() - необязательный колбэк, вызывается, когда обнаружился
  // (при открытии страницы) или только что начался активный прогон -
  // им пользуется startProgressPolling() ниже (карточка "Идёт прогон").
  var btn = document.createElement('button');
  btn.className = 'submit';
  btn.type = 'button';
  btn.textContent = 'Запустить сейчас';
  var status = document.createElement('p');
  status.className = 'hint';
  container.appendChild(btn);
  container.appendChild(status);

  function refreshStatus() {
    fetchJson('/api/run').then(function (d) {
      status.textContent = d.running ? 'Прогон уже идёт.' : 'Сейчас прогонов нет.';
      if (d.running && onRunning) { onRunning(); }
    })['catch'](function (err) {
      status.textContent = 'Не удалось узнать статус: ' + err.message;
    });
  }

  btn.addEventListener('click', function () {
    btn.disabled = true;
    fetchJson('/api/run', { method: 'POST' }).then(function (d) {
      status.textContent = d.started ? 'Прогон запущен.' : 'Прогон уже шёл, новый не запускался.';
      if (d.running && onRunning) { onRunning(); }
    })['catch'](function (err) {
      status.textContent = 'Не удалось запустить: ' + err.message;
    })['finally'](function () { btn.disabled = false; });
  });

  refreshStatus();
}

// ----- живой прогресс скоростного теста по нодам ТЕКУЩЕГО прогона
// (/api/progress) -----
//
// У /api/progress нет отдельного признака "прогона нет вовсе" (до первого
// прогона сервер отвечает {}) - поэтому "идёт ли прогон" проверяется тем же
// /api/run, что и раньше у кнопки "Запустить сейчас" (см. renderRunButton
// выше). Карточка обновляется НА МЕСТЕ (без переотрисовки всей
// страницы) - полный renderStats() зовётся только один раз, когда
// прогон завершается, чтобы подтянуть уже посчитанные финальные данные
// (график/таблица/"последний прогон").

var PROGRESS_POLL_MS = 2000;
var progressPollTimer = null;
var progressCardEl = null;

export function stopProgressPolling() {
  if (progressPollTimer) { clearInterval(progressPollTimer); progressPollTimer = null; }
  progressCardEl = null;
}

function buildProgressTable(results) {
  var table = el('table');
  var thead = el('thead');
  var htr = el('tr');
  ['Нода', 'Скорость, Мбит/с', 'Статус'].forEach(function (t) {
    htr.appendChild(el('th', null, t));
  });
  thead.appendChild(htr);
  table.appendChild(thead);
  var tbody = el('tbody');
  for (var i = 0; i < results.length; i++) {
    var r = results[i];
    var tr = el('tr');
    tr.appendChild(el('td', null, r.name));
    tr.appendChild(el('td', null, fmtMbit(r.speed_bytes)));
    var ok = r.status === 'ok';
    tr.appendChild(el('td', ok ? 'status-alive' : 'status-absent', ok ? 'выше порога' : 'ниже порога'));
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  return table;
}

function updateProgressCard(progress) {
  if (!progressCardEl) { return; }
  var tested = progress && typeof progress.tested === 'number' ? progress.tested : 0;
  var total = progress && typeof progress.total === 'number' ? progress.total : 0;
  var results = (progress && progress.results) || [];
  var summary = progressCardEl.querySelector('.progress-summary');
  summary.textContent = total > 0
    ? ('Протестировано ' + tested + ' из ' + total + '.')
    : 'Ожидание начала скоростного теста...';
  var oldTable = progressCardEl.querySelector('table');
  var table = buildProgressTable(results);
  if (oldTable) { progressCardEl.replaceChild(table, oldTable); } else { progressCardEl.appendChild(table); }
}

function progressPollTick() {
  var alive = viewGuard();
  fetchJson('/api/progress').then(function (data) {
    if (!alive()) { return; }
    // {} - прогона ещё не было (файла progress.json нет) - трактуем как
    // "прогресса ещё нет", а не как ошибку.
    updateProgressCard(data && typeof data.tested === 'number' ? data : null);
  })['catch'](function () { /* временная сетевая заминка - опрос продолжится следующим тиком */ });

  fetchJson('/api/run').then(function (d) {
    if (!alive()) { return; }
    if (!d.running) {
      stopProgressPolling();
      renderStats();
    }
  })['catch'](function () { /* см. выше */ });
}

function startProgressPolling(container, insertBefore) {
  if (!progressCardEl) {
    progressCardEl = card('Идёт прогон');
    progressCardEl.appendChild(el('p', 'hint progress-summary', 'Ожидание начала скоростного теста...'));
    if (insertBefore) { container.insertBefore(progressCardEl, insertBefore); } else { container.appendChild(progressCardEl); }
  }
  if (progressPollTimer) { return; }
  progressPollTick();
  progressPollTimer = setInterval(progressPollTick, PROGRESS_POLL_MS);
}

// ----- раздел "Статистика" (/api/stats) -----

// fmtDateShort/fmtTimeShort - как fmt_date_short()/fmt_time_short() в
// render_stats.awk: iso в формате "YYYY-MM-DD HH:MM:SS". Используются
// для подписей оси времени ленты доступности.
function fmtDateShort(iso) {
  return iso.slice(8, 10) + '.' + iso.slice(5, 7);
}
function fmtTimeShort(iso) {
  return iso.slice(11, 16);
}

// fmtLastSeen(iso) - "последний раз жива" в таблице "Доступность нод
// пула": last_seen из node_stability.tsv (см. node_stats_update.awk) -
// та же строка "YYYY-MM-DD HH:MM:SS", что и iso прогонов, пусто, если
// нода ни разу не отвечала (ещё не тестировалась/только добавлена).
function fmtLastSeen(iso) {
  if (!iso) { return '-'; }
  return fmtDateShort(iso) + ' ' + fmtTimeShort(iso);
}

// Все прогоны попадают в один календарный день - тогда подписи оси X
// это время, иначе дата (тот же критерий, что был у старого
// render_x_axis_dates() в render_stats.awk).
function sameCalendarDay(labels) {
  if (!labels.length) { return true; }
  var day1 = labels[0].slice(0, 10);
  for (var i = 1; i < labels.length; i++) {
    if (labels[i].slice(0, 10) !== day1) { return false; }
  }
  return true;
}

// ----- лента доступности по нодам -----
// Строка на ноду, клетка на прогон: жива / не ответила / не проверялась.
// Данные - поле window из node_stability.tsv (node_stats_update.awk: по
// символу на прогон, последний справа), на роутере ничего не считается.
// Ноды уже отсортированы по аптайму (render_stats.awk); по умолчанию
// показываются первые node_history.cap (настройка «Сколько нод
// показывать»), остальные - кнопкой «Все» или поиском.

var UPTIME_ROW_H = 14;      // высота строки, CSS px
var UPTIME_CELL_GAP = 1;    // зазор между клетками, если клетка шире 3 px
var uptimeState = { query: '', all: false };

function cssVar(name, fallback) {
  var v = getComputedStyle(document.documentElement).getPropertyValue(name);
  return (v && v.trim()) || fallback;
}

var UPTIME_LABELS = { A: 'жива', D: 'не ответила', S: 'не проверялась', '.': 'не было в подписке' };

function buildUptimeTimeline(nodes, runsSeries, cap) {
  var wrap = el('div', 'uptime');
  var cols = 0;
  nodes.forEach(function (n) { cols = Math.max(cols, (n.window || '').length); });
  if (!cols) {
    wrap.appendChild(el('p', 'hint', 'Пока недостаточно истории для ленты.'));
    return wrap;
  }
  // Клетка col (0..cols-1) - прогон runsSeries[runs - cols + col], если он
  // ещё есть в сводке (сводку могли обрезать по сроку хранения раньше окна).
  function runIso(col) {
    var r = runsSeries[runsSeries.length - cols + col];
    return r ? r.iso : '';
  }
  function cell(node, col) {
    var w = node.window || '';
    var i = col - (cols - w.length);
    return i >= 0 ? w.charAt(i) : '.';
  }

  // --- панель: поиск и переключатель количества ---
  var bar = el('div', 'node-chart-bar');
  var search = el('input');
  search.type = 'text';
  search.placeholder = 'поиск ноды';
  search.setAttribute('aria-label', 'Поиск ноды в ленте доступности');
  search.value = uptimeState.query;
  var counter = el('span', 'hint node-chart-count');
  var toggle = el('button', 'theme-btn');
  toggle.type = 'button';
  bar.appendChild(search);
  bar.appendChild(counter);
  bar.appendChild(toggle);
  wrap.appendChild(bar);

  var readout = el('p', 'hint node-chart-readout', 'Наведите курсор на клетку - покажет время прогона и статус ноды.');
  wrap.appendChild(readout);

  var rowsBox = el('div', 'uptime-rows');
  wrap.appendChild(rowsBox);
  var axis = el('div', 'uptime-axis');
  wrap.appendChild(axis);

  var legend = el('div', 'legend');
  [['sw-alive', 'жива'], ['sw-down', 'не ответила'], ['sw-skip', 'не проверялась'], ['sw-none', 'не было в подписке']].forEach(function (it) {
    var li = el('span', 'legend-item');
    li.appendChild(el('span', 'sw ' + it[0]));
    li.appendChild(document.createTextNode(it[1]));
    legend.appendChild(li);
  });
  wrap.appendChild(legend);

  var colors = {
    A: cssVar('--accent', '#35c7c7'),
    D: cssVar('--danger', '#d1453b'),
    S: cssVar('--muted', '#8b9096'),
    grid: cssVar('--border', '#26292c'),
    hover: cssVar('--text', '#e7e6e2')
  };
  var rows = [];      // {node, canvas}
  var hoverCol = -1;

  function draw(row) {
    var c = row.canvas;
    var wCss = c.clientWidth;
    if (!wCss) { return; }
    var dpr = window.devicePixelRatio || 1;
    c.width = Math.round(wCss * dpr);
    c.height = Math.round(UPTIME_ROW_H * dpr);
    var ctx = c.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, wCss, UPTIME_ROW_H);
    var cw = wCss / cols;
    var gap = cw > 3 ? UPTIME_CELL_GAP : 0;
    ctx.fillStyle = colors.grid;
    ctx.fillRect(0, UPTIME_ROW_H - 1, wCss, 1);
    for (var col = 0; col < cols; col++) {
      var ch = cell(row.node, col);
      if (ch === '.') { continue; }
      var x = col * cw;
      ctx.fillStyle = colors[ch] || colors.S;
      if (ch === 'S') {
        // «не проверялась» - половина высоты: отличается не только цветом
        ctx.fillRect(x, UPTIME_ROW_H / 2, Math.max(1, cw - gap), UPTIME_ROW_H / 2 - 1);
      } else {
        ctx.fillRect(x, 1, Math.max(1, cw - gap), UPTIME_ROW_H - 2);
      }
    }
    if (hoverCol >= 0) {
      ctx.fillStyle = colors.hover;
      ctx.globalAlpha = 0.35;
      ctx.fillRect(hoverCol * cw, 0, Math.max(1, cw - gap), UPTIME_ROW_H);
      ctx.globalAlpha = 1;
    }
  }
  function drawAll() { rows.forEach(draw); }

  function setHover(row, col) {
    hoverCol = col;
    drawAll();
    if (col < 0 || !row) {
      readout.textContent = 'Наведите курсор на клетку - покажет время прогона и статус ноды.';
      readout.classList.remove('active');
      return;
    }
    var iso = runIso(col);
    readout.textContent = row.node.name + ' · ' + (iso ? fmtLastSeen(iso) : 'прогон старше сводки') + ' · ' + UPTIME_LABELS[cell(row.node, col)];
    readout.classList.add('active');
  }

  function visibleNodes() {
    var q = uptimeState.query.toLowerCase();
    if (q) { return nodes.filter(function (n) { return n.name.toLowerCase().indexOf(q) >= 0; }); }
    return uptimeState.all ? nodes : nodes.slice(0, cap);
  }

  function rebuild() {
    while (rowsBox.firstChild) { rowsBox.removeChild(rowsBox.firstChild); }
    rows = [];
    var list = visibleNodes();
    list.forEach(function (node) {
      var r = el('div', 'uptime-row');
      var name = el('span', 'uptime-name', node.name);
      name.title = node.name;
      var canvas = document.createElement('canvas');
      canvas.className = 'uptime-strip';
      canvas.setAttribute('role', 'img');
      canvas.setAttribute('aria-label', node.name + ': аптайм ' + (node.uptime_pct === null ? 'нет данных' : node.uptime_pct + '%'));
      var pct = el('span', 'uptime-pct', node.uptime_pct === null ? '-' : node.uptime_pct + '%');
      r.appendChild(name); r.appendChild(canvas); r.appendChild(pct);
      rowsBox.appendChild(r);
      var row = { node: node, canvas: canvas };
      rows.push(row);
      canvas.addEventListener('mousemove', function (e) {
        var rect = canvas.getBoundingClientRect();
        var col = Math.floor((e.clientX - rect.left) / rect.width * cols);
        setHover(row, Math.max(0, Math.min(cols - 1, col)));
      });
      canvas.addEventListener('mouseleave', function () { setHover(null, -1); });
    });
    if (!list.length) { rowsBox.appendChild(el('p', 'hint', 'Нет нод по запросу.')); }
    counter.textContent = 'показано ' + list.length + ' из ' + nodes.length;
    toggle.textContent = uptimeState.all ? 'Топ-' + Math.min(cap, nodes.length) : 'Все (' + nodes.length + ')';
    toggle.disabled = !!uptimeState.query || nodes.length <= cap;
    drawAll();
  }

  // подписи оси времени: первый, средний и последний прогон окна
  function buildAxis() {
    var isos = [];
    for (var col = 0; col < cols; col++) { isos.push(runIso(col)); }
    var known = isos.filter(Boolean);
    var sameDay = sameCalendarDay(known);
    [0, Math.floor((cols - 1) / 2), cols - 1].forEach(function (col, k) {
      var iso = isos[col];
      var s = el('span', '', iso ? (sameDay ? fmtTimeShort(iso) : fmtDateShort(iso) + ' ' + fmtTimeShort(iso)) : '');
      s.style.textAlign = ['left', 'center', 'right'][k];
      axis.appendChild(s);
    });
  }

  search.addEventListener('input', function () { uptimeState.query = search.value; rebuild(); });
  toggle.addEventListener('click', function () { uptimeState.all = !uptimeState.all; rebuild(); });
  var onResize = function () {
    if (!wrap.isConnected) { window.removeEventListener('resize', onResize); return; }
    drawAll();
  };
  window.addEventListener('resize', onResize);

  buildAxis();
  rebuild();
  // canvas получает ширину только после вставки в документ
  requestAnimationFrame(drawAll);
  return wrap;
}

// Фильтр «Статистики доступности нод» по статусу. Работает только в
// браузере по уже полученному /api/stats. Выбор хранится здесь, вне
// DOM: renderStats() пересоздаёт карточку при каждой загрузке и после
// завершения прогона, а фильтр должен пережить перерисовку. Сбрасывается
// только перезагрузкой страницы.
var STABILITY_GROUPS = [
  { key: 'alive', label: 'жива', sw: 'sw-alive' },
  { key: 'down', label: 'недоступна', sw: 'sw-down' },
  { key: 'other', label: 'нет данных / не проверена', sw: 'sw-absent' }
];
var stabilityFilter = { alive: true, down: true, other: true };

function stabilityGroup(status) {
  return status === 'alive' || status === 'down' ? status : 'other';
}

function buildStabilityFilter(rows, table, emptyHint) {
  var wrap = el('div', 'stability-filter');
  var counts = { alive: 0, down: 0, other: 0 };
  rows.forEach(function (r) { counts[stabilityGroup(r.status)]++; });
  function apply() {
    var trs = table.tBodies[0].rows;
    var shown = 0;
    for (var i = 0; i < trs.length; i++) {
      var visible = !!stabilityFilter[trs[i].getAttribute('data-group')];
      trs[i].hidden = !visible;
      if (visible) { shown++; }
    }
    table.hidden = shown === 0;
    emptyHint.hidden = shown !== 0;
  }
  STABILITY_GROUPS.forEach(function (g) {
    var label = el('label', 'stability-filter-item');
    var cb = el('input');
    cb.type = 'checkbox';
    cb.checked = !!stabilityFilter[g.key];
    cb.setAttribute('data-group', g.key);
    cb.addEventListener('change', function () {
      stabilityFilter[g.key] = cb.checked;
      apply();
    });
    label.appendChild(cb);
    label.appendChild(el('span', 'sw ' + g.sw));
    label.appendChild(document.createTextNode(g.label + ' (' + counts[g.key] + ')'));
    wrap.appendChild(label);
  });
  apply();
  return wrap;
}

// Сортировка «Статистики доступности нод» кликом по заголовку столбца: первый
// клик - направление по умолчанию для столбца (dir ниже), повторный -
// обратное. Пустые значения (null, нет данных) всегда внизу. Выбор
// хранится вне DOM, как stabilityFilter, и переживает перерисовку;
// до первого клика - порядок сервера (по убыванию uptime).
var STATUS_ORDER = { alive: 0, down: 1, skipped: 2 };
var STABILITY_COLUMNS = [
  { title: 'Нода', key: 'name', dir: 1, get: function (r) { return r.name ? r.name.toLowerCase() : null; } },
  { title: 'Статус', key: 'status', dir: 1, get: function (r) { return r.status in STATUS_ORDER ? STATUS_ORDER[r.status] : 3; } },
  { title: 'Последний раз жива', key: 'last_seen', dir: -1, get: function (r) { return r.last_seen || null; } },
  { title: 'Uptime', key: 'uptime', dir: -1, get: function (r) { return r.uptime_pct; } },
  { title: 'Сейчас, Мбит/с', key: 'last', dir: -1, get: function (r) { return r.last_speed_bytes; } },
  { title: 'Средняя, Мбит/с', key: 'avg', dir: -1, get: function (r) { return r.avg_speed_bytes; } },
  { title: 'Δ, Мбит/с', key: 'delta', dir: -1, get: function (r) { return r.delta_bytes; } }
];
var stabilitySort = { key: null, dir: 1 };

function sortStabilityRows(rows) {
  var col = null;
  STABILITY_COLUMNS.forEach(function (c) { if (c.key === stabilitySort.key) { col = c; } });
  if (!col) { return rows.slice(); }
  return rows.map(function (r, i) { return { r: r, i: i, v: col.get(r) }; }).sort(function (a, b) {
    var an = a.v === null || a.v === undefined, bn = b.v === null || b.v === undefined;
    if (an || bn) { return an === bn ? a.i - b.i : (an ? 1 : -1); }
    var c = typeof a.v === 'string' ? a.v.localeCompare(b.v) : a.v - b.v;
    return c ? c * stabilitySort.dir : a.i - b.i;
  }).map(function (x) { return x.r; });
}

function buildStabilityTable(rows) {
  var table = el('table', 'stability-table');
  var thead = el('thead');
  var htr = el('tr');
  htr.appendChild(el('th'));
  var headBtns = [];
  STABILITY_COLUMNS.forEach(function (col) {
    var th = el('th');
    var btn = el('button', 'th-sort');
    btn.type = 'button';
    btn.addEventListener('click', function () {
      if (stabilitySort.key === col.key) { stabilitySort.dir = -stabilitySort.dir; }
      else { stabilitySort.key = col.key; stabilitySort.dir = col.dir; }
      fillBody();
    });
    th.appendChild(btn);
    htr.appendChild(th);
    headBtns.push({ col: col, th: th, btn: btn });
  });
  thead.appendChild(htr);
  table.appendChild(thead);
  var tbody = el('tbody');
  table.appendChild(tbody);

  function fillBody() {
    headBtns.forEach(function (h) {
      var on = stabilitySort.key === h.col.key;
      h.btn.textContent = h.col.title + (on ? (stabilitySort.dir > 0 ? ' ▲' : ' ▼') : '');
      h.btn.classList.toggle('on', on);
      h.th.setAttribute('aria-sort', on ? (stabilitySort.dir > 0 ? 'ascending' : 'descending') : 'none');
    });
    while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
    sortStabilityRows(rows).forEach(function (r) {
      var tr = el('tr');
      var group = stabilityGroup(r.status);
      tr.setAttribute('data-group', group);
      tr.hidden = !stabilityFilter[group];
      var st = statusLabel(r.status);
      var swTd = el('td');
      swTd.appendChild(el('span', 'sw ' + st.sw));
      tr.appendChild(swTd);
      tr.appendChild(el('td', null, r.name));
      tr.appendChild(el('td', st.cls, st.text));
      tr.appendChild(el('td', null, fmtLastSeen(r.last_seen)));
      tr.appendChild(el('td', null, r.uptime_pct === null ? '-' : r.uptime_pct + '%'));
      tr.appendChild(el('td', null, fmtMbit(r.last_speed_bytes)));
      tr.appendChild(el('td', null, fmtMbit(r.avg_speed_bytes)));
      tr.appendChild(el('td', null, fmtSigned(r.delta_bytes)));
      tbody.appendChild(tr);
    });
  }
  fillBody();
  return table;
}

function buildKpiRow(runsCount, lastRun) {
  var row = el('div', 'kpi-row');
  function tile(label, value, id) {
    var t = el('div', 'kpi');
    if (id) { t.id = id; }
    t.appendChild(el('div', 'kpi-label', label));
    var v = el('div', 'kpi-value', value);
    if (id) { v.id = id + 'Value'; }
    t.appendChild(v);
    return t;
  }
  row.appendChild(tile('ПРОГОНОВ В ИСТОРИИ', String(runsCount)));
  row.appendChild(tile('ЖИВЫХ НОД', lastRun ? (lastRun.alive + '/' + lastRun.total) : '-'));
  row.appendChild(tile('КАНАЛ', lastRun ? (fmtMbit(lastRun.channel_bytes) + ' Мбит/с') : '-'));
  row.appendChild(tile('ПОРОГ', lastRun ? (fmtMbit(lastRun.threshold_bytes) + ' Мбит/с') : '-'));
  row.appendChild(tile('ПОБЕДИТЕЛЕЙ', lastRun ? String(lastRun.winners) : '-'));
  row.appendChild(tile('ОБНОВЛЕНИЕ', '-', 'kpiUpdateTile'));
  return row;
}

export function renderStats() {
  stopProgressPolling();
  setLoading();
  var alive = viewGuard();
  fetchJson('/api/stats').then(function (data) {
    if (!alive()) { return; }
    clearApp();

    // {} - stats.json ещё нет - трактуем как "прогонов ещё не было", а не
    // как ошибку.
    var runsCount = data.runs && typeof data.runs.count === 'number' ? data.runs.count : 0;

    var meta = el('p', 'hint', 'Обновлено: ' + (data.generated || '-') + ' · прогонов в истории: ' + runsCount);
    app.appendChild(meta);

    app.appendChild(buildKpiRow(runsCount, data.last_run));
    refreshUpdatesBadge();

    // Карточки идут рядами (.card-row): на широком экране - рядом, на
    // узком - друг под другом. Карточка "Идёт прогон" встаёт перед рядом.
    var topRow = el('div', 'card-row');
    app.appendChild(topRow);
    var lastRunCard = card('Последний прогон');
    if (data.last_run) {
      var lr = data.last_run;
      var p = el('p', 'hint');
      p.textContent = lr.iso + ' - канал: ' + fmtMbit(lr.channel_bytes) + ' Мбит/с, порог: ' +
        fmtMbit(lr.threshold_bytes) + ' Мбит/с, живых нод: ' + lr.alive + '/' + lr.total +
        ', победителей: ' + lr.winners;
      lastRunCard.appendChild(p);
    } else {
      lastRunCard.appendChild(el('p', 'hint', 'Прогонов ещё не было.'));
    }
    // Кнопка ручного запуска - в этой же карточке ("состояние и время
    // последнего прогона"), чтобы её было видно сразу, без прокрутки
    // вниз мимо графика и таблицы доступности (см. TODO.md).
    renderRunButton(lastRunCard, function () { startProgressPolling(app, topRow); });
    topRow.appendChild(lastRunCard);

    var lastMeasureCard = card('Последний замер');
    if (data.last_measurement && data.last_measurement.length) {
      for (var m = 0; m < data.last_measurement.length; m++) {
        var meas = data.last_measurement[m];
        lastMeasureCard.appendChild(el('p', 'hint', meas.name + ': ' + (meas.unit === 'МБ/с' ? (Math.round(meas.speed_mb * 1048576 * 8 / 100000) / 10 + ' Мбит/с') : (meas.speed_mb + ' ' + meas.unit))));
      }
    } else {
      lastMeasureCard.appendChild(el('p', 'hint', 'Данных пока нет.'));
    }
    topRow.appendChild(lastMeasureCard);

    var mainRow = el('div', 'card-row card-row-wide');
    app.appendChild(mainRow);

    var chartCard = card('Доступность нод по прогонам');
    if (data.node_stability && data.node_stability.length) {
      var cap = (data.node_history && data.node_history.cap) || 8;
      chartCard.appendChild(buildUptimeTimeline(data.node_stability, (data.runs && data.runs.series) || [], cap));
    } else {
      chartCard.appendChild(el('p', 'hint', 'Пока недостаточно истории для ленты.'));
    }
    mainRow.appendChild(chartCard);

    var stabilityCard = card('Статистика доступности нод');
    if (data.node_stability && data.node_stability.length) {
      var stabilityTable = buildStabilityTable(data.node_stability);
      var stabilityEmpty = el('p', 'hint', 'Нет нод с выбранными статусами.');
      stabilityCard.appendChild(buildStabilityFilter(data.node_stability, stabilityTable, stabilityEmpty));
      var tableBox = el('div', 'table-scroll');
      tableBox.appendChild(stabilityTable);
      stabilityCard.appendChild(tableBox);
      stabilityCard.appendChild(stabilityEmpty);
    } else {
      stabilityCard.appendChild(el('p', 'hint', 'Данных пока нет.'));
    }
    mainRow.appendChild(stabilityCard);
  })['catch'](function (err) {
    if (!alive()) { return; }
    if (err.message === 'not_implemented') {
      showNotYetMoved('Раздел статистики ещё переезжает на новый интерфейс.');
      renderRunButton(app, function () { startProgressPolling(app, null); });
      return;
    }
    showError('Не удалось загрузить статистику: ', err);
  });
}
