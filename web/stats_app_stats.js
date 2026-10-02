// Раздел «Статистика» (/stats): KPI, кнопка запуска, живой прогресс,
// график скорости по нодам (Chart.js) и таблица доступности нод.

import { app, bytesToMbit, card, clearApp, el, fetchJson, fmtMbit, fmtSigned, setLoading, showError, showNotYetMoved, statusLabel } from './app-core.js';
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
// (/api/progress, шаг 3 задачи "видно по нодам при прогоне" - шаги 1-2
// см. CHANGELOG.md) -----
//
// У /api/progress нет отдельного признака "прогона нет вовсе" (см.
// комментарий в stats_httpd.py про SPA-фоллбек, если progress.json ещё
// не существует) - поэтому "идёт ли прогон" проверяется тем же
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
  fetchJson('/api/progress').then(function (data) {
    // {} - /api/progress без файла на диске (см. комментарий в
    // stats_httpd.py: ещё не было прогона с этой версией speedtest2.sh -
    // SPA-фоллбек отдаёт index.html, fetchJson() превращает
    // нераспарсенный JSON в {}) - трактуем как "прогресса ещё нет", а
    // не как ошибку.
    updateProgressCard(data && typeof data.tested === 'number' ? data : null);
  })['catch'](function () { /* временная сетевая заминка - опрос продолжится следующим тиком */ });

  fetchJson('/api/run').then(function (d) {
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
// для подписей оси X в buildNodeChart().
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

// Вертикальное перекрестие в точке наведения - тултип Chart.js рисует
// сам, а линию под курсором - нет, поэтому небольшой локальный плагин
// (afterDraw поверх уже нарисованного графика). Регистрируется только
// на этом графике (через options.plugins ниже), глобально не нужен.
function makeCrosshairPlugin() {
  return {
    id: 'nodeCrosshair',
    afterDraw: function (chart) {
      var active = chart.getActiveElements();
      if (!active.length) { return; }
      var x = active[0].element.x;
      var area = chart.chartArea;
      var ctx = chart.ctx;
      ctx.save();
      ctx.beginPath();
      ctx.moveTo(x, area.top);
      ctx.lineTo(x, area.bottom);
      ctx.lineWidth = 1;
      ctx.strokeStyle = getComputedStyle(document.documentElement).getPropertyValue('--muted') || '#9aa0a6';
      ctx.stroke();
      ctx.restore();
    }
  };
}

// График «Скорость по нодам» (вариант A из макетов): все ноды истории,
// легенда-чипы под графиком. Наведение на чип или на линию подсвечивает
// ноду (остальные притухают, тултип - только по ней), клик по чипу
// скрывает/показывает, поиск отбирает чипы, «Только найденные» оставляет
// на графике их. Сразу показаны первые nodeHistory.cap нод по числу побед
// (настройка «Сколько нод показывать на графике сразу»). Выбор хранится
// здесь, вне DOM, по имени ноды - как stabilityFilter ниже, переживает
// перерисовку после прогона и сбрасывается только перезагрузкой страницы.
// Скрытые ноды в легенде свёрнуты (страница не раздувается от длинного
// списка зачёркнутых чипов): видны только совпавшие с поиском, остальные
// раскрывает кнопка «+ N скрытых» в конце легенды (showHidden).
var nodeChartState = { vis: {}, query: '', showHidden: false };

// withAlpha(color, a) - тот же цвет с прозрачностью: "#rrggbb" или
// "hsl(h, s%, l%)" (оба формата отдаёт node_color() в render_stats.awk).
function withAlpha(color, a) {
  if (/^#[0-9a-f]{6}$/i.test(color)) {
    return color + ('0' + Math.round(a * 255).toString(16)).slice(-2);
  }
  var m = /^hsl\((.*)\)$/.exec(color);
  return m ? 'hsla(' + m[1] + ', ' + a + ')' : color;
}

function buildNodeChart(nodeHistory, runsSeries) {
  var top = nodeHistory.top || [];
  var cap = nodeHistory.cap || 8;
  var labels = runsSeries.map(function (r) { return r.iso; });
  var wrap = el('div', 'node-chart');

  function isVisible(i) {
    var v = nodeChartState.vis[top[i].name];
    return v === undefined ? i < cap : v;
  }
  function matches(i) {
    var q = nodeChartState.query.toLowerCase();
    return !!q && top[i].name.toLowerCase().indexOf(q) >= 0;
  }

  // --- панель: поиск, счётчик, быстрые кнопки ---
  var bar = el('div', 'node-chart-bar');
  var search = el('input');
  search.type = 'text';
  search.placeholder = 'поиск ноды';
  search.setAttribute('aria-label', 'Поиск ноды на графике');
  search.value = nodeChartState.query;
  var onlyFoundBtn = el('button', 'theme-btn');
  onlyFoundBtn.type = 'button';
  var counter = el('span', 'hint node-chart-count');
  bar.appendChild(search);
  bar.appendChild(onlyFoundBtn);
  bar.appendChild(counter);
  function quickBtn(text, fn) {
    var b = el('button', 'theme-btn', text);
    b.type = 'button';
    b.addEventListener('click', fn);
    bar.appendChild(b);
  }
  quickBtn('Все', function () { top.forEach(function (n) { nodeChartState.vis[n.name] = true; }); applyVisibility(); });
  quickBtn('Топ-' + Math.min(cap, top.length), function () { top.forEach(function (n, i) { nodeChartState.vis[n.name] = i < cap; }); applyVisibility(); });
  quickBtn('Скрыть все', function () { top.forEach(function (n) { nodeChartState.vis[n.name] = false; }); applyVisibility(); });
  wrap.appendChild(bar);

  var readout = el('p', 'hint node-chart-readout');
  wrap.appendChild(readout);

  var chartWrap = el('div', 'chart-wrap');
  wrap.appendChild(chartWrap);
  var chart = null;
  if (typeof Chart === 'undefined') {
    chartWrap.appendChild(el('p', 'hint', 'chart.js не загрузился - график недоступен (переустановите install.sh).'));
  }

  // --- легенда-чипы ---
  var legend = el('div', 'legend node-legend');
  var chips = top.map(function (node, i) {
    var chip = el('button', 'node-chip');
    chip.type = 'button';
    var sw = el('span', 'sw');
    sw.style.background = node.color || '#2a78d6';
    chip.appendChild(sw);
    chip.appendChild(el('span', null, node.name));
    chip.appendChild(el('span', 'node-chip-wins', String(node.wins)));
    chip.title = 'побед: ' + node.wins + ' - клик скрывает/показывает';
    chip.addEventListener('mouseenter', function () { setHighlight(i); });
    chip.addEventListener('mouseleave', function () { setHighlight(null); });
    chip.addEventListener('focus', function () { setHighlight(i); });
    chip.addEventListener('blur', function () { setHighlight(null); });
    chip.addEventListener('click', function () {
      nodeChartState.vis[node.name] = !isVisible(i);
      applyVisibility();
      // чип мог свернуться из-под курсора - mouseleave тогда не придёт
      if (chip.classList.contains('collapsed')) { setHighlight(null); }
    });
    legend.appendChild(chip);
    return chip;
  });
  var hiddenToggle = el('button', 'node-chip node-chip-more');
  hiddenToggle.type = 'button';
  hiddenToggle.addEventListener('click', function () {
    nodeChartState.showHidden = !nodeChartState.showHidden;
    applyVisibility();
  });
  legend.appendChild(hiddenToggle);
  wrap.appendChild(legend);

  var highlighted = null;

  function fmtVal(v) { return v === null || v === undefined ? '-' : bytesToMbit(v) + ' Мбит/с'; }

  function updateReadout() {
    if (highlighted === null) {
      readout.textContent = 'Наведите курсор на ноду в легенде или на линию - она подсветится. Клик по ноде в легенде скрывает/показывает её.';
      readout.classList.remove('active');
      return;
    }
    var n = top[highlighted];
    var got = n.values.filter(function (v) { return v !== null && v !== undefined; });
    var avg = got.length ? got.reduce(function (a, b) { return a + b; }, 0) / got.length : null;
    readout.textContent = n.name + '  ·  средняя ' + fmtVal(avg) + '  ·  последний ' + fmtVal(n.values[n.values.length - 1]) +
      '  ·  в победителях ' + n.wins + ' раз' + (isVisible(highlighted) ? '' : '  (скрыта)');
    readout.classList.add('active');
  }

  // Цвет/толщина линий - scriptable-опции датасетов (см. new Chart ниже):
  // Chart.js кэширует обычные опции точек, поэтому смена цвета через
  // свойства датасета не доходила бы до точек. Здесь - только порядок
  // отрисовки (подсвеченная линия поверх остальных) и перерисовка.
  function styleDatasets() {
    if (!chart) { return; }
    chart.data.datasets.forEach(function (ds, i) { ds.order = highlighted === i ? -1 : i; });
    chart.update('none');
  }

  function setHighlight(i) {
    if (highlighted === i) { return; }
    highlighted = i;
    chips.forEach(function (c, k) { c.classList.toggle('hl', k === i); });
    styleDatasets();
    updateReadout();
  }

  function applyVisibility() {
    var shown = 0, found = 0, folded = 0;
    chips.forEach(function (c, i) {
      var vis = isVisible(i), m = matches(i);
      var fold = !vis && !m && !nodeChartState.showHidden;
      if (vis) { shown++; }
      if (m) { found++; }
      if (fold) { folded++; }
      c.classList.toggle('collapsed', fold);
      c.classList.toggle('off', !vis);
      c.classList.toggle('match', m);
      c.classList.toggle('dim', !!nodeChartState.query && !m);
      if (chart) { chart.setDatasetVisibility(i, vis); }
    });
    counter.textContent = 'показано ' + shown + ' из ' + top.length;
    // кнопка не нужна, если нечего раскрывать/сворачивать
    hiddenToggle.classList.toggle('collapsed', shown === top.length || (!nodeChartState.showHidden && folded === 0));
    hiddenToggle.textContent = nodeChartState.showHidden ? 'свернуть скрытые' : '+ ' + folded + ' скрытых';
    onlyFoundBtn.textContent = 'Только найденные (' + found + ')';
    onlyFoundBtn.disabled = found === 0;
    if (chart) { chart.update('none'); }
    updateReadout();
  }

  search.addEventListener('input', function () {
    nodeChartState.query = search.value.trim();
    applyVisibility();
  });
  onlyFoundBtn.addEventListener('click', function () {
    top.forEach(function (n, i) { nodeChartState.vis[n.name] = matches(i); });
    applyVisibility();
  });

  if (typeof Chart !== 'undefined') {
    var sameDay = sameCalendarDay(labels);
    var canvas = document.createElement('canvas');
    chartWrap.appendChild(canvas);
    var lineColor = function (ctx) {
      var i = ctx.datasetIndex, color = top[i].color || '#2a78d6';
      return highlighted !== null && highlighted !== i ? withAlpha(color, 0.12) : color;
    };
    var datasets = top.map(function (node) {
      return {
        label: node.name,
        data: node.values.map(function (v) { return v === null || v === undefined ? null : bytesToMbit(v); }),
        borderColor: lineColor,
        backgroundColor: lineColor,
        pointBackgroundColor: lineColor,
        pointBorderColor: lineColor,
        pointRadius: function (ctx) { return highlighted === ctx.datasetIndex ? 3.5 : 2.5; },
        pointHoverRadius: 4,
        borderWidth: function (ctx) { return highlighted === ctx.datasetIndex ? 3.5 : 2; },
        spanGaps: false,
        tension: 0
      };
    });

    chart = new Chart(canvas.getContext('2d'), {
      type: 'line',
      data: { labels: labels, datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: { mode: 'index', intersect: false },
        // Подсветка линии под курсором: ближайшая точка видимой ноды не
        // дальше 12 px от курсора.
        onHover: function (evt, active, ch) {
          var near = ch.getElementsAtEventForMode(evt, 'nearest', { intersect: false, axis: 'xy' }, false);
          var idx = null;
          if (near.length) {
            var p = near[0].element;
            if (Math.abs(p.x - evt.x) <= 12 && Math.abs(p.y - evt.y) <= 12) { idx = near[0].datasetIndex; }
          }
          if (idx === null && highlighted !== null && chips[highlighted] === document.activeElement) { return; }
          setHighlight(idx);
        },
        plugins: {
          legend: { display: false }, // своя легенда - чипы под графиком
          tooltip: {
            filter: function (item) { return highlighted === null || item.datasetIndex === highlighted; },
            callbacks: {
              title: function (items) { return items.length ? items[0].label : ''; },
              label: function (item) {
                return item.dataset.label + ': ' + (item.parsed.y === null ? '-' : item.parsed.y) + ' Мбит/с';
              }
            }
          }
        },
        scales: {
          x: {
            ticks: {
              autoSkip: true,
              maxTicksLimit: 6,
              maxRotation: 0,
              callback: function (value, index) {
                var iso = labels[index];
                return iso ? (sameDay ? fmtTimeShort(iso) : fmtDateShort(iso)) : '';
              }
            }
          },
          y: {
            beginAtZero: true,
            ticks: {
              callback: function (value) { return value + ' Мбит/с'; }
            }
          }
        }
      },
      plugins: [makeCrosshairPlugin()]
    });
    canvas.addEventListener('mouseleave', function () { setHighlight(null); });
  }

  applyVisibility();
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
  row.appendChild(tile('ОБНОВЛЕНИЕ', '-', 'kpiUpdateTile'));
  return row;
}

export function renderStats() {
  stopProgressPolling();
  setLoading();
  fetchJson('/api/stats').then(function (data) {
    clearApp();

    // {} - /api/stats без файла на диске (см. комментарий в
    // progressPollTick() и в stats_httpd.py про SPA-фоллбек) - трактуем
    // как "прогонов ещё не было", а не как ошибку.
    var runsCount = data.runs && typeof data.runs.count === 'number' ? data.runs.count : 0;

    var meta = el('p', 'hint', 'Обновлено: ' + (data.generated || '-') + ' · прогонов в истории: ' + runsCount);
    app.appendChild(meta);

    app.appendChild(buildKpiRow(runsCount, data.last_run));
    refreshUpdatesBadge();

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
    renderRunButton(lastRunCard, function () { startProgressPolling(app, lastRunCard); });
    app.appendChild(lastRunCard);

    var lastMeasureCard = card('Последний замер');
    if (data.last_measurement && data.last_measurement.length) {
      for (var m = 0; m < data.last_measurement.length; m++) {
        var meas = data.last_measurement[m];
        lastMeasureCard.appendChild(el('p', 'hint', meas.name + ': ' + (meas.unit === 'МБ/с' ? (Math.round(meas.speed_mb * 1048576 * 8 / 100000) / 10 + ' Мбит/с') : (meas.speed_mb + ' ' + meas.unit))));
      }
    } else {
      lastMeasureCard.appendChild(el('p', 'hint', 'Данных пока нет.'));
    }
    app.appendChild(lastMeasureCard);

    var chartCard = card('Скорость по нодам (последние ' + runsCount + ' прогонов)');
    if (data.node_history && data.node_history.total_unique > 0) {
      chartCard.appendChild(buildNodeChart(data.node_history, data.runs.series));
    } else {
      chartCard.appendChild(el('p', 'hint', 'Пока недостаточно истории для графика.'));
    }
    app.appendChild(chartCard);

    var stabilityCard = card('Статистика доступности нод');
    if (data.node_stability && data.node_stability.length) {
      var stabilityTable = buildStabilityTable(data.node_stability);
      var stabilityEmpty = el('p', 'hint', 'Нет нод с выбранными статусами.');
      stabilityCard.appendChild(buildStabilityFilter(data.node_stability, stabilityTable, stabilityEmpty));
      stabilityCard.appendChild(stabilityTable);
      stabilityCard.appendChild(stabilityEmpty);
    } else {
      stabilityCard.appendChild(el('p', 'hint', 'Данных пока нет.'));
    }
    app.appendChild(stabilityCard);
  })['catch'](function (err) {
    if (err.message === 'not_implemented') {
      showNotYetMoved('Раздел статистики ещё переезжает на новый интерфейс.');
      renderRunButton(app, function () { startProgressPolling(app, null); });
      return;
    }
    showError('Не удалось загрузить статистику: ', err);
  });
}
