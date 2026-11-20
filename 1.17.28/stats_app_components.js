// Карточка «Компоненты» раздела «Обновления»: версии ядра mihomo, zashboard
// и xkeen, проверка и обновление ядра/zashboard (/api/components/*).
// Обновление самого проекта - в stats_app_updates.js, здесь его нет.

import { card, el, fetchJson, showFormMessage } from './app-core.js';

var COMPONENT_ORDER = ['mihomo', 'zashboard', 'xkeen'];
var COMPONENT_TITLES = { mihomo: 'Ядро mihomo', zashboard: 'Zashboard', xkeen: 'XKeen' };
var CONFIRM_TEXTS = {
  mihomo: 'Обновить ядро mihomo? Прокси и замеры скорости кратко прервутся. Если ядро не поднимется, прежняя версия вернётся сама.',
  zashboard: 'Обновить zashboard?'
};
var JOB_POLL_MS = 2000;
var jobPollTimer = null;

export function stopComponentsPolling() {
  if (jobPollTimer) { clearInterval(jobPollTimer); jobPollTimer = null; }
}

// data - ответ /api/components/status. «Есть обновление» хоть у одного
// компонента (включая индикатор xkeen): по этому правилу считаются бейдж в
// меню и плитка на /stats (см. refreshUpdatesBadge в app-updates.js).
export function componentsAvailable(data) {
  var items = data && data.components && data.components.items;
  if (!items) { return false; }
  return COMPONENT_ORDER.some(function (key) { return !!(items[key] && items[key].available); });
}

// components - поле components из ответа status (или null). Три строки в
// фиксированном порядке; без данных строка получает tone 'muted'.
export function componentRows(components) {
  var items = (components && components.items) || {};
  return COMPONENT_ORDER.map(function (key) {
    var it = items[key] || {};
    var status; var tone;
    if (it.error) { status = it.error; tone = 'err'; }
    else if (it.available) { status = 'Доступно обновление'; tone = 'warn'; }
    else if (it.installed && it.latest) { status = 'Актуально'; tone = 'ok'; }
    else if (!it.installed && it.latest) { status = 'Версия не определена'; tone = 'muted'; }
    else { status = 'Нет данных'; tone = 'muted'; }
    var canApply = !!it.can_apply && !it.error && (!!it.available || (!it.installed && !!it.latest));
    return {
      key: key,
      title: COMPONENT_TITLES[key],
      installed: it.installed || 'неизвестна',
      latest: it.latest || '—',
      channel: it.channel || null,
      status: status,
      tone: tone,
      canApply: canApply,
      note: key === 'xkeen' ? 'Обновляется вручную по SSH: панель только сообщает о новой версии.' : ''
    };
  });
}

function renderConsole(pre, text) {
  while (pre.firstChild) { pre.removeChild(pre.firstChild); }
  var lines = String(text || '').split('\n');
  lines.forEach(function (line, i) {
    if (line === '' && i === lines.length - 1) { return; }
    pre.appendChild(el('div', 'log-line' + (line.indexOf('ОШИБКА') >= 0 ? ' err' : ''), line === '' ? ' ' : line));
  });
  pre.scrollTop = pre.scrollHeight;
}

function buildTable(rows, onApply, busy) {
  var table = el('table');
  var head = el('tr');
  ['Компонент', 'Установлено', 'Последняя', 'Статус', ''].forEach(function (t) { head.appendChild(el('th', null, t)); });
  table.appendChild(head);
  rows.forEach(function (r) {
    var tr = el('tr');
    var name = el('td', null, r.title + (r.channel ? ' (' + r.channel + ')' : ''));
    if (r.note) { name.appendChild(el('div', 'hint', r.note)); }
    tr.appendChild(name);
    tr.appendChild(el('td', null, r.installed));
    tr.appendChild(el('td', null, r.latest));
    tr.appendChild(el('td', r.tone === 'err' ? 'msg-err-text' : null, r.status));
    var act = el('td');
    if (r.canApply) {
      var b = el('button', 'submit', 'Обновить');
      b.type = 'button';
      b.disabled = !!busy;
      b.addEventListener('click', function () { onApply(r.key); });
      act.appendChild(b);
    }
    tr.appendChild(act);
    table.appendChild(tr);
  });
  return table;
}

// onChanged - вызывается после проверки и после завершения обновления
// (app-updates.js пересчитывает бейдж и плитку).
export function buildComponentsCard(onChanged) {
  var c = card('Компоненты');
  var body = el('div');
  c.appendChild(body);
  var changed = function () { if (onChanged) { onChanged(); } };

  function clear() { while (body.firstChild) { body.removeChild(body.firstChild); } }

  function showProgress(name) {
    clear();
    var status = el('p', 'hint', 'Обновление ' + (COMPONENT_TITLES[name] || name) + ': выполняется...');
    var pre = el('pre', 'update-console');
    body.appendChild(status);
    body.appendChild(pre);
    stopComponentsPolling();
    function tick() {
      if (!document.body.contains(c)) { stopComponentsPolling(); return; }
      fetchJson('/api/components/status').then(function (data) {
        renderConsole(pre, data.log);
        var job = data.job;
        if (!job || job.state === 'running') { return; }
        stopComponentsPolling();
        load(job.state === 'error' ? 'Обновление не выполнено: ' + (job.error || 'неизвестная ошибка') : 'Обновление выполнено.', job.state === 'error' ? 'err' : 'ok');
        changed();
      })['catch'](function () { status.textContent = 'Нет ответа от панели, жду...'; });
    }
    tick();
    jobPollTimer = setInterval(tick, JOB_POLL_MS);
  }

  function apply(name) {
    if (!window.confirm(CONFIRM_TEXTS[name] || 'Обновить?')) { return; }
    fetchJson('/api/components/apply?name=' + encodeURIComponent(name), { method: 'POST' }).then(function () {
      showProgress(name);
    })['catch'](function (err) { showFormMessage(body, 'Не удалось запустить обновление: ' + err.message, 'err'); });
  }

  function render(data, msg, kind) {
    clear();
    if (msg) { showFormMessage(body, msg, kind); }
    var comps = data && data.components;
    body.appendChild(el('p', 'hint', comps && comps.checked_at
      ? 'Последняя проверка: ' + comps.checked_at + '.'
      : 'Проверок ещё не было.'));
    body.appendChild(buildTable(componentRows(comps), apply, false));
    var row = el('div', 'btn-row');
    var checkBtn = el('button', 'submit', 'Проверить сейчас');
    checkBtn.type = 'button';
    checkBtn.addEventListener('click', function () {
      checkBtn.disabled = true;
      fetchJson('/api/components/check', { method: 'POST' }).then(function () { load(); changed(); })
        ['catch'](function (err) {
          showFormMessage(body, 'Не удалось проверить: ' + err.message, 'err');
          checkBtn.disabled = false;
        });
    });
    row.appendChild(checkBtn);
    body.appendChild(row);
  }

  function load(msg, kind) {
    fetchJson('/api/components/status').then(function (data) {
      if (data && data.job && data.job.state === 'running') { showProgress(data.job.name); return; }
      render(data, msg, kind);
    })['catch'](function (err) {
      clear();
      body.appendChild(el('p', 'msg-err', 'Не удалось загрузить компоненты: ' + err.message));
    });
  }

  body.appendChild(el('p', 'hint', 'Загрузка...'));
  load();
  return c;
}
