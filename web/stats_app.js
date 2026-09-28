// Клиентский роутер и логика SPA-shell веб-сервиса статистики speedtest2
// (index.html + style.css) - см. docs/plans/2026-09-12-web-spa-migration-design.md.
// Ставится install.sh как $DIR/stats_app.js; копия внутри раздаваемого
// каталога (app.js) пишется сама write_stats_static() из speedtest2.sh -
// править нужно этот файл, не копию.
//
// Шаг 4 плана: "/api/stats" и "/api/settings" теперь отдают реальные
// данные (см. render_stats.awk -v format=json и print_settings_json() в
// stats_cgi.sh) - вместо заглушки "раздел переезжает" здесь рисуются сами
// разделы.
//
// График по нодам (buildNodeChart() ниже) рисует Chart.js - stats_chart.js
// (вендоренная UMD-сборка, MIT, кладётся рядом с этим файлом и раздаётся
// как есть, без npm/сборки на роутере - тег <script src="chart.js">
// подключается в stats_index.html перед этим файлом). Раньше график был
// на ручном SVG - от него отказались, когда всплыли кросс-браузерные баги
// с перехватом событий мыши (см. CHANGELOG.md).
(function () {
  'use strict';

  var app = document.getElementById('app');
  var mainNav = document.getElementById('mainNav');
  var logoutBtn = document.getElementById('logoutBtn');
  var authState = null;

  function updateActiveNav(path) {
    var links = document.querySelectorAll('nav a[data-link]');
    for (var i = 0; i < links.length; i++) {
      var href = links[i].getAttribute('href');
      var isActive = href === path || (path === '/' && href === '/stats');
      links[i].classList.toggle('active', isActive);
    }
  }

  function navigate(path) {
    history.pushState(null, '', path);
    render(path);
    updateActiveNav(path);
  }

  document.addEventListener('click', function (e) {
    var el = e.target;
    while (el && el !== document && !(el.tagName === 'A' && el.hasAttribute('data-link'))) {
      el = el.parentNode;
    }
    if (!el || el === document) { return; }
    e.preventDefault();
    navigate(el.getAttribute('href'));
  });

  window.addEventListener('popstate', function () {
    if (authState) {
      render(location.pathname);
      updateActiveNav(location.pathname);
    } else {
      loadAuth();
    }
  });

  function clearApp() {
    while (app.firstChild) { app.removeChild(app.firstChild); }
  }

  function setLoading() {
    clearApp();
    var p = document.createElement('p');
    p.className = 'hint';
    p.textContent = 'Загрузка...';
    app.appendChild(p);
  }

  function showNotYetMoved(text) {
    clearApp();
    var p = document.createElement('p');
    p.className = 'hint';
    p.textContent = text;
    app.appendChild(p);
    return p;
  }

  function showError(prefix, err) {
    clearApp();
    var p = document.createElement('p');
    p.className = 'msg-err';
    p.textContent = prefix + (err && err.message ? err.message : String(err));
    app.appendChild(p);
  }

  function fetchJson(url, opts) {
    opts = opts || {};
    var method = (opts.method || 'GET').toUpperCase();
    var headers = new Headers(opts.headers || {});
    if (authState && authState.csrf && method !== 'GET' && method !== 'HEAD') {
      headers.set('X-CSRF-Token', authState.csrf);
    }
    var requestOpts = {};
    Object.keys(opts).forEach(function (key) { requestOpts[key] = opts[key]; });
    requestOpts.headers = headers;
    requestOpts.credentials = 'same-origin';
    return fetch(url, requestOpts).then(function (r) {
      return r.json()['catch'](function () { return {}; }).then(function (data) {
        if (!r.ok) {
          var error = new Error(data && data.error ? data.error : ('HTTP ' + r.status));
          error.status = r.status;
          if (r.status === 401 && url.indexOf('/api/auth/') !== 0) {
            authState = null;
            history.replaceState(null, '', '/login');
            renderAuthForm('login');
            return new Promise(function () {});
          }
          throw error;
        }
        return data;
      });
    });
  }

  // ----- мелкие DOM/форматирующие помощники -----

  function el(tag, className, text) {
    var n = document.createElement(tag);
    if (className) { n.className = className; }
    if (text !== undefined && text !== null) { n.textContent = text; }
    return n;
  }

  function card(title) {
    var c = el('div', 'card');
    if (title) { c.appendChild(el('h2', null, title)); }
    return c;
  }

  // Байты/с -> Мбит/с (x8 / 1 000 000, как в спидтестах) числом с одним
  // знаком после точки (без лишнего нуля).
  function bytesToMbit(bytes) {
    return Math.round(bytes * 8 / 100000) / 10;
  }

  // Байты/с -> Мбит/с текстом, null/undefined -> "-".
  function fmtMbit(bytes) {
    if (bytes === null || bytes === undefined) { return '-'; }
    return String(bytesToMbit(bytes));
  }

  function fmtSigned(bytes) {
    if (bytes === null || bytes === undefined) { return '-'; }
    var s = fmtMbit(Math.abs(bytes));
    if (bytes > 0) { return '+' + s; }
    if (bytes < 0) { return '-' + s; }
    return s;
  }

  function statusLabel(status) {
    if (status === 'alive') { return { text: 'жива', cls: 'status-alive', sw: 'sw-alive' }; }
    if (status === 'down') { return { text: 'недоступна', cls: 'status-down', sw: 'sw-down' }; }
    // skipped - WG/AWG-нода в пуле, но не проверена (нет входа замера в основном ядре)
    if (status === 'skipped') { return { text: 'не проверена', cls: 'status-absent', sw: 'sw-absent' }; }
    return { text: 'нет данных', cls: 'status-absent', sw: 'sw-absent' };
  }

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
        status.textContent = d.running ? 'Прогон уже идёт.' : 'Сейчас прогонов не идёт.';
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

  function stopProgressPolling() {
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

  // buildNodeChart() - график по нодам на Chart.js (см. комментарий в
  // начале файла про stats_chart.js). runsSeries - data.runs.series из
  // /api/stats (нужен только iso[] для подписей оси X и тултипа).
  function buildNodeChart(nodeHistory, runsSeries) {
    var top = nodeHistory.top || [];
    var labels = runsSeries.map(function (r) { return r.iso; });

    var wrap = el('div', 'chart-wrap');

    if (typeof Chart === 'undefined') {
      wrap.appendChild(el('p', 'hint', 'chart.js не загрузился - график недоступен (переустановите install.sh).'));
      return wrap;
    }

    var sameDay = sameCalendarDay(labels);
    var canvas = document.createElement('canvas');
    wrap.appendChild(canvas);

    var datasets = top.map(function (node) {
      var color = node.color || '#2a78d6';
      return {
        label: node.name,
        data: node.values.map(function (v) { return v === null || v === undefined ? null : bytesToMbit(v); }),
        borderColor: color,
        backgroundColor: color,
        pointRadius: 2.5,
        pointHoverRadius: 4,
        borderWidth: 2,
        spanGaps: false,
        tension: 0
      };
    });

    new Chart(canvas.getContext('2d'), {
      type: 'line',
      data: { labels: labels, datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: false }, // своя легенда - buildNodeLegend() (в ней ещё и число побед)
          tooltip: {
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

    return wrap;
  }

  function buildNodeLegend(nodeHistory) {
    var wrap = el('div', 'legend');
    var top = nodeHistory.top || [];
    for (var k = 0; k < top.length; k++) {
      var item = el('span', 'legend-item');
      var sw = el('span', 'sw');
      sw.style.background = top[k].color || '#2a78d6';
      item.appendChild(sw);
      item.appendChild(document.createTextNode(top[k].name + ' (побед: ' + top[k].wins + ')'));
      wrap.appendChild(item);
    }
    return wrap;
  }

  // Фильтр «Доступности нод пула» по статусу. Работает только в
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

  function buildStabilityTable(rows) {
    var table = el('table');
    var thead = el('thead');
    var htr = el('tr');
    [''].concat(['Нода', 'Статус', 'Последний раз жива', 'Uptime', 'Сейчас, Мбит/с', 'Средняя, Мбит/с', 'Δ, Мбит/с']).forEach(function (t) {
      htr.appendChild(el('th', null, t));
    });
    thead.appendChild(htr);
    table.appendChild(thead);
    var tbody = el('tbody');
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      var tr = el('tr');
      tr.setAttribute('data-group', stabilityGroup(r.status));
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
    }
    table.appendChild(tbody);
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

  function renderStats() {
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
        chartCard.appendChild(buildNodeLegend(data.node_history));
        chartCard.appendChild(buildNodeChart(data.node_history, data.runs.series));
      } else {
        chartCard.appendChild(el('p', 'hint', 'Пока недостаточно истории для графика.'));
      }
      app.appendChild(chartCard);

      var stabilityCard = card('Доступность нод пула');
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

  // ----- гео-фильтр спидтеста (BLOCK): карточка "Какие ноды не проверять" -----
  // Дизайн: docs/superpowers/specs/2026-09-28-block-filter-ui-design.md.
  // BLOCK - не regex, а список подстрок через | (см. prep.awk): нода
  // пропускается, если её имя содержит любое слово без учёта регистра.
  // Блок между метками GEO-LOGIC-BEGIN/END - чистые функции без DOM;
  // tests/test_stats_geo_filter.sh вырезает его и проверяет в node.
  // GEO-LOGIC-BEGIN
  function geoCountry(code, flag, ru, en, extra, common) {
    return { code: code, flag: flag, ru: ru, words: [flag, en, ru].concat(extra || []), common: !!common };
  }

  // Наборы слов - только флаг и полные названия (у "других" стран ещё
  // столица/хаб): голые 2-3-буквенные коды совпадали бы внутри чужих
  // имён ("RU" - Brussels, Peru; "USA" - Jerusalem). У России - ещё
  // привычные метки нод из шаблона (MSK/SPB оставлены сознательно).
  var GEO_CATALOG = [
    geoCountry('RU', '🇷🇺', 'Россия', 'Russia', ['RU-', 'RU_', 'Moscow', 'Москва', 'MSK', 'SPB', 'СПб'], true),
    geoCountry('UA', '🇺🇦', 'Украина', 'Ukraine', [], true),
    geoCountry('KZ', '🇰🇿', 'Казахстан', 'Kazakhstan', [], true),
    geoCountry('TR', '🇹🇷', 'Турция', 'Turkey', ['Türkiye'], true),
    geoCountry('IL', '🇮🇱', 'Израиль', 'Israel', [], true),
    geoCountry('IN', '🇮🇳', 'Индия', 'India', [], true),
    geoCountry('JP', '🇯🇵', 'Япония', 'Japan', [], true),
    geoCountry('KR', '🇰🇷', 'Корея', 'Korea', [], true),
    geoCountry('MY', '🇲🇾', 'Малайзия', 'Malaysia', [], true),
    geoCountry('AU', '🇦🇺', 'Австралия', 'Australia', [], true),
    geoCountry('ZA', '🇿🇦', 'ЮАР', 'South Africa', [], true),
    geoCountry('NG', '🇳🇬', 'Нигерия', 'Nigeria', [], true),
    geoCountry('BR', '🇧🇷', 'Бразилия', 'Brazil', [], true),
    geoCountry('AR', '🇦🇷', 'Аргентина', 'Argentina', [], true),
    geoCountry('CL', '🇨🇱', 'Чили', 'Chile', [], true),
    geoCountry('CO', '🇨🇴', 'Колумбия', 'Colombia', [], true),
    geoCountry('PE', '🇵🇪', 'Перу', 'Peru', [], true),
    geoCountry('MX', '🇲🇽', 'Мексика', 'Mexico', [], true),
    geoCountry('US', '🇺🇸', 'США', 'United States', []),
    geoCountry('CA', '🇨🇦', 'Канада', 'Canada', []),
    geoCountry('GB', '🇬🇧', 'Великобритания', 'United Kingdom', ['London']),
    geoCountry('DE', '🇩🇪', 'Германия', 'Germany', ['Frankfurt']),
    geoCountry('NL', '🇳🇱', 'Нидерланды', 'Netherlands', ['Amsterdam']),
    geoCountry('FR', '🇫🇷', 'Франция', 'France', ['Paris']),
    geoCountry('FI', '🇫🇮', 'Финляндия', 'Finland', ['Helsinki']),
    geoCountry('SE', '🇸🇪', 'Швеция', 'Sweden', ['Stockholm']),
    geoCountry('PL', '🇵🇱', 'Польша', 'Poland', ['Warsaw']),
    geoCountry('EE', '🇪🇪', 'Эстония', 'Estonia', ['Tallinn']),
    geoCountry('LV', '🇱🇻', 'Латвия', 'Latvia', ['Riga']),
    geoCountry('LT', '🇱🇹', 'Литва', 'Lithuania', ['Vilnius']),
    geoCountry('CH', '🇨🇭', 'Швейцария', 'Switzerland', ['Zurich']),
    geoCountry('AT', '🇦🇹', 'Австрия', 'Austria', ['Vienna']),
    geoCountry('SG', '🇸🇬', 'Сингапур', 'Singapore', []),
    geoCountry('HK', '🇭🇰', 'Гонконг', 'Hong Kong', [])
  ];

  function geoLc(s) { return String(s).toLowerCase(); }

  // Строка BLOCK (или exclude-filter из config.yaml) -> слова: режем по |,
  // срезаем пробелы и префикс "(?i)" (в BLOCK он не нужен и ломал поиск).
  function geoSplit(s) {
    return String(s || '').split('|').map(function (t) {
      return t.trim().replace(/^\(\?i\)/, '').trim();
    }).filter(function (t) { return t !== ''; });
  }

  // Текст поля "Свои слова": по слову на строку (| внутри строки тоже делит).
  function geoCustomList(text) {
    return geoSplit(String(text || '').replace(/\r?\n/g, '|'));
  }

  // Страна отмечена, если в строке есть её флаг; все её слова уходят из
  // "своих", остальные слова остаются как есть.
  function geoParse(s) {
    var tokens = geoSplit(s);
    var have = {}, sel = {}, used = {};
    tokens.forEach(function (t) { have[geoLc(t)] = true; });
    GEO_CATALOG.forEach(function (c) {
      if (have[geoLc(c.flag)]) {
        sel[c.code] = true;
        c.words.forEach(function (w) { used[geoLc(w)] = true; });
      }
    });
    return {
      sel: sel,
      custom: tokens.filter(function (t) { return !used[geoLc(t)]; }),
      hadRegex: /(^|\|)\s*\(\?i\)/.test(String(s || ''))
    };
  }

  // Слова отмеченных стран (в порядке каталога), затем свои; дубликаты
  // без учёта регистра убираются.
  function geoBuild(sel, customList) {
    var seen = {}, out = [];
    function add(t) {
      var k = geoLc(t);
      if (k && !seen[k]) { seen[k] = true; out.push(t); }
    }
    GEO_CATALOG.forEach(function (c) { if (sel[c.code]) { c.words.forEach(add); } });
    customList.forEach(add);
    return out;
  }

  // Замечания к фильтру. kind: 'err' - сервер не примет, 'important' -
  // Россия не выбрана, 'warn' - слово, скорее всего, работает не так,
  // как задумано, 'info' - к сведению. Сохранять мешает только 'err'.
  function geoWarnings(sel, customList, hadRegex) {
    var out = [], owner = {};
    GEO_CATALOG.forEach(function (c) {
      c.words.forEach(function (w) { if (!owner[geoLc(w)]) { owner[geoLc(w)] = c; } });
    });
    if (geoBuild(sel, customList).length === 0) {
      out.push({ kind: 'err', text: 'Фильтр пуст - сохранить нельзя.' });
    }
    if (!sel.RU) {
      out.push({ kind: 'important', text: 'Россия не выбрана - российская нода может выиграть замер по пингу.' });
    }
    customList.forEach(function (t) {
      if (/[\\^$*+?()[\]{}]/.test(t)) {
        out.push({ kind: 'warn', text: '«' + t + '» похоже на регулярное выражение. Символы ищутся буквально, так что правило, скорее всего, не сработает.' });
      } else if (/^[A-Za-z]{1,3}$/.test(t)) {
        var isRu = geoLc(t) === 'ru';
        out.push({ kind: 'warn', text: '«' + t + '» слишком короткое: совпадёт и там, где эти буквы стоят внутри слова' +
          (isRu ? ' (Brussels, Peru, Truckee).' + (sel.RU ? ' Для России уже есть RU- и RU_.' : '') : '.') });
      }
      var o = owner[geoLc(t)];
      if (o && sel[o.code]) {
        out.push({ kind: 'info', text: '«' + t + '» уже входит в страну «' + o.ru + '» - строку можно удалить.' });
      }
    });
    if (hadRegex) {
      out.push({ kind: 'info', text: 'Префикс (?i) убран: здесь это не регулярное выражение, регистр и так не важен, а с префиксом первое слово не находилось.' });
    }
    return out;
  }
  // GEO-LOGIC-END

  var GEO_WARN_TAGS = { err: 'ОШИБКА', important: 'ВАЖНО', warn: 'ВНИМАНИЕ', info: 'ИНФО' };

  // Карточка формы настроек. Готовую строку кладёт в скрытое поле
  // geo_filter - API /api/settings и серверная валидация не меняются.
  function buildGeoFilterCard(saved, candidates) {
    var c = card('Какие ноды не проверять');
    c.appendChild(el('p', 'hint', 'Спидтест пропускает ноду, если в её имени есть любое из слов ниже. Регистр не важен. ' +
      'Обязательно исключите Россию - иначе российская нода может выиграть замер по пингу. ' +
      'На основное ядро (config.yaml) эта настройка не влияет.'));

    var hidden = el('input');
    hidden.type = 'hidden';
    hidden.name = 'geo_filter';
    hidden.id = 'geo_filter';
    c.appendChild(hidden);

    var savedSet = {};
    geoSplit(saved).forEach(function (t) { savedSet[geoLc(t)] = true; });
    var st = { sel: {}, loadedRegex: false };
    var boxes = {};

    // --- кнопки "Заполнить из config.yaml" / "Вернуть сохранённое" ---
    var tools = el('div', 'geo-tools');
    var candSelect = null;
    candidates = candidates || [];
    if (candidates.length) {
      if (candidates.length > 1) {
        candSelect = el('select');
        candSelect.setAttribute('aria-label', 'Вариант exclude-filter из config.yaml');
        candidates.forEach(function (cand, i) {
          var o = el('option', null, 'Вариант ' + (i + 1) + ': ' + (cand.length > 60 ? cand.slice(0, 60) + '…' : cand));
          o.value = String(i);
          candSelect.appendChild(o);
        });
        tools.appendChild(candSelect);
      }
      var fillBtn = el('button', 'small', 'Заполнить из config.yaml');
      fillBtn.type = 'button';
      fillBtn.addEventListener('click', function () {
        var cand = candidates[candSelect ? Number(candSelect.value) : 0];
        load(cand, 'Форма заполнена из exclude-filter в config.yaml. Проверьте итог и сохраните.');
      });
      tools.appendChild(fillBtn);
    }
    var resetBtn = el('button', 'small muted', 'Вернуть сохранённое');
    resetBtn.type = 'button';
    resetBtn.addEventListener('click', function () { load(saved, 'Возвращено сохранённое значение.'); });
    tools.appendChild(resetBtn);
    c.appendChild(tools);

    var flash = el('p', 'msg-ok geo-flash');
    flash.hidden = true;
    c.appendChild(flash);

    // --- страны ---
    var searchLabel = el('label', null, 'Страны');
    searchLabel.setAttribute('for', 'geo_search');
    c.appendChild(searchLabel);
    var search = el('input', 'geo-search');
    search.type = 'text';
    search.id = 'geo_search';
    search.placeholder = 'Найти страну: Россия, Japan…';
    search.autocomplete = 'off';
    c.appendChild(search);

    function group(title, list) {
      var head = el('div', 'geo-group-title');
      var grid = el('div', 'geo-grid');
      list.forEach(function (country) {
        var lab = el('label', 'geo-country');
        var cb = el('input');
        cb.type = 'checkbox';
        cb.addEventListener('change', function () {
          if (cb.checked) { st.sel[country.code] = true; } else { delete st.sel[country.code]; }
          flash.hidden = true;
          update();
        });
        lab.appendChild(cb);
        lab.appendChild(el('span', 'geo-flag', country.flag));
        lab.appendChild(el('span', 'geo-name', country.ru));
        lab.appendChild(el('span', 'geo-code', country.code));
        grid.appendChild(lab);
        boxes[country.code] = { cb: cb, label: lab, country: country };
      });
      c.appendChild(head);
      c.appendChild(grid);
      return { title: title, head: head, grid: grid, list: list };
    }
    var groups = [
      group('Обычно исключают', GEO_CATALOG.filter(function (x) { return x.common; })),
      group('Другие страны', GEO_CATALOG.filter(function (x) { return !x.common; }))
    ];
    var noMatch = el('p', 'hint', 'Страна не найдена в списке - её можно добавить словом в поле ниже.');
    noMatch.hidden = true;
    c.appendChild(noMatch);

    search.addEventListener('input', function () {
      var q = geoLc(search.value.trim());
      var shown = 0;
      groups.forEach(function (g) {
        var inGroup = 0;
        g.list.forEach(function (country) {
          var hit = !q || geoLc(country.code).indexOf(q) >= 0 ||
            country.words.some(function (w) { return geoLc(w).indexOf(q) >= 0; });
          boxes[country.code].label.hidden = !hit;
          if (hit) { inGroup++; }
        });
        g.head.hidden = g.grid.hidden = inGroup === 0;
        shown += inGroup;
      });
      noMatch.hidden = shown > 0;
    });

    // --- свои слова и замечания ---
    var cols = el('div', 'geo-cols');
    var left = el('div');
    var taLabel = el('label', null, 'Свои слова - по одному на строку');
    taLabel.setAttribute('for', 'geo_custom');
    left.appendChild(taLabel);
    var customTa = el('textarea');
    customTa.id = 'geo_custom';
    customTa.rows = 7;
    customTa.addEventListener('input', function () { flash.hidden = true; update(); });
    left.appendChild(customTa);
    left.appendChild(el('p', 'hint', 'Например: whitelist, Обход, RU- . Слово ищется как есть, без регулярных выражений.'));
    var right = el('div');
    right.appendChild(el('label', null, 'Проверка'));
    var warnBox = el('div');
    right.appendChild(warnBox);
    cols.appendChild(left);
    cols.appendChild(right);
    c.appendChild(cols);

    // --- итог ---
    var summary = el('div', 'geo-summary');
    var countLine = el('div');
    summary.appendChild(countLine);
    var chips = el('div', 'geo-chips');
    summary.appendChild(chips);
    var removedLine = el('div', 'geo-chips');
    summary.appendChild(removedLine);
    summary.appendChild(el('p', 'hint', '+ и пунктир - слово добавится, зачёркнутое - исчезнет по сравнению с сохранённым.'));
    var details = el('details');
    details.appendChild(el('summary', null, 'Строка BLOCK, которая запишется в speedtest2.env'));
    var pre = el('pre');
    details.appendChild(pre);
    summary.appendChild(details);
    c.appendChild(summary);

    function update() {
      var custom = geoCustomList(customTa.value);
      var tokens = geoBuild(st.sel, custom);
      hidden.value = tokens.join('|');

      Object.keys(boxes).forEach(function (code) {
        var b = boxes[code];
        b.cb.checked = !!st.sel[code];
        b.label.classList.toggle('on', !!st.sel[code]);
      });
      groups.forEach(function (g) {
        var n = g.list.filter(function (x) { return st.sel[x.code]; }).length;
        g.head.textContent = g.title + ' · выбрано ' + n + ' из ' + g.list.length;
      });

      while (warnBox.firstChild) { warnBox.removeChild(warnBox.firstChild); }
      var hadRegex = st.loadedRegex || /\(\?i\)/.test(customTa.value);
      var warns = geoWarnings(st.sel, custom, hadRegex);
      if (!warns.length) { warnBox.appendChild(el('p', 'geo-warn', 'Замечаний нет.')); }
      warns.forEach(function (w) {
        var row = el('div', 'geo-warn ' + w.kind);
        row.appendChild(el('span', 'geo-warn-tag', GEO_WARN_TAGS[w.kind]));
        row.appendChild(el('span', null, w.text));
        warnBox.appendChild(row);
      });

      countLine.textContent = 'Будут пропущены ноды, в имени которых есть (слов: ' + tokens.length + '):';
      while (chips.firstChild) { chips.removeChild(chips.firstChild); }
      var nowSet = {};
      tokens.forEach(function (t) {
        nowSet[geoLc(t)] = true;
        var isNew = !savedSet[geoLc(t)];
        chips.appendChild(el('span', 'geo-chip' + (isNew ? ' new' : ''), (isNew ? '+ ' : '') + t));
      });
      while (removedLine.firstChild) { removedLine.removeChild(removedLine.firstChild); }
      var removed = geoSplit(saved).filter(function (t) { return !nowSet[geoLc(t)]; });
      removedLine.hidden = removed.length === 0;
      if (removed.length) {
        removedLine.appendChild(el('span', 'hint', 'Исчезнут:'));
        removed.forEach(function (t) { removedLine.appendChild(el('span', 'geo-chip removed', t)); });
      }
      pre.textContent = "BLOCK='" + hidden.value + "'";
    }

    function load(value, msg) {
      var p = geoParse(value);
      st.sel = p.sel;
      st.loadedRegex = p.hadRegex;
      customTa.value = p.custom.join('\n');
      flash.textContent = msg || '';
      flash.hidden = !msg;
      update();
    }

    load(saved, null);
    return c;
  }

  // ----- раздел "Настройки" (/api/settings) -----

  // Описание полей формы - в том же порядке и с теми же подписями/
  // подсказками/диапазонами, что и в прежней HTML-форме stats_cgi.sh, -
  // группировка по карточкам ниже повторяет прежнюю разбивку.
  var FIELD_DEFS = {
    max_tested: { label: 'Максимум кандидатов на скоростной тест', type: 'number', min: 0, hint: 'Берём первые живые ноды по возрастанию технического времени ответа второго ядра. 0 = без ограничения.' },
    extype: { label: 'Исключить типы нод целиком (через |)', type: 'text', placeholder: 'например trojan|ss', hint: 'Пусто = тестировать все типы, которые понимает mihomo.' },
    size_mb: { label: 'Размер файла для замера, МБ', type: 'number', min: 1, max: 100, step: 'any', hint: 'Меньше 10 МБ занижает результат - треть времени уходит на TTFB.' },
    dl_timeout: { label: 'Таймаут закачки, сек', type: 'number', min: 1, max: 120 },
    min_speed_mb: { label: 'Порог отбора (для текущего канала), Мбит/с', type: 'number', min: 0.1, max: 10000, step: 'any', hint: 'Пересчитывается install.sh при переустановке от прямого замера канала - здесь можно поправить вручную.' },
    min_ratio: { label: 'Динамический порог, доля от прямого канала', type: 'number', min: 0.01, max: 1, step: 'any' },
    min_floor_mb: { label: 'Абсолютный минимум порога, Мбит/с (0 = без минимума)', type: 'number', min: 0, step: 'any' },
    topn: { label: 'Сколько нод класть в fast.yaml (TOPN)', type: 'number', min: 1, max: 50 },
    enough: { label: 'Хватит нод выше порога - дальше не мерить', type: 'number', min: 1, max: 100 },
    min_winners: { label: 'Минимум нод в fast.yaml, даже ниже порога', type: 'number', min: 0, max: 50, hint: 'Если рабочих нод меньше TOPN - добор идёт по убыванию скорости, пока не наберётся этот минимум.' },
    stability_window: { label: 'Длина окна "недавних" прогонов', type: 'number', min: 1, max: 5000, hint: 'В прогонах, не в днях - 200 при прогоне раз в 3 часа - это около месяца.' },
    stability_drop_after: { label: 'Удалять ноду после стольких прогонов подряд без неё в пуле (0 = не удалять)', type: 'number', min: 0 },
    node_cap: { label: 'Число нод на графике (1-8)', type: 'number', min: 1, max: 8, hint: 'Больше 8 не поддерживается - столько цветов в палитре легенды.' },
    keep_runs: { label: 'Хранить прогонов (0 = не ограничивать)', type: 'number', min: 0 },
    keep_days: { label: 'Хранить дней (0 = не ограничивать)', type: 'number', min: 0, hint: 'Нельзя занулить оба сразу.' }
  };

  var CARDS = [
    { geo: true }, // своя карточка - buildGeoFilterCard()
    { title: 'Как тестируем ноды', fields: ['extype', 'max_tested', 'size_mb', 'dl_timeout'] },
    { title: 'Порог и число нод в fast.yaml', fields: ['min_speed_mb', 'min_ratio', 'min_floor_mb', 'topn', 'enough', 'min_winners'] },
    { title: 'Стабильность нод', fields: ['stability_window', 'stability_drop_after'] },
    { title: 'График по нодам', fields: ['node_cap'] },
    { title: 'Хранение истории', fields: ['keep_runs', 'keep_days'] }
  ];

  function buildField(name, value) {
    var def = FIELD_DEFS[name];
    var wrap = document.createDocumentFragment();
    var label = el('label', null, def.label);
    label.setAttribute('for', name);
    wrap.appendChild(label);
    var input = el('input');
    input.type = def.type;
    input.id = name;
    input.name = name;
    if (def.type === 'number') {
      if (def.min !== undefined) { input.min = def.min; }
      if (def.max !== undefined) { input.max = def.max; }
      if (def.step !== undefined) { input.step = def.step; }
    }
    if (def.placeholder) { input.placeholder = def.placeholder; }
    input.value = value === undefined || value === null ? '' : value;
    wrap.appendChild(input);
    if (def.hint) { wrap.appendChild(el('p', 'hint', def.hint)); }
    return wrap;
  }

  function showFormMessage(form, text, kind) {
    var old = form.querySelector('.form-msg');
    if (old) { old.parentNode.removeChild(old); }
    if (!text) { return; }
    var p = el('p', (kind === 'ok' ? 'msg-ok' : 'msg-err') + ' form-msg', text);
    form.insertBefore(p, form.firstChild);
  }

  function buildSettingsForm(values) {
    var form = document.createElement('form');

    CARDS.forEach(function (cardDef) {
      if (cardDef.geo) {
        form.appendChild(buildGeoFilterCard(values.geo_filter || '', values.geo_filter_candidates));
        return;
      }
      var c = card(cardDef.title);
      cardDef.fields.forEach(function (name) {
        c.appendChild(buildField(name, values[name]));
      });
      form.appendChild(c);
    });

    var btnRow = el('div', 'btn-row');
    var saveBtn = el('button', 'submit', 'Сохранить');
    saveBtn.type = 'submit';
    var saveRunBtn = el('button', 'submit secondary', 'Сохранить и запустить');
    saveRunBtn.type = 'submit';
    btnRow.appendChild(saveBtn);
    btnRow.appendChild(saveRunBtn);
    form.appendChild(btnRow);

    // Какая кнопка нажата - запоминаем по клику (событие click срабатывает
    // раньше submit), чтобы после успешного сохранения решить, звать ли
    // ещё и /api/run (кнопка "Сохранить и запустить").
    var runAfterSave = false;
    saveBtn.addEventListener('click', function () { runAfterSave = false; });
    saveRunBtn.addEventListener('click', function () { runAfterSave = true; });

    function setFormButtonsDisabled(disabled) {
      saveBtn.disabled = disabled;
      saveRunBtn.disabled = disabled;
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var shouldRun = runAfterSave;
      setFormButtonsDisabled(true);
      showFormMessage(form, null);
      var body = new URLSearchParams(new FormData(form));
      fetchJson('/api/settings', { method: 'POST', body: body }).then(function (resp) {
        if (!resp.ok) {
          var texts = [];
          var errs = resp.errors || {};
          Object.keys(errs).forEach(function (key) {
            texts.push(errs[key]);
            var badInput = form.querySelector('[name="' + key + '"]');
            if (badInput) { badInput.classList.add('input-err'); }
          });
          showFormMessage(form, texts.join(' '), 'err');
          setFormButtonsDisabled(false);
          return;
        }
        if (!shouldRun) {
          renderSettings('Настройки сохранены.');
          return;
        }
        return fetchJson('/api/run', { method: 'POST' }).then(function (d) {
          var msg = d.started ? 'Настройки сохранены, прогон запущен.' : 'Настройки сохранены, прогон уже шёл - новый не запускался.';
          renderSettings(msg);
        })['catch'](function (err) {
          renderSettings('Настройки сохранены, но не удалось запустить прогон: ' + err.message);
        });
      })['catch'](function (err) {
        showFormMessage(form, 'Не удалось сохранить: ' + err.message, 'err');
        setFormButtonsDisabled(false);
      });
    });

    return form;
  }

  function renderSettings(justSavedMsg) {
    setLoading();
    fetchJson('/api/settings').then(function (data) {
      clearApp();
      var values = data.values || {};
      var form = buildSettingsForm(values);
      app.appendChild(form);
      if (justSavedMsg) { showFormMessage(form, justSavedMsg, 'ok'); }
    })['catch'](function (err) {
      if (err.message === 'not_implemented') {
        showNotYetMoved('Форма настройки ещё переезжает на новый интерфейс.');
        return;
      }
      showError('Не удалось загрузить настройки: ', err);
    });
  }

  // ----- раздел "Обновления" (/api/updates/*) -----

  function updatesBadgeEl() { return document.getElementById('updatesBadge'); }

  function refreshUpdatesBadge() {
    fetchJson('/api/updates/status').then(function (data) {
      var lc = data && data.last_check;
      // 'missing' - тоже "есть что поставить": релиз, добавляющий только
      // новые файлы (без единого изменённого), иначе не показал бы бейдж/
      // кнопку "Обновить" вовсе (баг, найденный при редизайне раздела).
      var available = !!(lc && lc.ok && lc.plan && lc.plan.files &&
        lc.plan.files.some(function (f) {
          return f.state === 'new' || f.state === 'modified' || f.state === 'changed' || f.state === 'missing';
        }));
      var badge = updatesBadgeEl();
      if (badge) { badge.hidden = !available; }
      // KPI-плитка "ОБНОВЛЕНИЕ" на /stats (buildKpiRow) - тот же расчёт
      // available, что и у бейджа выше, без второго независимого правила
      // (см. комментарий про 'missing' - тот баг уже случился один раз
      // из-за двух копий одной и той же проверки).
      var kpiTile = document.getElementById('kpiUpdateTile');
      if (kpiTile) {
        kpiTile.classList.toggle('kpi-danger', available);
        var kpiValue = document.getElementById('kpiUpdateTileValue');
        if (kpiValue) { kpiValue.textContent = available ? 'ЕСТЬ ОБНОВЛЕНИЕ' : 'АКТУАЛЬНО'; }
      }
    })['catch'](function () { /* бейдж/плитка - необязательная подсказка, сетевая ошибка не должна ломать страницу */ });
  }

  var UPDATE_JOB_POLL_MS = 2000;
  var updateJobPollTimer = null;

  function stopUpdateJobPolling() {
    if (updateJobPollTimer) { clearInterval(updateJobPollTimer); updateJobPollTimer = null; }
  }

  // onUpdate получает целиком ответ /api/updates/status (а не только
  // data.job) - мини консоли (renderUpdatesProgress) на каждый тик нужен
  // ещё и data.log, второй отдельный fetch на то же самое был бы лишним.
  function startUpdateJobPolling(onUpdate) {
    stopUpdateJobPolling();
    function tick() {
      fetchJson('/api/updates/status').then(function (data) {
        onUpdate(data || {});
      })['catch'](function () { /* временная заминка - опрос продолжится следующим тиком */ });
    }
    tick();
    updateJobPollTimer = setInterval(tick, UPDATE_JOB_POLL_MS);
  }

  // Мини консоль хода обновления (задача веб-редизайна раздела /updates,
  // п.3: "видны все этапы и ошибки"). Рендерим построчно (а не одним
  // textContent) - строки "ERROR:"/"WARN:" получают свой класс для
  // подсветки; пустая последняя "строка" (хвостовой перевод строки файла)
  // не рисуется отдельной пустой строкой.
  function renderConsoleLog(pre, text) {
    while (pre.firstChild) { pre.removeChild(pre.firstChild); }
    var lines = String(text || '').split('\n');
    lines.forEach(function (line, i) {
      if (line === '' && i === lines.length - 1) { return; }
      var isErr = line.indexOf('ERROR:') === 0 || line.indexOf('WARN:') === 0;
      pre.appendChild(el('div', 'log-line' + (isErr ? ' err' : ''), line === '' ? ' ' : line));
    });
    pre.scrollTop = pre.scrollHeight;
  }

  // Запускает apply для уже подготовленного плана - как в обычном пути
  // (план не требует подтверждения, автоматически продолжаем сразу после
  // prepare, п.2: "пользователь нажал обновить и операция началась"), так
  // и в принудительном повторе после блокирующего сообщения о локальных
  // изменениях/миграции конфига (см. handlePrepareDone ниже).
  function startApply(planId, confirmLocal, confirmConfig, container) {
    var body = new URLSearchParams();
    body.set('plan_id', planId);
    if (confirmLocal) { body.set('confirm_local', '1'); }
    if (confirmConfig) { body.set('confirm_config', '1'); }
    fetchJson('/api/updates/apply', { method: 'POST', body: body }).then(function (resp) {
      if (!resp.started) { showFormMessage(container, 'Уже выполняется другая операция обновления.', 'err'); return; }
      renderUpdatesProgress('apply');
    })['catch'](function (err) { showFormMessage(container, 'Не удалось запустить обновление: ' + err.message, 'err'); });
  }

  // По завершении prepare: если план не требует подтверждения - обновление
  // продолжается само (без отдельного экрана подтверждения, п.2 задачи
  // редизайна). Если есть локальные изменения и/или требуется миграция
  // config.yaml - операция останавливается, сообщение уходит в консоль, и
  // единственный путь вперёд - кнопка "Обновить принудительно" (решение,
  // согласованное с пользователем при обсуждении дизайна).
  function handlePrepareDone(job, container) {
    var plan = job.plan;
    var needsLocal = !!(plan && plan.overwrite_required);
    var needsConfig = !!(job.config_diff !== null && plan && plan.config_migration && plan.config_migration.confirmation_required);
    if (!needsLocal && !needsConfig) {
      startApply(job.plan_id, 0, 0, container);
      return;
    }
    var reasons = [];
    if (needsLocal) { reasons.push('есть локально изменённые файлы - они будут перезаписаны'); }
    if (needsConfig) { reasons.push('миграция config.yaml требует отдельного подтверждения'); }
    showFormMessage(container, 'Обновление остановлено: ' + reasons.join('; ') + '.', 'err');
    var forceBtn = el('button', 'submit', 'Обновить принудительно');
    forceBtn.type = 'button';
    forceBtn.addEventListener('click', function () {
      forceBtn.disabled = true;
      startApply(job.plan_id, needsLocal ? 1 : 0, needsConfig ? 1 : 0, container);
    });
    container.appendChild(forceBtn);
  }

  function renderUpdatesProgress(action) {
    clearApp();
    var c = card(action === 'prepare' ? 'Подготовка обновления' : 'Применение обновления');
    var status = el('p', 'hint', 'Выполняется...');
    c.appendChild(status);
    var consolePre = el('pre', 'update-console');
    c.appendChild(consolePre);
    app.appendChild(c);
    startUpdateJobPolling(function (data) {
      renderConsoleLog(consolePre, data.log);
      var job = data.job;
      if (!job || job.action !== action) { return; }
      if (job.state === 'queued' || job.state === 'running') { return; }
      stopUpdateJobPolling();
      if (job.state === 'error') {
        status.className = 'msg-err'; status.textContent = 'Ошибка: ' + (job.error || 'неизвестная ошибка');
        return;
      }
      if (action === 'prepare') {
        status.className = 'msg-ok'; status.textContent = 'Подготовка завершена.';
        handlePrepareDone(job, c);
        return;
      }
      status.className = 'msg-ok'; status.textContent = 'Обновление применено.';
      // Пункт фидбека по макету: last_check.plan к этому моменту ещё
      // относится к состоянию ДО применения обновления, поэтому просто
      // refreshUpdatesBadge() продолжил бы показывать бейдж как "есть
      // обновление" до тех пор, пока пользователь не нажмёт "Проверить
      // сейчас" вручную. Перепроверяем сами - тем же запросом, что и
      // кнопка "Проверить сейчас" - и только потом обновляем бейдж/плитку.
      fetchJson('/api/updates/check', { method: 'POST' }).then(function () { refreshUpdatesBadge(); })
        ['catch'](function () { refreshUpdatesBadge(); });
    });
  }

  // ----- вкладка «Журнал» (/log): живой журнал speedtest2.sh и службы -----
  // Пока вкладка открыта, раз в LOG_POLL_MS опрашиваем /api/log (см.
  // live_log_poll() в stats_httpd.py): сам опрос и включает сбор строк в
  // /tmp, без опроса сервер через ~30 с прекращает сбор и удаляет файл.
  // gen/offset - с какого места дочитывать; при обрыве связи опрос просто
  // повторяется с тем же местом, а при смене поколения (обрезка журнала,
  // перезапуск сервера, долгий перерыв) сервер отвечает reset, и вывод
  // перерисовывается с затравки. Строки выводятся только через textContent
  // (el()), без innerHTML - содержимое журнала в браузере не исполняется.
  var LOG_POLL_MS = 2000;
  var LOG_RETRY_MS = 5000;
  var LOG_MAX_LINES = 2000;
  var logPollTimer = null;
  var logView = null;

  function stopLogPolling() {
    if (logPollTimer) { clearTimeout(logPollTimer); logPollTimer = null; }
    logView = null;
  }

  function logLineClass(line) {
    if (line.indexOf('--- ') === 0) { return 'log-line sep'; }
    if (/ERROR|WARN|FAIL|ошибк/i.test(line)) { return 'log-line err'; }
    return 'log-line';
  }

  function appendLogText(view, text) {
    if (!text) { return; }
    var lines = String(text).split('\n');
    if (lines[lines.length - 1] === '') { lines.pop(); }
    lines.forEach(function (line) {
      view.pre.appendChild(el('div', logLineClass(line), line === '' ? ' ' : line));
    });
    while (view.pre.childNodes.length > LOG_MAX_LINES) { view.pre.removeChild(view.pre.firstChild); }
  }

  function scheduleLogPoll(view, delay) {
    if (logView !== view) { return; }
    logPollTimer = setTimeout(function () { logPollTick(view); }, delay);
  }

  function logPollTick(view) {
    logPollTimer = null;
    if (logView !== view) { return; }
    var url = '/api/log?gen=' + encodeURIComponent(view.gen) + '&offset=' + view.offset;
    fetchJson(url).then(function (data) {
      if (logView !== view) { return; }
      var atBottom = view.pre.scrollHeight - view.pre.scrollTop - view.pre.clientHeight < 24;
      if (data.reset) {
        while (view.pre.firstChild) { view.pre.removeChild(view.pre.firstChild); }
        appendLogText(view, data.seed);
      }
      appendLogText(view, data.text);
      view.gen = data.gen || '';
      view.offset = typeof data.offset === 'number' ? data.offset : 0;
      view.status.textContent = 'Журнал обновляется, пока открыта эта вкладка.';
      view.status.className = 'hint';
      if (view.autoScroll.checked && (atBottom || data.reset)) { view.pre.scrollTop = view.pre.scrollHeight; }
      scheduleLogPoll(view, data.more ? 0 : LOG_POLL_MS);
    })['catch'](function (err) {
      if (logView !== view) { return; }
      view.status.textContent = 'Нет связи с роутером (' + err.message + '), повтор через ' + (LOG_RETRY_MS / 1000) + ' с...';
      view.status.className = 'hint msg-err';
      scheduleLogPoll(view, LOG_RETRY_MS);
    });
  }

  function renderLog() {
    stopLogPolling();
    clearApp();
    var c = card('Журнал');
    var status = el('p', 'hint', 'Подключение...');
    c.appendChild(status);
    var row = el('div', 'row-checkbox');
    var auto = el('input');
    auto.type = 'checkbox';
    auto.id = 'logAutoScroll';
    auto.checked = true;
    row.appendChild(auto);
    var autoLabel = el('label', null, 'Автопрокрутка');
    autoLabel.setAttribute('for', 'logAutoScroll');
    row.appendChild(autoLabel);
    c.appendChild(row);
    var pre = el('div', 'update-console live-log');
    pre.setAttribute('role', 'log');
    pre.setAttribute('aria-live', 'polite');
    c.appendChild(pre);
    app.appendChild(c);
    var view = { gen: '', offset: 0, pre: pre, status: status, autoScroll: auto };
    logView = view;
    logPollTick(view);
  }

  function renderUpdates() {
    stopProgressPolling();
    stopUpdateJobPolling();
    stopLogPolling();
    setLoading();
    fetchJson('/api/updates/status').then(function (data) {
      clearApp();
      var lc = data.last_check;
      var job = data.job;
      if (job && (job.state === 'queued' || job.state === 'running')) {
        renderUpdatesProgress(job.action);
        return;
      }
      // 'missing' - см. комментарий у refreshUpdatesBadge() выше.
      var available = !!(lc && lc.ok && lc.plan && lc.plan.files &&
        lc.plan.files.some(function (f) {
          return f.state === 'new' || f.state === 'modified' || f.state === 'changed' || f.state === 'missing';
        }));
      // Одна карточка сверху с обеими кнопками рядом (п.1 задачи редизайна:
      // "кнопка обновить должна быть вверху, там же где и проверка
      // обновлений") вместо прежних двух отдельных карточек.
      var summary = card('Обновления');
      if (lc && lc.ok) {
        // Одна короткая фраза по available (та же проверка, что показывает
        // кнопку "Обновить"): либо доступна новая версия N, либо N уже
        // установлена. Прежний двойной текст (версия релиза + отдельная
        // пометка статуса) владелец счёл избыточным.
        var versionMsg = 'Последняя проверка: ' + lc.checked_at + '. ' +
          (available ? 'Доступна новая версия: ' : 'Установлена актуальная версия: ') +
          lc.plan.release_version + '.';
        summary.appendChild(el('p', 'hint', versionMsg));
      } else if (lc) {
        summary.appendChild(el('p', 'msg-err', 'Последняя проверка не удалась: ' + (lc.error || '')));
      } else {
        summary.appendChild(el('p', 'hint', 'Проверок ещё не было.'));
      }
      var row = el('div', 'btn-row');
      var checkBtn = el('button', 'submit', 'Проверить сейчас');
      checkBtn.type = 'button';
      var updateBtn = el('button', 'submit', 'Обновить');
      updateBtn.type = 'button';
      // "Обновить" показывается только когда есть обновление (available);
      // при актуальной версии и после неудачной проверки кнопки нет вовсе.
      checkBtn.addEventListener('click', function () {
        checkBtn.disabled = true; updateBtn.disabled = true;
        fetchJson('/api/updates/check', { method: 'POST' }).then(function () { renderUpdates(); refreshUpdatesBadge(); })
          ['catch'](function (err) {
            showFormMessage(summary, 'Не удалось проверить: ' + err.message, 'err');
            checkBtn.disabled = false; updateBtn.disabled = false;
          });
      });
      updateBtn.addEventListener('click', function () {
        // Клик "Обновить" сразу запускает операцию, без отдельного экрана
        // подтверждения (п.2 задачи редизайна) - подготовка (prepare)
        // сама переходит в применение (apply), если план не требует
        // подтверждения (см. handlePrepareDone).
        checkBtn.disabled = true; updateBtn.disabled = true;
        fetchJson('/api/updates/prepare', { method: 'POST' }).then(function (resp) {
          if (!resp.started) {
            showFormMessage(summary, 'Уже выполняется другая операция обновления.', 'err');
            checkBtn.disabled = false; updateBtn.disabled = false;
            return;
          }
          renderUpdatesProgress('prepare');
        })['catch'](function (err) {
          showFormMessage(summary, 'Не удалось начать подготовку: ' + err.message, 'err');
          checkBtn.disabled = false; updateBtn.disabled = false;
        });
      });
      row.appendChild(checkBtn); if (available) { row.appendChild(updateBtn); }
      summary.appendChild(row);
      app.appendChild(summary);
      // Вместо полного списка файлов - текст релиза(ов) "что нового" (п.4
      // задачи редизайна). lc.notes заполняется cmd_check() на backend -
      // один элемент на каждый пропущенный релиз, от старого к новому.
      if (lc && lc.ok && lc.notes && lc.notes.length) {
        var notesCard = card('Что нового');
        lc.notes.forEach(function (n) {
          notesCard.appendChild(el('h2', null, 'Релиз ' + n.tag));
          notesCard.appendChild(el('pre', 'release-notes', n.body || '(описание не указано)'));
        });
        app.appendChild(notesCard);
      }
    })['catch'](function (err) { showError('Не удалось загрузить раздел обновлений: ', err); });
  }

  function render(path) {
    stopProgressPolling();
    stopUpdateJobPolling();
    stopLogPolling();
    if (path === '/updates') { renderUpdates(); }
    else if (path === '/settings') { renderSettings(); }
    else if (path === '/log') { renderLog(); }
    else { renderStats(); }
    if (path !== '/updates') { refreshUpdatesBadge(); }
  }

  // ----- футер (артборд "Панель управления": версия/аптайм/CPU/MEM/mihomo,
  // см. /api/system и CHANGELOG) -----

  function sysFooterEls() {
    return {
      el: document.getElementById('sysFooter'),
      left: document.getElementById('sysFooterLeft'),
      right: document.getElementById('sysFooterRight')
    };
  }

  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  function fmtUptime(sec) {
    if (sec === null || sec === undefined) { return '-'; }
    var d = Math.floor(sec / 86400);
    var h = Math.floor((sec % 86400) / 3600);
    var m = Math.floor((sec % 3600) / 60);
    return d + 'D ' + pad2(h) + ':' + pad2(m);
  }

  function fmtPercent(v) { return (v === null || v === undefined) ? '-' : (v + '%'); }

  function refreshSystemFooter() {
    var els = sysFooterEls();
    if (!els.el) { return; }
    fetchJson('/api/system').then(function (data) {
      var fw = data.release_version ? ('FIRMWARE v' + data.release_version) : 'FIRMWARE -';
      els.left.textContent = fw + ' \u00b7 UPTIME ' + fmtUptime(data.uptime_seconds);
      var mihomo = data.mihomo_active === true ? 'активен'
        : (data.mihomo_active === false ? 'не активен' : 'статус неизвестен');
      els.right.textContent = 'CPU ' + fmtPercent(data.cpu_percent) + ' \u00b7 MEM ' +
        fmtPercent(data.mem_percent) + ' \u00b7 mihomo core ' + mihomo;
      els.el.hidden = false;
    })['catch'](function () { /* футер - необязательная подсказка, сетевая ошибка не должна ломать страницу */ });
  }

  var SYSTEM_FOOTER_POLL_MS = 30000;
  var systemFooterPollTimer = null;

  function startSystemFooterPolling() {
    if (systemFooterPollTimer) { return; }
    refreshSystemFooter();
    systemFooterPollTimer = setInterval(refreshSystemFooter, SYSTEM_FOOTER_POLL_MS);
  }

  function stopSystemFooterPolling() {
    if (systemFooterPollTimer) { clearInterval(systemFooterPollTimer); systemFooterPollTimer = null; }
    var footer = sysFooterEls().el;
    if (footer) { footer.hidden = true; }
  }

  function setAuthenticatedUi(authenticated) {
    mainNav.hidden = !authenticated;
    logoutBtn.hidden = !authenticated;
    if (authenticated) { startSystemFooterPolling(); } else { stopSystemFooterPolling(); }
  }

  function authInput(form, name, labelText, type, autocomplete) {
    var label = el('label', null, labelText);
    label.setAttribute('for', name);
    form.appendChild(label);
    var input = el('input');
    input.id = name;
    input.name = name;
    input.type = type || 'text';
    if (autocomplete) { input.autocomplete = autocomplete; }
    input.required = true;
    form.appendChild(input);
    return input;
  }

  function renderAuthForm(mode) {
    stopProgressPolling();
    stopUpdateJobPolling();
    stopLogPolling();
    setAuthenticatedUi(false);
    clearApp();
    var c = card(mode === 'setup' ? 'Первичная настройка' : 'Вход');
    var form = el('form', 'auth-form');
    if (mode === 'setup') {
      form.appendChild(el('p', 'hint', 'Введите одноразовый код из терминала роутера и создайте учётную запись.'));
      authInput(form, 'setup_code', 'Одноразовый код', 'text', 'one-time-code');
    }
    authInput(form, 'login_username', 'Логин', 'text', 'username');
    authInput(form, 'login_password', 'Пароль', 'password', mode === 'setup' ? 'new-password' : 'current-password');
    if (mode === 'setup') {
      authInput(form, 'login_password_confirm', 'Повторите пароль', 'password', 'new-password');
    }
    var submit = el('button', 'submit', mode === 'setup' ? 'Создать учётную запись' : 'Войти');
    submit.type = 'submit';
    form.appendChild(submit);
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      submit.disabled = true;
      showFormMessage(form, null);
      var payload = {
        username: form.elements.login_username.value,
        password: form.elements.login_password.value
      };
      if (mode === 'setup') {
        payload.code = form.elements.setup_code.value;
        payload.password_confirm = form.elements.login_password_confirm.value;
      }
      fetchJson('/api/auth/' + mode, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      }).then(function (data) {
        authState = data;
        setAuthenticatedUi(true);
        history.replaceState(null, '', '/stats');
        render('/stats');
        updateActiveNav('/stats');
      })['catch'](function (error) {
        var message = error.message === 'invalid_credentials' ? 'Неверный логин или пароль.' :
          error.message === 'invalid_setup' ? 'Неверный или устаревший одноразовый код.' :
          error.message === 'password_mismatch' ? 'Пароли не совпадают.' :
          error.message === 'rate_limited' ? 'Слишком много попыток. Повторите позже.' :
          'Не удалось выполнить запрос: ' + error.message;
        showFormMessage(form, message, 'err');
        submit.disabled = false;
      });
    });
    c.appendChild(form);
    app.appendChild(c);
  }

  function renderUninitialized() {
    stopProgressPolling();
    stopUpdateJobPolling();
    stopLogPolling();
    setAuthenticatedUi(false);
    clearApp();
    var c = card('Авторизация не настроена');
    c.appendChild(el('p', 'msg-err', 'Выполните stats_auth.sh reset в терминале роутера, затем откройте эту страницу снова.'));
    app.appendChild(c);
  }

  function loadAuth() {
    setLoading();
    return fetch('/api/auth/status', { credentials: 'same-origin' }).then(function (response) {
      return response.json()['catch'](function () { return { mode: 'uninitialized' }; });
    }).then(function (data) {
      if (data.mode === 'authenticated') {
        authState = data;
        setAuthenticatedUi(true);
        var path = location.pathname;
        if (path === '/login' || path === '/setup') {
          history.replaceState(null, '', '/stats');
          path = '/stats';
        }
        render(path);
        updateActiveNav(path);
      } else if (data.mode === 'setup') {
        authState = null;
        if (location.pathname !== '/setup') { history.replaceState(null, '', '/setup'); }
        renderAuthForm('setup');
      } else if (data.mode === 'login') {
        authState = null;
        if (location.pathname !== '/login') { history.replaceState(null, '', '/login'); }
        renderAuthForm('login');
      } else {
        authState = null;
        renderUninitialized();
      }
    })['catch'](function (error) {
      showError('Не удалось проверить авторизацию: ', error);
    });
  }

  logoutBtn.addEventListener('click', function () {
    logoutBtn.disabled = true;
    fetchJson('/api/auth/logout', { method: 'POST' }).then(function () {
      authState = null;
      history.replaceState(null, '', '/login');
      renderAuthForm('login');
    })['catch'](function (error) {
      if (error.status === 401) {
        authState = null;
        history.replaceState(null, '', '/login');
        renderAuthForm('login');
      } else {
        showError('Не удалось выйти: ', error);
      }
    }).then(function () { logoutBtn.disabled = false; });
  });

  loadAuth();
})();
