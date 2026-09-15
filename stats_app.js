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

  var THEME_KEY = 'speedtest2-theme';
  var root = document.documentElement;
  var app = document.getElementById('app');
  var themeBtn = document.getElementById('themeBtn');

  function applyTheme(t) {
    if (t) { root.setAttribute('data-theme', t); } else { root.removeAttribute('data-theme'); }
    var cur = root.getAttribute('data-theme');
    themeBtn.textContent = cur === 'dark' ? 'Светлая тема' : cur === 'light' ? 'Тёмная тема' : 'Тема: авто';
  }
  var savedTheme = null;
  try { savedTheme = localStorage.getItem(THEME_KEY); } catch (e) { /* приватный режим и т.п. - без темы по умолчанию */ }
  applyTheme(savedTheme);
  themeBtn.addEventListener('click', function () {
    var cur = root.getAttribute('data-theme');
    var next = cur === 'dark' ? 'light' : cur === 'light' ? null : 'dark';
    applyTheme(next);
    try {
      if (next) { localStorage.setItem(THEME_KEY, next); } else { localStorage.removeItem(THEME_KEY); }
    } catch (e) { /* см. выше */ }
  });

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
    render(location.pathname);
    updateActiveNav(location.pathname);
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
    return fetch(url, opts).then(function (r) {
      return r.json()['catch'](function () { return {}; }).then(function (data) {
        if (!r.ok) {
          throw new Error(data && data.error ? data.error : ('HTTP ' + r.status));
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

  // Байты -> МБ/с текстом, как bytes_to_mb() в stats_cgi.sh (%g - без
  // лишних нулей после запятой), null/undefined -> "-".
  function fmtMB(bytes) {
    if (bytes === null || bytes === undefined) { return '-'; }
    var v = bytes / 1048576;
    var r = Math.round(v * 100) / 100;
    return String(r);
  }

  function fmtSigned(bytes) {
    if (bytes === null || bytes === undefined) { return '-'; }
    var s = fmtMB(Math.abs(bytes));
    if (bytes > 0) { return '+' + s; }
    if (bytes < 0) { return '-' + s; }
    return s;
  }

  function statusLabel(status) {
    if (status === 'alive') { return { text: 'жива', cls: 'status-alive' }; }
    if (status === 'down') { return { text: 'недоступна', cls: 'status-down' }; }
    return { text: 'нет данных', cls: 'status-absent' };
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
    ['Нода', 'Скорость, МБ/с', 'Статус'].forEach(function (t) {
      htr.appendChild(el('th', null, t));
    });
    thead.appendChild(htr);
    table.appendChild(thead);
    var tbody = el('tbody');
    for (var i = 0; i < results.length; i++) {
      var r = results[i];
      var tr = el('tr');
      tr.appendChild(el('td', null, r.name));
      tr.appendChild(el('td', null, fmtMB(r.speed_bytes)));
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
        data: node.values.map(function (v) { return v === null || v === undefined ? null : v / 1048576; }),
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
                return item.dataset.label + ': ' + (item.parsed.y === null ? '-' : item.parsed.y) + ' МБ/с';
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
              callback: function (value) { return value + ' МБ/с'; }
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

  function buildStabilityTable(rows) {
    var table = el('table');
    var thead = el('thead');
    var htr = el('tr');
    ['Нода', 'Статус', 'Последний раз жива', 'Uptime', 'Сейчас, МБ/с', 'Средняя, МБ/с', 'Δ, МБ/с'].forEach(function (t) {
      htr.appendChild(el('th', null, t));
    });
    thead.appendChild(htr);
    table.appendChild(thead);
    var tbody = el('tbody');
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      var tr = el('tr');
      tr.appendChild(el('td', null, r.name));
      var st = statusLabel(r.status);
      tr.appendChild(el('td', st.cls, st.text));
      tr.appendChild(el('td', null, fmtLastSeen(r.last_seen)));
      tr.appendChild(el('td', null, r.uptime_pct === null ? '-' : r.uptime_pct + '%'));
      tr.appendChild(el('td', null, fmtMB(r.last_speed_bytes)));
      tr.appendChild(el('td', null, fmtMB(r.avg_speed_bytes)));
      tr.appendChild(el('td', null, fmtSigned(r.delta_bytes)));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderStats() {
    stopProgressPolling();
    setLoading();
    fetchJson('/api/stats').then(function (data) {
      clearApp();

      var meta = el('p', 'hint', 'Обновлено: ' + (data.generated || '-') + ' · прогонов в истории: ' + data.runs.count);
      app.appendChild(meta);

      var lastRunCard = card('Последний прогон');
      if (data.last_run) {
        var lr = data.last_run;
        var p = el('p', 'hint');
        p.textContent = lr.iso + ' - канал: ' + fmtMB(lr.channel_bytes) + ' МБ/с, порог: ' +
          fmtMB(lr.threshold_bytes) + ' МБ/с, живых нод: ' + lr.alive + '/' + lr.total +
          ', победителей: ' + lr.winners;
        lastRunCard.appendChild(p);
      } else {
        lastRunCard.appendChild(el('p', 'hint', 'Прогонов ещё не было.'));
      }
      app.appendChild(lastRunCard);

      var lastMeasureCard = card('Последний замер');
      if (data.last_measurement && data.last_measurement.length) {
        for (var m = 0; m < data.last_measurement.length; m++) {
          var meas = data.last_measurement[m];
          lastMeasureCard.appendChild(el('p', 'hint', meas.name + ': ' + meas.speed_mb + ' ' + meas.unit));
        }
      } else {
        lastMeasureCard.appendChild(el('p', 'hint', 'Данных пока нет.'));
      }
      app.appendChild(lastMeasureCard);

      var chartCard = card('Скорость по нодам (последние ' + data.runs.count + ' прогонов)');
      if (data.node_history && data.node_history.total_unique > 0) {
        chartCard.appendChild(buildNodeLegend(data.node_history));
        chartCard.appendChild(buildNodeChart(data.node_history, data.runs.series));
      } else {
        chartCard.appendChild(el('p', 'hint', 'Пока недостаточно истории для графика.'));
      }
      app.appendChild(chartCard);

      var stabilityCard = card('Доступность нод пула');
      if (data.node_stability && data.node_stability.length) {
        stabilityCard.appendChild(buildStabilityTable(data.node_stability));
      } else {
        stabilityCard.appendChild(el('p', 'hint', 'Данных пока нет.'));
      }
      app.appendChild(stabilityCard);

      var runCard = card('Запустить прогон вручную');
      renderRunButton(runCard, function () { startProgressPolling(app, lastRunCard); });
      app.appendChild(runCard);
    })['catch'](function (err) {
      if (err.message === 'not_implemented') {
        showNotYetMoved('Раздел статистики ещё переезжает на новый интерфейс.');
        renderRunButton(app, function () { startProgressPolling(app, null); });
        return;
      }
      showError('Не удалось загрузить статистику: ', err);
    });
  }

  // ----- раздел "Настройки" (/api/settings) -----

  // Описание полей формы - в том же порядке и с теми же подписями/
  // подсказками/диапазонами, что и в прежней HTML-форме stats_cgi.sh, -
  // группировка по карточкам ниже повторяет прежнюю разбивку.
  var FIELD_DEFS = {
    max_tested: { label: 'Максимум кандидатов на скоростной тест', type: 'number', min: 0, hint: 'Берём первые живые ноды по возрастанию технического времени ответа второго ядра. 0 = без ограничения.' },
    geo_filter: { label: 'Регулярное выражение для исключения нод', type: 'text', hint: 'Обязательное поле - без него подписка может подставить российскую ноду, которая выиграет замер по пингу. Подсказки в списке - варианты exclude-filter, найденные в текущем config.yaml.', datalist: 'geo_filter_options' },
    extype: { label: 'Исключить типы нод целиком (через |)', type: 'text', placeholder: 'например trojan|ss', hint: 'Пусто = тестировать все типы, которые понимает mihomo.' },
    size_mb: { label: 'Размер файла для замера, МБ', type: 'number', min: 1, max: 100, step: 'any', hint: 'Меньше 10 МБ занижает результат - треть времени уходит на TTFB.' },
    dl_timeout: { label: 'Таймаут закачки, сек', type: 'number', min: 1, max: 120 },
    min_speed_mb: { label: 'Порог отбора (для текущего канала), МБ/с', type: 'number', min: 0.1, max: 1000, step: 'any', hint: 'Пересчитывается install.sh при переустановке от прямого замера канала - здесь можно поправить вручную.' },
    min_ratio: { label: 'Динамический порог, доля от прямого канала', type: 'number', min: 0.01, max: 1, step: 'any' },
    min_floor_mb: { label: 'Абсолютный минимум порога, МБ/с (0 = без минимума)', type: 'number', min: 0, step: 'any' },
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
    { title: 'Гео-фильтр (BLOCK)', fields: ['geo_filter'] },
    { title: 'Как тестируем ноды', fields: ['extype', 'max_tested', 'size_mb', 'dl_timeout'] },
    { title: 'Порог и число нод в fast.yaml', fields: ['min_speed_mb', 'min_ratio', 'min_floor_mb', 'topn', 'enough', 'min_winners'] },
    { title: 'Стабильность нод', fields: ['stability_window', 'stability_drop_after'] },
    { title: 'График по нодам', fields: ['node_cap'] },
    { title: 'Хранение истории', fields: ['keep_runs', 'keep_days'] }
  ];

  function buildField(name, value, geoCandidates) {
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
    if (def.datalist) {
      input.setAttribute('list', def.datalist);
      input.autocomplete = 'off';
    }
    wrap.appendChild(input);
    if (def.datalist === 'geo_filter_options') {
      var dl = el('datalist');
      dl.id = 'geo_filter_options';
      (geoCandidates || []).forEach(function (c) {
        var opt = document.createElement('option');
        opt.value = c;
        dl.appendChild(opt);
      });
      wrap.appendChild(dl);
    }
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
      var c = card(cardDef.title);
      cardDef.fields.forEach(function (name) {
        c.appendChild(buildField(name, values[name], values.geo_filter_candidates));
      });
      form.appendChild(c);
    });

    var authCard = card('Защита формы настройки');
    authCard.appendChild(el('p', 'hint', 'Страница статистики всегда открыта без пароля. Этой формой можно закрыть только саму настройку.'));
    var userLabel = el('label', null, 'Логин');
    userLabel.setAttribute('for', 'auth_user');
    authCard.appendChild(userLabel);
    var userInput = el('input');
    userInput.type = 'text'; userInput.id = 'auth_user'; userInput.name = 'auth_user';
    userInput.autocomplete = 'off';
    userInput.placeholder = values.has_auth && values.auth_user ? 'текущий: ' + values.auth_user : 'не задан';
    authCard.appendChild(userInput);
    var passLabel = el('label', null, 'Новый пароль');
    passLabel.setAttribute('for', 'auth_pass');
    authCard.appendChild(passLabel);
    var passInput = el('input');
    passInput.type = 'password'; passInput.id = 'auth_pass'; passInput.name = 'auth_pass';
    passInput.autocomplete = 'new-password';
    passInput.placeholder = 'оставьте пустым, если не меняете';
    authCard.appendChild(passInput);
    var rc = el('div', 'row-checkbox');
    var noAuthInput = el('input');
    noAuthInput.type = 'checkbox'; noAuthInput.id = 'no_auth'; noAuthInput.name = 'no_auth'; noAuthInput.value = '1';
    rc.appendChild(noAuthInput);
    var noAuthLabel = el('label', null, 'Отключить защиту (доступ без пароля)');
    noAuthLabel.setAttribute('for', 'no_auth');
    rc.appendChild(noAuthLabel);
    authCard.appendChild(rc);
    form.appendChild(authCard);

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

  function render(path) {
    stopProgressPolling();
    if (path === '/settings') { renderSettings(); } else { renderStats(); }
  }

  render(location.pathname);
  updateActiveNav(location.pathname);
})();
