// Вкладка «Журнал» (/log): живой журнал speedtest2.sh и службы.

import { app, card, clearApp, el, fetchJson } from './app-core.js';

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

export function stopLogPolling() {
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

export function renderLog() {
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
