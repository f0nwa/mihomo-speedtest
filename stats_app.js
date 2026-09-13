// Клиентский роутер и логика SPA-shell веб-сервиса статистики speedtest2
// (index.html + style.css) - см. docs/plans/2026-09-12-web-spa-migration-design.md.
// Ставится install.sh как $DIR/stats_app.js; копия внутри раздаваемого
// каталога (app.js) пишется сама write_stats_static() из speedtest2.sh -
// править нужно этот файл, не копию.
//
// Шаг 4 плана: "/api/stats" и "/api/settings" теперь отдают реальные
// данные (см. render_stats.awk -v format=json и print_settings_json() в
// stats_cgi.sh) - вместо заглушки "раздел переезжает" здесь рисуются сами
// разделы. Никаких сторонних библиотек (на роутере нет Node.js и сборки) -
// график по нодам рисуется вручную через SVG.
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

  function renderRunButton(container) {
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
      })['catch'](function (err) {
        status.textContent = 'Не удалось узнать статус: ' + err.message;
      });
    }

    btn.addEventListener('click', function () {
      btn.disabled = true;
      fetchJson('/api/run', { method: 'POST' }).then(function (d) {
        status.textContent = d.started ? 'Прогон запущен.' : 'Прогон уже шёл, новый не запускался.';
      })['catch'](function (err) {
        status.textContent = 'Не удалось запустить: ' + err.message;
      })['finally'](function () { btn.disabled = false; });
    });

    refreshStatus();
  }

  // ----- раздел "Статистика" (/api/stats) -----

  var SVG_NS = 'http://www.w3.org/2000/svg';

  // fmtDateShort/fmtTimeShort - как fmt_date_short()/fmt_time_short() в
  // render_stats.awk: iso в формате "YYYY-MM-DD HH:MM:SS".
  function fmtDateShort(iso) {
    return iso.slice(8, 10) + '.' + iso.slice(5, 7);
  }
  function fmtTimeShort(iso) {
    return iso.slice(11, 16);
  }

  function svgEl(tag, attrs) {
    var e = document.createElementNS(SVG_NS, tag);
    for (var k in attrs) { e.setAttribute(k, attrs[k]); }
    return e;
  }

  // renderXAxisDates() - таймлайн под графиком, перенесено из
  // render_x_axis_dates() в render_stats.awk (тот же алгоритм: 2-6 подписей
  // на равных по индексу прогона позициях, дата или время в зависимости от
  // того, попадают ли выбранные метки в один календарный день).
  function renderXAxisDates(svg, left, padTop, w, h, labels) {
    var n = labels.length;
    if (n < 2) { return; }
    var tn = n < 6 ? n : 6;
    var day1 = labels[0].slice(0, 10);
    var sameDay = true;
    for (var i = 0; i < n; i++) {
      if (labels[i].slice(0, 10) !== day1) { sameDay = false; break; }
    }
    var prevIdx = -1;
    for (var t = 0; t < tn; t++) {
      var idx = Math.round((t * (n - 1)) / (tn - 1));
      if (idx < 0) { idx = 0; }
      if (idx > n - 1) { idx = n - 1; }
      if (idx === prevIdx) { continue; }
      prevIdx = idx;
      var x = n > 1 ? left + (idx * w) / (n - 1) : left + w / 2;
      var anchor = t === 0 ? 'start' : t === tn - 1 ? 'end' : 'middle';
      var lbl = sameDay ? fmtTimeShort(labels[idx]) : fmtDateShort(labels[idx]);
      svg.appendChild(svgEl('line', { 'class': 'axis-tick', x1: x, y1: padTop + h, x2: x, y2: padTop + h + 4 }));
      var text = svgEl('text', { 'class': 'axis-text', x: x, y: padTop + h + 15, 'font-size': 10, 'text-anchor': anchor });
      text.textContent = lbl;
      svg.appendChild(text);
    }
  }

  // buildNodeChart() - SVG-график по нодам без сторонних библиотек,
  // перенесено из render_node_history() в render_stats.awk (оси, таймлайн,
  // подсказки-точки и наведение курсором с перекрестием - тот же набор
  // возможностей, что был у старой server-rendered stats.html).
  // runsSeries - data.runs.series из /api/stats (нужен только iso[] для
  // подписей оси X и подсказки).
  function buildNodeChart(nodeHistory, runsSeries) {
    var left = 40, padTop = 10, w = 710, h = 170, W = 760, H = 214;
    var top = nodeHistory.top || [];
    var n = runsSeries.length;
    var labels = runsSeries.map(function (r) { return r.iso; });

    var wrap = el('div', 'chart-wrap');
    var svg = svgEl('svg', { id: 'svg-hist', viewBox: '0 0 ' + W + ' ' + H, width: '100%', height: H });

    var max = 0;
    for (var i = 0; i < top.length; i++) {
      for (var j = 0; j < top[i].values.length; j++) {
        var v = top[i].values[j];
        if (v !== null && v > max) { max = v; }
      }
    }
    if (max <= 0) { max = 1; }

    function xOf(idx) {
      return n > 1 ? left + (idx * w) / (n - 1) : left + w / 2;
    }
    function yOf(v) {
      return padTop + h - (v * h) / max;
    }

    svg.appendChild(svgEl('line', { 'class': 'axis-line', x1: left, y1: padTop, x2: left, y2: padTop + h }));
    svg.appendChild(svgEl('line', { 'class': 'axis-line', x1: left, y1: padTop + h, x2: left + w, y2: padTop + h }));
    var maxLabel = svgEl('text', { 'class': 'axis-text', x: left - 6, y: padTop + 4, 'font-size': 10, 'text-anchor': 'end' });
    maxLabel.textContent = fmtMB(max) + ' МБ/с';
    svg.appendChild(maxLabel);
    var zeroLabel = svgEl('text', { 'class': 'axis-text', x: left - 6, y: padTop + h + 4, 'font-size': 10, 'text-anchor': 'end' });
    zeroLabel.textContent = '0';
    svg.appendChild(zeroLabel);
    renderXAxisDates(svg, left, padTop, w, h, labels);

    var groups = {};
    var dots = {};
    for (var k = 0; k < top.length; k++) {
      var values = top[k].values;
      var color = top[k].color || '#2a78d6';
      var group = svgEl('g', { 'class': 'node-series', id: 'series-hist-n' + k });

      var d = '';
      var pen = false;
      for (var m = 0; m < values.length; m++) {
        var val = values[m];
        if (val === null) { pen = false; continue; }
        var cmd = pen ? 'L' : 'M';
        d += cmd + xOf(m).toFixed(1) + ' ' + yOf(val).toFixed(1) + ' ';
        pen = true;
      }
      if (d) {
        group.appendChild(svgEl('path', { d: d.trim(), fill: 'none', stroke: color, 'stroke-width': 2 }));
      }
      for (var p = 0; p < values.length; p++) {
        var pv = values[p];
        if (pv === null) { continue; }
        var dot = svgEl('circle', { 'class': 'node-dot', cx: xOf(p).toFixed(1), cy: yOf(pv).toFixed(1), r: 3, fill: color, 'stroke-width': 1 });
        var title = document.createElementNS(SVG_NS, 'title');
        title.textContent = (labels[p] || '') + ' · ' + fmtMB(pv) + ' МБ/с · ' + top[k].name;
        dot.appendChild(title);
        group.appendChild(dot);
      }
      svg.appendChild(group);
      groups[k] = group;
    }

    var crosshair = svgEl('line', { 'class': 'crosshair-line', id: 'crosshair-hist', x1: left, y1: padTop, x2: left, y2: padTop + h, visibility: 'hidden' });
    svg.appendChild(crosshair);
    for (var kk = 0; kk < top.length; kk++) {
      var cdot = svgEl('circle', { 'class': 'crosshair-dot', id: 'dot-hist-n' + kk, r: 3.5, fill: top[kk].color || '#2a78d6', visibility: 'hidden' });
      svg.appendChild(cdot);
      dots[kk] = cdot;
    }
    var capture = svgEl('rect', { 'class': 'chart-capture', id: 'capture-hist', x: left, y: padTop, width: w, height: h });
    svg.appendChild(capture);

    wrap.appendChild(svg);
    var tooltip = el('div', 'tooltip');
    tooltip.id = 'tooltip-hist';
    tooltip.hidden = true;
    wrap.appendChild(tooltip);

    // Наведение курсором (и touch) - перекрестие + подсветка ближайшей ноды +
    // подсказка с показаниями всех нод в этой точке, как в старой
    // server-rendered stats.html (см. общий initChart() в render_stats.awk).
    function svgPoint(clientX, clientY) {
      var pt = svg.createSVGPoint();
      pt.x = clientX; pt.y = clientY;
      return pt.matrixTransform(svg.getScreenCTM().inverse());
    }
    function idxAt(svgX) {
      var step = n > 1 ? w / (n - 1) : 0;
      var idx = step > 0 ? Math.round((svgX - left) / step) : 0;
      if (idx < 0) { idx = 0; }
      if (idx > n - 1) { idx = n - 1; }
      return idx;
    }
    function show(clientX, clientY) {
      if (!n) { return; }
      var loc = svgPoint(clientX, clientY);
      var idx = idxAt(loc.x);
      var x = xOf(idx);
      crosshair.setAttribute('x1', x); crosshair.setAttribute('x2', x);
      crosshair.setAttribute('visibility', 'visible');
      var html = '<div class="tt-label">' + (labels[idx] || '') + '</div>';
      var nearestId = null, nearestDist = Infinity;
      for (var ii = 0; ii < top.length; ii++) {
        var vv = top[ii].values[idx];
        if (vv === null || vv === undefined) { continue; }
        var dist = Math.abs(loc.y - yOf(vv));
        if (dist < nearestDist) { nearestDist = dist; nearestId = ii; }
      }
      for (var jj = 0; jj < top.length; jj++) {
        var v2 = top[jj].values[idx];
        var dot2 = dots[jj];
        if (v2 === null || v2 === undefined) {
          if (dot2) { dot2.setAttribute('visibility', 'hidden'); }
        } else {
          if (dot2) {
            dot2.setAttribute('cx', x);
            dot2.setAttribute('cy', yOf(v2));
            dot2.setAttribute('visibility', 'visible');
          }
          html += '<div class="tt-row"><span class="sw" style="background:' + (top[jj].color || '#2a78d6') + '"></span>' + top[jj].name + ': ' + fmtMB(v2) + ' МБ/с</div>';
        }
        if (groups[jj]) { groups[jj].classList.toggle('dim', jj !== nearestId); }
      }
      tooltip.innerHTML = html;
      tooltip.hidden = false;
      var wrapRect = wrap.getBoundingClientRect();
      var tleft = clientX - wrapRect.left + 12;
      var ttop = clientY - wrapRect.top - 12;
      var maxLeft = wrapRect.width - tooltip.offsetWidth - 4;
      if (tleft > maxLeft) { tleft = clientX - wrapRect.left - tooltip.offsetWidth - 12; }
      if (tleft < 0) { tleft = 0; }
      tooltip.style.left = tleft + 'px';
      tooltip.style.top = ttop + 'px';
    }
    function hide() {
      crosshair.setAttribute('visibility', 'hidden');
      for (var kd in dots) { if (dots[kd]) { dots[kd].setAttribute('visibility', 'hidden'); } }
      for (var kg in groups) { if (groups[kg]) { groups[kg].classList.remove('dim'); } }
      tooltip.hidden = true;
    }
    capture.addEventListener('mousemove', function (e) { show(e.clientX, e.clientY); });
    capture.addEventListener('mouseleave', hide);
    capture.addEventListener('touchmove', function (e) { if (e.touches && e.touches[0]) { show(e.touches[0].clientX, e.touches[0].clientY); } }, { passive: true });
    capture.addEventListener('touchend', hide);

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
    ['Нода', 'Статус', 'Uptime', 'Сейчас, МБ/с', 'Средняя, МБ/с', 'Δ, МБ/с'].forEach(function (t) {
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
      renderRunButton(runCard);
      app.appendChild(runCard);
    })['catch'](function (err) {
      if (err.message === 'not_implemented') {
        showNotYetMoved('Раздел статистики ещё переезжает на новый интерфейс.');
        renderRunButton(app);
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
    { title: 'Как тестируем ноды', fields: ['extype', 'size_mb', 'dl_timeout'] },
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

    var submitBtn = el('button', 'submit', 'Сохранить');
    submitBtn.type = 'submit';
    form.appendChild(submitBtn);

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      submitBtn.disabled = true;
      showFormMessage(form, null);
      var body = new URLSearchParams(new FormData(form));
      fetchJson('/api/settings', { method: 'POST', body: body }).then(function (resp) {
        if (resp.ok) {
          renderSettings('Настройки сохранены.');
          return;
        }
        var texts = [];
        var errs = resp.errors || {};
        Object.keys(errs).forEach(function (key) {
          texts.push(errs[key]);
          var badInput = form.querySelector('[name="' + key + '"]');
          if (badInput) { badInput.classList.add('input-err'); }
        });
        showFormMessage(form, texts.join(' '), 'err');
      })['catch'](function (err) {
        showFormMessage(form, 'Не удалось сохранить: ' + err.message, 'err');
      })['finally'](function () { submitBtn.disabled = false; });
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
    if (path === '/settings') { renderSettings(); } else { renderStats(); }
  }

  render(location.pathname);
  updateActiveNav(location.pathname);
})();
