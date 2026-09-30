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
    // Несохранённые правки на вкладке "Конфиг" (configView ниже).
    if (configView && configView.dirty && path !== location.pathname &&
        !window.confirm('В редакторе конфига есть несохранённые изменения. Уйти со страницы?')) { return; }
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
          error.data = data;
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

  // Описание полей формы. label - подпись, hint - одна строка под полем,
  // help - подробная подсказка (появляется, если задержать курсор на поле,
  // или по кнопке «?» - для телефона и клавиатуры): пары [заголовок, текст].
  // Тексты должны совпадать с тем, что реально делают speedtest2.sh,
  // prep.awk, node_stats_update.awk и install.sh - меняя поведение там,
  // правьте подсказку здесь.
  var HELP_WHEN = ['Когда действует', 'Со следующего прогона (по расписанию раз в 3 часа или по кнопке «Сохранить и запустить»). Сам по себе этот параметр ничего не меняет и никакими другими настройками не перезаписывается.'];
  var FIELD_DEFS = {
    min_ratio: {
      label: 'Порог скорости: доля от скорости вашего канала', type: 'number', min: 0.01, max: 1, step: 'any',
      hint: '0.25 = нода должна выдать хотя бы 25% скорости интернета без прокси.',
      help: [
        ['Что это', 'Главная настройка отбора. Нода попадает в быстрый пул, только если её скорость не ниже порога. Порог не задаётся числом раз и навсегда - он пересчитывается в каждом прогоне от скорости вашего интернета.'],
        ['Как работает', 'В начале каждого прогона роутер качает тестовый файл напрямую, без прокси, и получает скорость канала. Порог = скорость канала × эта доля, но не ниже значения «Порог скорости: не ниже».'],
        ['Пример', 'Канал 100 Мбит/с, доля 0.25 → порог 25 Мбит/с. Вечером канал просел до 60 Мбит/с → порог сам станет 15 Мбит/с, и пул не опустеет из-за того, что провайдер медленнее.'],
        ['Как выбрать', 'Больше (0.4-0.5) - в пул попадут только самые быстрые ноды, но их может оказаться мало. Меньше (0.1-0.15) - пул шире, но в него попадут и средние ноды.'],
        ['Связи', 'Если замер канала не удался (нет интернета напрямую), вместо этой формулы берётся «Запасной порог» из раздела «Дополнительно». Команда mihomo-speedtest recalibrate и переустановка пересчитывают запасной порог по этой доле.'],
        HELP_WHEN
      ]
    },
    min_floor_mb: {
      label: 'Порог скорости: не ниже, Мбит/с', type: 'number', min: 0, step: 'any',
      hint: 'Нижняя граница для порога выше. 0 = без границы.',
      help: [
        ['Что это', 'Страховка для порога «доля от канала»: какой бы медленной ни оказалась прямая скорость в момент замера, порог не опустится ниже этого числа.'],
        ['Пример', 'Доля 0.25, этот параметр 4 Мбит/с. Ночью канал намерился всего 8 Мбит/с (кто-то качал торрент) → 8 × 0.25 = 2, но порог станет 4 Мбит/с, и совсем медленные ноды в пул не пройдут.'],
        ['Как выбрать', 'Минимальная скорость, при которой вам ещё комфортно (видео, звонки). 0 - порог всегда равен доле от канала.'],
        HELP_WHEN
      ]
    },
    topn: {
      label: 'Сколько нод держать в быстром пуле (максимум)', type: 'number', min: 1, max: 50,
      hint: 'Самые быстрые ноды выше порога попадают в fast.yaml.',
      help: [
        ['Что это', 'Сколько нод-победителей записывается в fast.yaml. Из них Mihomo собирает группу «⚡ Быстрый пул» и сам выбирает внутри неё ноду с лучшим пингом, раз в минуту.'],
        ['Как работает', 'Все проверенные ноды выше порога сортируются по скорости, первые N становятся пулом. Если нод выше порога меньше - пул будет меньше (см. «Минимум нод в быстром пуле»).'],
        ['Пример', 'Значение 15, выше порога оказалось 22 ноды → в пул попадут 15 самых быстрых. Оказалось 6 → в пул попадут 6.'],
        ['Как выбрать', 'Больше - группе есть из чего выбирать, если нода упадёт между прогонами. Меньше - в пуле только лучшие. 10-20 подходит большинству.'],
        ['Связи', 'Прогон перестаёт проверять ноды, как только найдено «Остановиться, когда найдено быстрых нод». Если это число меньше, чем здесь, пул никогда не заполнится полностью - держите его не меньше этого значения.'],
        HELP_WHEN
      ]
    },
    min_winners: {
      label: 'Минимум нод в быстром пуле', type: 'number', min: 0, max: 50,
      hint: 'Если быстрых нод мало - добираем самыми быстрыми из остальных. 0 = не добирать.',
      help: [
        ['Что это', 'Защита от пустого пула. Если нод выше порога набралось меньше этого числа, пул добирается самыми быстрыми из рабочих нод ниже порога.'],
        ['Пример', 'Значение 3, выше порога прошла только 1 нода → в пул попадут она и ещё 2 самые быстрые из остальных, даже если они медленнее порога. Ноды, которые вообще не скачали файл, не добираются никогда.'],
        ['Как выбрать', '2-3 обычно достаточно: пул из одной ноды перестаёт работать, как только она упадёт. 0 - в пул попадают только ноды выше порога, даже если это значит пустой пул (тогда остаётся прошлый fast.yaml).'],
        HELP_WHEN
      ]
    },
    max_tested: {
      label: 'Сколько нод проверять на скорость за прогон (максимум)', type: 'number', min: 0,
      hint: '0 = все доступные ноды. Меньше - прогон быстрее и тратит меньше трафика.',
      help: [
        ['Что это', 'Сначала все ноды подписок быстро проверяются на доступность. Из живых на скорость проверяются не больше этого числа - первые по времени ответа.'],
        ['Как работает', 'Ноды проверяются по очереди, по одной. На каждую уходит до «Максимум времени на одну ноду» и скачивается до «Объём скачивания на одну ноду».'],
        ['Пример', 'Значение 40, объём 10 МБ, время 15 сек: прогон скачает не больше 400 МБ и займёт не дольше 10 минут. При прогоне раз в 3 часа это до 3,2 ГБ трафика в сутки.'],
        ['Связи', 'Прогон может закончиться раньше - когда найдено «Остановиться, когда найдено быстрых нод». Этот параметр - верхняя граница на случай, когда быстрых нод мало.'],
        HELP_WHEN
      ]
    },
    enough: {
      label: 'Остановиться, когда найдено быстрых нод', type: 'number', min: 1, max: 100,
      hint: 'Экономит время и трафик: дальше не проверяем. Держите не меньше размера пула.',
      help: [
        ['Что это', 'Как только столько проверенных нод оказались выше порога, прогон перестаёт скачивать через остальные.'],
        ['Пример', 'Значение 20, размер пула 15: прогон найдёт 20 быстрых нод, остановится и возьмёт в пул 15 лучших из них. Оставшиеся кандидаты в этот раз не проверяются.'],
        ['Как выбрать', 'Не меньше «Сколько нод держать в быстром пуле», лучше немного больше - тогда в пул попадут лучшие из найденных, а не просто первые. Больше - точнее отбор, но дольше прогон.'],
        HELP_WHEN
      ]
    },
    keep_runs: {
      label: 'Хранить прогонов (0 = не ограничивать)', type: 'number', min: 0,
      hint: 'Сколько последних прогонов помнить для графиков.',
      help: [
        ['Что это', 'История прогонов для графиков на странице статистики. Старые прогоны удаляются.'],
        ['Как работает', 'Действуют оба ограничения - «прогонов» и «дней»: срабатывает то, что наступит раньше. 200 прогонов при прогоне раз в 3 часа - это 25 дней.'],
        ['Связи', 'Лишние прогоны удаляются при следующем прогоне, не сразу. На таблицу «Статистика доступности нод» не влияет - у неё свои параметры в разделе «Дополнительно».'],
        HELP_WHEN
      ]
    },
    keep_days: {
      label: 'Хранить дней (0 = не ограничивать)', type: 'number', min: 0,
      hint: 'Нельзя занулить оба ограничения сразу.',
      help: [
        ['Что это', 'Прогоны старше стольких дней удаляются из истории графиков.'],
        ['Пример', '«Прогонов» 200 и «дней» 7: хранится неделя, даже если за неделю прошло меньше 200 прогонов.'],
        HELP_WHEN
      ]
    },
    node_cap: {
      label: 'Сколько нод показывать на графике сразу (1-50)', type: 'number', min: 1, max: 50,
      hint: 'Первые по числу побед. Остальные можно включить в легенде графика.',
      help: [
        ['Что это', 'Только отображение: сколько нод график «Скорость по нодам» показывает при открытии страницы. На отбор нод не влияет.'],
        ['Как работает', 'Ноды упорядочены по тому, сколько раз попадали в пул. Остальные ноды истории есть в легенде под графиком - включаются кликом или через поиск.'],
        ['Когда действует', 'Сразу после сохранения.']
      ]
    },
    update_check_hours: {
      label: 'Проверять обновления', type: 'select', dflt: 12,
      options: [[1, 'каждый час'], [2, 'раз в 2 часа'], [3, 'раз в 3 часа'], [4, 'раз в 4 часа'], [6, 'раз в 6 часов'], [8, 'раз в 8 часов'], [12, 'раз в 12 часов'], [24, 'раз в сутки']],
      hint: 'Только проверка. Обновление ставится кнопкой в разделе «Обновления».',
      help: [
        ['Что это', 'Как часто роутер сам спрашивает GitHub, не вышла ли новая версия проекта. Если вышла - на вкладке «Обновления» появляется отметка.'],
        ['Важно', 'Ничего не устанавливается само: обновление всегда запускается только кнопкой «Обновить».'],
        ['Когда действует', 'Сразу после сохранения - расписание в cron переписывается.']
      ]
    },
    extype: {
      label: 'Не проверять ноды этих типов (через |)', type: 'text', placeholder: 'например trojan|ss',
      hint: 'Типы протоколов, которые пропускаются целиком. Пусто = пропускается только trojan.',
      help: [
        ['Что это', 'Ноды с таким протоколом (поле type в подписке) не проверяются на скорость и не попадают в быстрый пул.'],
        ['Пример', 'trojan|ss - пропустить Trojan и Shadowsocks. Другие типы: vless, vmess, hysteria2, tuic, wireguard.'],
        ['Зачем', 'Если какой-то протокол у вас не работает или работает плохо, нет смысла тратить на него время и трафик.'],
        ['Связи', 'В config.yaml у провайдера fast тоже есть exclude-type (по умолчанию trojan|ss): если убрать тип отсюда, но оставить там, ноды этого типа будут проверяться, но Mihomo всё равно не возьмёт их в «⚡ Быстрый пул». Пустое поле не отключает фильтр - тогда пропускается trojan.'],
        HELP_WHEN
      ]
    },
    size_mb: {
      label: 'Объём скачивания на одну ноду, МБ', type: 'number', min: 1, max: 100, step: 'any',
      hint: 'Меньше 10 МБ занижает результат. Больше - точнее, но больше трафика.',
      help: [
        ['Что это', 'Сколько данных скачивается через каждую ноду для замера (файл с speed.cloudflare.com). Скорость = объём / время.'],
        ['Почему не меньше 10', 'Первые доли секунды уходят на установку соединения. На маленьком файле они занимают большую часть времени: на 3 МБ нода с реальными 12 МБ/с показывала 4,5 МБ/с.'],
        ['Трафик', 'Объём × число проверенных нод за прогон. 10 МБ × 40 нод = до 400 МБ за прогон.'],
        HELP_WHEN
      ]
    },
    dl_timeout: {
      label: 'Максимум времени на одну ноду, сек', type: 'number', min: 1, max: 120,
      hint: 'Медленная нода не задерживает прогон дольше этого.',
      help: [
        ['Что это', 'Сколько секунд максимум ждать скачивания через одну ноду. Если не успела - засчитывается скорость, с которой она качала до обрыва.'],
        ['Пример', '10 МБ за 15 секунд - это около 5,6 Мбит/с. Нода медленнее за 15 секунд файл не докачает, но её скорость всё равно будет измерена.'],
        ['Связи', 'Самый долгий прогон ≈ это время × «Сколько нод проверять на скорость за прогон». Этим же временем ограничен замер прямого канала в начале прогона.'],
        HELP_WHEN
      ]
    },
    min_speed_mb: {
      label: 'Запасной порог, Мбит/с (если замер канала не удался)', type: 'number', min: 0.1, max: 10000, step: 'any',
      hint: 'Используется только когда прямой замер канала не удался.',
      help: [
        ['Что это', 'Порог скорости на крайний случай. Обычно порог считается в каждом прогоне как «доля от скорости канала», а это число не используется.'],
        ['Когда используется', 'Если в начале прогона не удалось скачать тестовый файл напрямую, без прокси (провайдер недоступен, Cloudflare заблокирован и т.п.).'],
        ['Меняется ли само', 'Да: install.sh при установке и команда mihomo-speedtest recalibrate пересчитывают его по текущей скорости канала и долям выше. Здесь его можно поправить вручную - значение продержится до следующего recalibrate или переустановки.']
      ]
    },
    stability_window: {
      label: 'Окно для расчёта Uptime, прогонов', type: 'number', min: 1, max: 5000,
      hint: 'За сколько последних прогонов считать Uptime в таблице доступности.',
      help: [
        ['Что это', 'Столбец Uptime в таблице «Статистика доступности нод» - доля прогонов, в которых нода отвечала. Этот параметр - за сколько последних прогонов считать.'],
        ['Пример', '200 прогонов при прогоне раз в 3 часа - около 25 дней. 8 - только последние сутки.'],
        ['Связи', 'Влияет только на таблицу доступности, на отбор нод в пул - нет.'],
        HELP_WHEN
      ]
    },
    stability_drop_after: {
      label: 'Убирать из таблицы доступности ноду, пропавшую из подписки, через N прогонов (0 = никогда)', type: 'number', min: 0,
      hint: 'Чистит таблицу от нод, которых больше нет в подписках.',
      help: [
        ['Что это', 'Если нода исчезла из подписки и не появляется столько прогонов подряд, её строка удаляется из таблицы «Статистика доступности нод».'],
        ['Пример', '8 - нода, пропавшая из подписки, исчезнет из таблицы через сутки (при прогоне раз в 3 часа). 0 - строки никогда не удаляются.'],
        HELP_WHEN
      ]
    }
  };

  var CARDS = [
    { geo: true }, // своя карточка - buildGeoFilterCard()
    { title: 'Быстрый пул: какие ноды в него попадают', fields: ['min_ratio', 'min_floor_mb', 'topn', 'min_winners'] },
    { title: 'Сколько нод проверять за прогон', fields: ['max_tested', 'enough'] },
    { title: 'История и графики', fields: ['keep_runs', 'keep_days', 'node_cap'] },
    { title: 'Обновления', fields: ['update_check_hours'] },
    { title: 'Дополнительно', advanced: true, note: 'Редко нужные параметры. Значения по умолчанию подходят большинству.', fields: ['extype', 'size_mb', 'dl_timeout', 'min_speed_mb', 'stability_window', 'stability_drop_after'] }
  ];

  // Короткая схема прогона над формой - чтобы подсказки полей было к чему
  // привязать («порог», «пул», «кандидаты»).
  function buildRunOverviewCard() {
    var c = el('details', 'card settings-overview');
    c.open = true;
    c.appendChild(el('summary', null, 'Как устроен прогон - кратко'));
    var ol = el('ol');
    [
      'Раз в 3 часа (или по кнопке) роутер берёт все ноды из подписок, кроме отфильтрованных гео-фильтром и по типу.',
      'Быстро проверяет, какие из них вообще отвечают.',
      'Замеряет скорость вашего интернета без прокси и считает порог: доля от канала, но не ниже заданного минимума.',
      'По очереди качает тестовый файл через живые ноды и останавливается, когда нашёл достаточно быстрых или проверил максимум нод.',
      'Самые быстрые ноды выше порога записываются в fast.yaml - это группа «⚡ Быстрый пул» в Mihomo. Внутри неё Mihomo сам выбирает ноду с лучшим пингом.'
    ].forEach(function (t) { ol.appendChild(el('li', null, t)); });
    c.appendChild(ol);
    c.appendChild(el('p', 'hint', 'Задержите курсор на любом поле или нажмите «?» рядом с ним - появится подробное объяснение с примерами.'));
    return c;
  }

  // Подробная подсказка поля: появляется, если задержать курсор на поле
  // (HELP_DELAY_MS), и по кнопке «?» (закрепляется до повторного нажатия,
  // клика мимо или Esc). Одновременно открыта одна.
  var HELP_DELAY_MS = 600;
  var openHelp = null;

  function closeOpenHelp() {
    if (openHelp) { openHelp.hide(); }
  }

  document.addEventListener('click', function (e) {
    if (openHelp && !openHelp.wrap.contains(e.target)) { closeOpenHelp(); }
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { closeOpenHelp(); }
  });

  function attachHelp(wrap, head, name, def) {
    var pop = el('div', 'help-pop');
    pop.id = 'help-' + name;
    pop.setAttribute('role', 'tooltip');
    pop.hidden = true;
    pop.appendChild(el('div', 'help-title', def.label));
    def.help.forEach(function (part) {
      var p = el('p');
      p.appendChild(el('b', null, part[0] + '. '));
      p.appendChild(document.createTextNode(part[1]));
      pop.appendChild(p);
    });
    var q = el('button', 'help-q', '?');
    q.type = 'button';
    q.setAttribute('aria-label', 'Подробнее: ' + def.label);
    q.setAttribute('aria-expanded', 'false');
    q.setAttribute('aria-describedby', pop.id);
    head.appendChild(q);
    wrap.appendChild(pop);

    var timer = null, pinned = false;
    var api = {
      wrap: wrap,
      show: function () {
        if (openHelp && openHelp !== api) { openHelp.hide(); }
        pop.hidden = false;
        q.setAttribute('aria-expanded', 'true');
        openHelp = api;
      },
      hide: function () {
        clearTimeout(timer);
        pinned = false;
        pop.hidden = true;
        q.setAttribute('aria-expanded', 'false');
        if (openHelp === api) { openHelp = null; }
      }
    };
    wrap.addEventListener('mouseenter', function () {
      clearTimeout(timer);
      if (pop.hidden) { timer = setTimeout(api.show, HELP_DELAY_MS); }
    });
    wrap.addEventListener('mouseleave', function () {
      clearTimeout(timer);
      if (!pinned) { api.hide(); }
    });
    q.addEventListener('click', function () {
      if (pinned) { api.hide(); return; }
      api.show();
      pinned = true;
    });
  }

  function buildField(name, value) {
    var def = FIELD_DEFS[name];
    var wrap = el('div', 'field');
    var head = el('div', 'field-head');
    var label = el('label', null, def.label);
    label.setAttribute('for', name);
    head.appendChild(label);
    wrap.appendChild(head);
    var input;
    if (def.type === 'select') {
      input = el('select');
      def.options.forEach(function (opt) {
        var o = el('option', null, opt[1]);
        o.value = String(opt[0]);
        input.appendChild(o);
      });
    } else {
      input = el('input');
      input.type = def.type;
    }
    input.id = name;
    input.name = name;
    if (def.type === 'number') {
      if (def.min !== undefined) { input.min = def.min; }
      if (def.max !== undefined) { input.max = def.max; }
      if (def.step !== undefined) { input.step = def.step; }
    }
    if (def.placeholder) { input.placeholder = def.placeholder; }
    input.value = value === undefined || value === null ? '' : value;
    if (def.type === 'select' && !input.value) { input.value = String(def.dflt); }
    wrap.appendChild(input);
    if (def.hint) { wrap.appendChild(el('p', 'hint', def.hint)); }
    if (def.help) { attachHelp(wrap, head, name, def); }
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
    form.appendChild(buildRunOverviewCard());
    // Браузерная проверка min/max не может показать ошибку в поле внутри
    // свёрнутого <details> и молча не отправляет форму - раскрываем блок.
    form.addEventListener('invalid', function (e) {
      var fold = e.target.closest && e.target.closest('details');
      if (fold) { fold.open = true; }
    }, true);

    CARDS.forEach(function (cardDef) {
      if (cardDef.geo) {
        form.appendChild(buildGeoFilterCard(values.geo_filter || '', values.geo_filter_candidates));
        return;
      }
      var c;
      if (cardDef.advanced) {
        // Свёрнутый блок: поля внутри <details> всё равно уходят в POST.
        c = el('details', 'card settings-advanced');
        c.appendChild(el('summary', null, cardDef.title));
      } else {
        c = card(cardDef.title);
      }
      if (cardDef.note) { c.appendChild(el('p', 'hint', cardDef.note)); }
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
            if (badInput) {
              badInput.classList.add('input-err');
              // ошибка в свёрнутом «Дополнительно» - раскрыть, иначе её не видно
              var fold = badInput.closest && badInput.closest('details');
              if (fold) { fold.open = true; }
            }
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

  // Сброс графика «Скорость по нодам» и таблицы «Статистика доступности нод»
  // (reset_node_stats() в stats_cgi.sh). Сводка прогонов остаётся.
  function buildResetStatsCard() {
    var c = card('Сброс статистики нод');
    c.appendChild(el('p', 'hint', 'Очищает график «Скорость по нодам» и таблицу «Статистика доступности нод» - они начнут копиться заново со следующего прогона. Сводка прогонов и настройки не меняются.'));
    var msg = el('p', 'hint');
    var btn = el('button', 'submit secondary', 'Сбросить статистику нод');
    btn.type = 'button';
    btn.addEventListener('click', function () {
      if (!window.confirm('Сбросить статистику «Скорость по нодам» и «Статистика доступности нод»? Отменить сброс нельзя.')) { return; }
      btn.disabled = true;
      msg.className = 'hint';
      msg.textContent = 'Сбрасываю...';
      fetchJson('/api/settings', { method: 'POST', body: new URLSearchParams({ action: 'reset_node_stats' }) }).then(function (resp) {
        if (resp.ok) {
          msg.className = 'msg-ok';
          msg.textContent = 'Статистика нод сброшена.';
        } else {
          var errs = resp.errors || {};
          msg.className = 'msg-err';
          msg.textContent = errs.reset || 'Не удалось сбросить статистику.';
        }
        btn.disabled = false;
      })['catch'](function (err) {
        msg.className = 'msg-err';
        msg.textContent = 'Не удалось сбросить статистику: ' + err.message;
        btn.disabled = false;
      });
    });
    var row = el('div', 'btn-row');
    row.appendChild(btn);
    c.appendChild(row);
    c.appendChild(msg);
    return c;
  }

  function renderSettings(justSavedMsg) {
    setLoading();
    fetchJson('/api/settings').then(function (data) {
      clearApp();
      var values = data.values || {};
      var form = buildSettingsForm(values);
      app.appendChild(form);
      app.appendChild(buildResetStatsCard());
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
  var UPDATE_RELOAD_DELAY_MS = 1500;
  var updateJobPollTimer = null;

  function stopUpdateJobPolling() {
    if (updateJobPollTimer) { clearInterval(updateJobPollTimer); updateJobPollTimer = null; }
  }

  // onUpdate получает целиком ответ /api/updates/status (а не только
  // data.job) - мини консоли (renderUpdatesProgress) на каждый тик нужен
  // ещё и data.log, второй отдельный fetch на то же самое был бы лишним.
  // onError (необязательный) вызывается при неудачном опросе: во время
  // применения обновления веб-служба перезапускается, и несколько опросов
  // подряд закономерно не получают ответа - страница должна показать это,
  // а не молча висеть на «Выполняется...». Опрос при этом продолжается.
  function startUpdateJobPolling(onUpdate, onError) {
    stopUpdateJobPolling();
    function tick() {
      fetchJson('/api/updates/status').then(function (data) {
        onUpdate(data || {});
      })['catch'](function (err) { if (onError) { onError(err); } });
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
    var offline = false;
    startUpdateJobPolling(function (data) {
      renderConsoleLog(consolePre, data.log);
      if (offline) {
        offline = false;
        status.className = 'hint'; status.textContent = 'Веб-служба снова на связи, выполняется...';
      }
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
      status.className = 'msg-ok'; status.textContent = 'Обновление применено. Страница сейчас перезагрузится с новой версией интерфейса...';
      // Пункт фидбека по макету: last_check.plan к этому моменту ещё
      // относится к состоянию ДО применения обновления, поэтому без
      // перепроверки раздел и бейдж продолжили бы показывать "есть
      // обновление" до ручного "Проверить сейчас". Перепроверяем тем же
      // запросом, что и кнопка, и только потом перезагружаем страницу:
      // в браузере до сих пор работает СТАРЫЙ app.js/style.css, а новые
      // файлы веб-интерфейса подхватятся только перезагрузкой (сервер
      // отдаёт их с Cache-Control: no-store). После перезагрузки
      // renderUpdates() покажет итог по job.json (карточка «Последнее
      // обновление»), так что результат не теряется.
      var reload = function () { setTimeout(function () { location.reload(); }, UPDATE_RELOAD_DELAY_MS); };
      fetchJson('/api/updates/check', { method: 'POST' }).then(reload, reload);
    }, function () {
      if (offline) { return; }
      offline = true;
      status.className = 'hint';
      status.textContent = action === 'apply'
        ? 'Нет ответа от веб-службы - при обновлении она перезапускается. Ожидаем, страница продолжит сама...'
        : 'Нет ответа от веб-службы, повторяем запрос...';
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
      // Итог последнего применения (job.json живёт в /tmp до следующей
      // операции или перезагрузки роутера): после автоматической
      // перезагрузки страницы по окончании обновления пользователь сразу
      // видит, что оно встало, или почему не встало.
      if (job && job.action === 'apply' && job.state === 'done') {
        summary.appendChild(el('p', 'msg-ok', 'Последнее обновление применено' +
          (job.finished_at ? ' ' + job.finished_at : '') + '.'));
      } else if (job && job.action === 'apply' && job.state === 'error') {
        summary.appendChild(el('p', 'msg-err', 'Последнее обновление не применено' +
          (job.finished_at ? ' (' + job.finished_at + ')' : '') + ': ' + (job.error || 'неизвестная ошибка')));
      }
      if (lc && lc.ok) {
        // Одна короткая фраза по available (та же проверка, что показывает
        // кнопку "Обновить"): либо доступна новая версия N, либо N уже
        // установлена. Прежний двойной текст (версия релиза + отдельная
        // пометка статуса) владелец счёл избыточным.
        var versionMsg = 'Последняя проверка: ' + lc.checked_at + '. ' +
          (available ? 'Доступна новая версия: ' : 'Установлена актуальная версия: ') +
          (lc.plan.release_tag || lc.plan.release_version) + '.';
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
      // Вместо полного списка файлов - текст последнего релиза "что
      // нового" (п.4 задачи редизайна). lc.notes заполняет cmd_check() на
      // backend: и для доступного обновления, и для уже установленной
      // версии.
      if (lc && lc.ok && lc.notes && lc.notes.length) {
        var notesCard = card(available ? 'Что нового' : 'Что нового в установленной версии');
        lc.notes.forEach(function (n) {
          notesCard.appendChild(el('h2', null, 'Релиз ' + n.tag));
          notesCard.appendChild(el('pre', 'release-notes', n.body || '(описание не указано)'));
        });
        app.appendChild(notesCard);
      }
    })['catch'](function (err) { showError('Не удалось загрузить раздел обновлений: ', err); });
  }

  // ----- раздел "Конфиг" (/api/config/*, stats_config.sh) -----
  //
  // Редактор config.yaml Mihomo на CodeMirror 5 (stats_codemirror.js,
  // вендоренная сборка, раздаётся как codemirror.js). Библиотека грузится
  // только при открытии вкладки, остальные разделы её не ждут. Если она
  // не загрузилась - редактор работает на обычном textarea.
  // Сохранение, откат и починка выполняются на роутере (stats_config.sh):
  // mihomo -t, бэкап, атомарная замена, xkeen -restart, автооткат.

  var configView = null;   // {dirty:bool} - есть несохранённые правки
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
            '. Похоже, CGI cgi-bin/configedit не установлен или завершился с ошибкой - ' +
            'перезапустите веб-службу (/opt/etc/init.d/S80speedtest-stats restart).');
        }
        return data;
      });
    });
  }

  function postText(url, text) {
    return fetchJson(url, { method: 'POST', body: text, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }

  function renderConfig() {
    setLoading();
    configView = { dirty: false };
    var view = configView;
    fetchConfigJson('/api/config', 'text').then(function (data) {
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
        if (/ГОТОВО|ядро работает/.test(line)) { return 'log-line ok'; }
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
      var d = err.data || {};
      showError('Не удалось загрузить конфиг: ', d.message ? new Error(d.message) : err);
    });
  }

  window.addEventListener('beforeunload', function (e) {
    if (configView && configView.dirty) { e.preventDefault(); e.returnValue = ''; }
  });

  function render(path) {
    configView = null;
    stopProgressPolling();
    stopUpdateJobPolling();
    stopLogPolling();
    if (path === '/updates') { renderUpdates(); }
    else if (path === '/settings') { renderSettings(); }
    else if (path === '/log') { renderLog(); }
    else if (path === '/config') { renderConfig(); }
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
