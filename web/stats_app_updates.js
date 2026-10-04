// Раздел «Обновления» (/updates) и бейдж новой версии в меню.

import { app, card, clearApp, el, fetchJson, setLoading, showError, showFormMessage, viewGuard } from './app-core.js';
import { stopProgressPolling } from './app-stats.js';
import { stopLogPolling } from './app-log.js';
import { buildField } from './app-settings.js';

// ----- раздел "Обновления" (/api/updates/*) -----

function updatesBadgeEl() { return document.getElementById('updatesBadge'); }

export function refreshUpdatesBadge() {
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

export function stopUpdateJobPolling() {
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

// Карточка «Настройки обновлений»: канал и частота проверки. Раньше жила в
// «Настройках», перенесена сюда, к кнопкам проверки и обновления.
// Сохраняет отдельным действием save_updates (save_update_settings() в
// stats_cgi.sh) - остальные настройки не трогает.
function buildUpdateSettingsCard(values) {
  var form = document.createElement('form');
  form.className = 'card';
  form.appendChild(el('h2', null, 'Настройки обновлений'));
  ['update_channel', 'update_check_hours'].forEach(function (name) {
    form.appendChild(buildField(name, values[name]));
  });
  var row = el('div', 'btn-row');
  var saveBtn = el('button', 'submit', 'Сохранить');
  saveBtn.type = 'submit';
  row.appendChild(saveBtn);
  form.appendChild(row);
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    saveBtn.disabled = true;
    showFormMessage(form, null);
    form.querySelectorAll('.input-err').forEach(function (x) { x.classList.remove('input-err'); });
    var body = new URLSearchParams(new FormData(form));
    body.set('action', 'save_updates');
    fetchJson('/api/settings', { method: 'POST', body: body }).then(function (resp) {
      saveBtn.disabled = false;
      if (resp.ok) {
        showFormMessage(form, 'Сохранено. Новый канал учтётся при следующей проверке или сразу по кнопке «Проверить сейчас».', 'ok');
        return;
      }
      var errs = resp.errors || {};
      var texts = [];
      Object.keys(errs).forEach(function (key) {
        texts.push(errs[key]);
        var bad = form.querySelector('[name="' + key + '"]');
        if (bad) { bad.classList.add('input-err'); }
      });
      showFormMessage(form, texts.join(' ') || 'Не удалось сохранить.', 'err');
    })['catch'](function (err) {
      saveBtn.disabled = false;
      showFormMessage(form, 'Не удалось сохранить: ' + err.message, 'err');
    });
  });
  return form;
}

export function renderUpdates() {
  stopProgressPolling();
  stopUpdateJobPolling();
  stopLogPolling();
  setLoading();
  var alive = viewGuard();
  // Настройки обновлений грузятся параллельно; их ошибка не ломает раздел -
  // просто не будет карточки «Настройки обновлений».
  var settingsReq = fetchJson('/api/settings')['catch'](function () { return null; });
  fetchJson('/api/updates/status').then(function (data) {
    return settingsReq.then(function (settings) { return [data, settings]; });
  }).then(function (pair) {
    var data = pair[0];
    var settings = pair[1];
    if (!alive()) { return; }
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
      fetchJson('/api/updates/check', { method: 'POST' }).then(function () { if (alive()) { renderUpdates(); } refreshUpdatesBadge(); })
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
    if (settings && settings.values) { app.appendChild(buildUpdateSettingsCard(settings.values)); }
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
  })['catch'](function (err) { if (alive()) { showError('Не удалось загрузить раздел обновлений: ', err); } });
}
