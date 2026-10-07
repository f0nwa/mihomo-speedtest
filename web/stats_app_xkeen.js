// Вкладка «XKeen» (/xkeen): кнопки команд XKeen с окном-консолью и
// редактор списков XKeen (исключения портов и адресов, xkeen.json).
//
// Кнопка открывает окно с описанием команды; на роутере она запускается
// только после «Отправить» (POST /api/xkeen/run?cmd=<ключ>). Вывод окно
// забирает опросом /api/xkeen/run-log с позиции next, пока команда идёт.
// Сервер (stats_xkeen.sh) принимает только ключи из своего списка -
// XKEEN_COMMANDS ниже должен с ним совпадать. Вывод выводится только через
// textContent, без innerHTML.

import { app, card, clearApp, el, fetchJson, viewGuard } from './app-core.js';

var XKEEN_COMMANDS = [
  { title: 'Установка', note: 'Первая установка XKeen и его компонентов. Во время установки XKeen задаёт вопросы - отвечайте в окне команды.', items: [
    { key: 'i', flag: '-i', desc: 'Основной режим установки XKeen + Xray + Mihomo + GeoFile/GeoIPSET.', ia: true },
    { key: 'i_auto', flag: '-i auto', desc: 'Автоустановка.', ia: true },
    { key: 'io', flag: '-io', desc: 'OffLine установка XKeen.', ia: true },
    { key: 'i_toff', flag: '-i -toff', desc: 'Отключение таймаута при медленной загрузке с GitHub (xkeen -i -toff).', ia: true },
    { key: 'health', flag: '-health', desc: 'Базовая проверка исправности Entware перед установкой XKeen.' }
  ] },
  { title: 'Переустановка', note: '', items: [
    { key: 'k', flag: '-k', desc: 'XKeen.', ia: true },
    { key: 'g', flag: '-g', desc: 'GeoFile.', ia: true },
    { key: 'gips', flag: '-gips', desc: 'GeoIPSET.', ia: true },
    { key: 'ri', flag: '-ri', desc: 'Пересоздать файл автозапуска XKeen в init.d.', ia: true }
  ] },
  { title: 'Обновление', note: '', items: [
    { key: 'uk', flag: '-uk', desc: 'XKeen.', ia: true },
    { key: 'ug', flag: '-ug', desc: 'GeoFile/GeoIPSET (списки сайтов и адресов по странам). Может идти несколько минут.' },
    { key: 'ux', flag: '-ux', desc: 'Xray (установка, повышение/понижение версии).', ia: true },
    { key: 'um', flag: '-um', desc: 'Mihomo (установка, повышение/понижение версии).', ia: true },
    { key: 'uy', flag: '-uy', desc: 'Yq (установка/обновление).', ia: true }
  ] },
  { title: 'Автообновление GeoFile/GeoIPSET', note: 'Запланированная задача, которая сама обновляет геобазы.', items: [
    { key: 'ugc', flag: '-ugc', desc: 'Создание задачи.', ia: true },
    { key: 'dgc', flag: '-dgc', desc: 'Удаление задачи.', ia: true }
  ] },
  { title: 'Резервная копия XKeen', note: '', items: [
    { key: 'kb', flag: '-kb', desc: 'Создание.' },
    { key: 'kbr', flag: '-kbr', desc: 'Восстановление.', ia: true }
  ] },
  { title: 'Резервная копия конфигурации Xray', note: '', items: [
    { key: 'xb', flag: '-xb', desc: 'Создание.' },
    { key: 'xbr', flag: '-xbr', desc: 'Восстановление.', ia: true }
  ] },
  { title: 'Резервная копия конфигурации Mihomo', note: '', items: [
    { key: 'mb', flag: '-mb', desc: 'Создание.' },
    { key: 'mbr', flag: '-mbr', desc: 'Восстановление.', ia: true }
  ] },
  { title: 'Удаление', note: 'Необратимые действия: перед выполнением XKeen спросит подтверждение.', items: [
    { key: 'remove', flag: '-remove', desc: 'Полная деинсталляция XKeen.', ia: true, danger: true },
    { key: 'dgs', flag: '-dgs', desc: 'GeoSite.', ia: true, danger: true },
    { key: 'dgi', flag: '-dgi', desc: 'GeoIP.', ia: true, danger: true },
    { key: 'dgips', flag: '-dgips', desc: 'GeoIPSET.', ia: true, danger: true },
    { key: 'dx', flag: '-dx', desc: 'Xray.', ia: true, danger: true },
    { key: 'dm', flag: '-dm', desc: 'Mihomo + Yq.', ia: true, danger: true },
    { key: 'dk', flag: '-dk', desc: 'XKeen.', ia: true, danger: true }
  ] },
  { title: 'Порты проксирования', note: 'Через прокси идут только эти порты (если список не пуст).', items: [
    { key: 'ap', flag: '-ap', desc: 'Добавить.', ia: true },
    { key: 'dp', flag: '-dp', desc: 'Удалить.', ia: true },
    { key: 'cp', flag: '-cp', desc: 'Посмотреть - какие порты проксируются, как их видит XKeen.' }
  ] },
  { title: 'Порты, исключённые из проксирования', note: 'Соединения на эти порты идут напрямую, мимо прокси.', items: [
    { key: 'ape', flag: '-ape', desc: 'Добавить.', ia: true },
    { key: 'dpe', flag: '-dpe', desc: 'Удалить.', ia: true },
    { key: 'cpe', flag: '-cpe', desc: 'Посмотреть - какие порты исключены, как их видит XKeen.' }
  ] },
  { title: 'Запуск и состояние прокси-клиента', note: '', items: [
    { key: 'status', flag: '-status', desc: 'Статус работы.' },
    { key: 'start', flag: '-start', desc: 'Запуск.' },
    { key: 'restart', flag: '-restart', desc: 'Перезапуск. Интернет через прокси пропадёт на 5-10 секунд.' },
    { key: 'stop', flag: '-stop', desc: 'Остановка: весь трафик пойдёт напрямую, мимо прокси, до запуска.', danger: true },
    { key: 'dscp', flag: '-dscp', desc: 'Статус маршрутизации по DSCP-меткам.' },
    { key: 'tp', flag: '-tp', desc: 'Порты, шлюз и протокол прокси-клиента.' },
    { key: 'cfd', flag: '-cfd', desc: 'Проверить количество файловых дескрипторов, открытых прокси-клиентом.' }
  ] },
  { title: 'Проверка и диагностика', note: '', items: [
    { key: 'diag', flag: '-diag', desc: 'Выполнить диагностику XKeen - её просит автор XKeen при сообщении о проблеме. Может идти несколько минут.' },
    { key: 'xtest', flag: '-xtest', desc: 'Проверить конфигурацию Xray на ошибки. Ничего не меняет.' },
    { key: 'mtest', flag: '-mtest', desc: 'Проверить конфигурацию Mihomo на ошибки. Ничего не меняет.' }
  ] },
  { title: 'Автозапуск и ожидания', note: '', items: [
    { key: 'auto', flag: '-auto', desc: 'Включить | Отключить автозапуск прокси-клиента.', ia: true },
    { key: 'di', flag: '-di', desc: 'Время ожидания инициализации роутера перед началом запуска прокси-клиента.', ia: true },
    { key: 'd', flag: '-d', desc: 'Время ожидания успешного запуска прокси-клиента.', ia: true },
    { key: 'fd', flag: '-fd', desc: 'Включить | Отключить контроль файловых дескрипторов прокси-клиента.', ia: true }
  ] },
  { title: 'Ядро и маршрутизация', note: '', items: [
    { key: 'xray', flag: '-xray', desc: 'Переключить XKeen на ядро Xray.', ia: true },
    { key: 'mihomo', flag: '-mihomo', desc: 'Переключить XKeen на ядро Mihomo.', ia: true },
    { key: 'channel', flag: '-channel', desc: 'Переключить канал получения обновлений XKeen (Stable/Dev версия).', ia: true },
    { key: 'ipv6', flag: '-ipv6', desc: 'Включить | Отключить протокол IPv6 в KeeneticOS.', ia: true },
    { key: 'dns', flag: '-dns', desc: 'Включить | Отключить перенаправление DNS в прокси.', ia: true },
    { key: 'pr', flag: '-pr', desc: 'Включить | Отключить проксирование трафика Entware через Xray/Mihomo.', ia: true }
  ] },
  { title: 'Режимы с параметром', note: 'Команды с готовым параметром: включить, выключить или посмотреть состояние.', items: [
    { key: 'sb_on', flag: '-sb on', desc: 'Балансировка outbound по фактической скорости: включить.' },
    { key: 'sb_off', flag: '-sb off', desc: 'Балансировка outbound по фактической скорости: выключить.' },
    { key: 'sb_status', flag: '-sb status', desc: 'Балансировка outbound по фактической скорости: состояние.' },
    { key: 'pbr_on', flag: '-pbr on', desc: 'Strict PBR-проверка mark / routing-mark для Xray/Mihomo: включить.' },
    { key: 'pbr_off', flag: '-pbr off', desc: 'Strict PBR-проверка mark / routing-mark для Xray/Mihomo: выключить.' },
    { key: 'pbr_status', flag: '-pbr status', desc: 'Strict PBR-проверка mark / routing-mark для Xray/Mihomo: состояние.' },
    { key: 'pbr_codes', flag: '-pbr codes', desc: 'Strict PBR-проверка mark / routing-mark для Xray/Mihomo: коды.' },
    { key: 'killswitch_on', flag: '-killswitch on', desc: 'Блокировать трафик policy xkeen при аварии ядра: включить.' },
    { key: 'killswitch_off', flag: '-killswitch off', desc: 'Блокировать трафик policy xkeen при аварии ядра: выключить.' },
    { key: 'killswitch_status', flag: '-killswitch status', desc: 'Блокировать трафик policy xkeen при аварии ядра: состояние.' }
  ] },
  { title: 'Сообщения и резервное копирование', note: '', items: [
    { key: 'startvb', flag: '-startvb', desc: 'Включить | Отключить вывод информации при старте прокси-клиента.', ia: true },
    { key: 'extmsg', flag: '-extmsg', desc: 'Включить | Отключить расширенные сообщения при запуске XKeen.', ia: true },
    { key: 'cbk', flag: '-cbk', desc: 'Включить | Отключить резервное копирование XKeen при обновлении.', ia: true },
    { key: 'aghfix', flag: '-aghfix', desc: 'Включить | Отключить отображение клиентов XKeen под своими IP в журнале AdGuard Home.', ia: true }
  ] },
  { title: 'Информация', note: '', items: [
    { key: 'about', flag: '-about', desc: 'О программе.' },
    { key: 'version', flag: '-v', desc: 'Версия XKeen.' },
    { key: 'ad', flag: '-ad', desc: 'Поддержать разработчиков.' },
    { key: 'af', flag: '-af', desc: 'Обратная связь.' }
  ] }
];

var POLL_MS = 1000;
var pollTimer = null;
var dlg = null;

export function stopXkeenPolling() {
  xk = null;
  if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
  if (dlg) {
    if (dlg.node.open) { dlg.node.close(); }
    if (dlg.node.parentNode) { dlg.node.parentNode.removeChild(dlg.node); }
    dlg = null;
  }
}

export function renderXkeen() {
  clearApp();
  var c = card('Команды XKeen');
  c.appendChild(el('p', 'hint', 'Каждая кнопка выполняет одну команду XKeen на роутере. ' +
    'Сначала откроется окно с описанием, команда пойдёт только после «Отправить». ' +
    'Если команда задаёт вопросы, отвечайте на них в этом же окне.'));
  XKEEN_COMMANDS.forEach(function (group) {
    var box = el('div', 'xk-group');
    box.appendChild(el('h3', 'xk-group-title', group.title));
    if (group.note) { box.appendChild(el('p', 'hint', group.note)); }
    var rows = el('div', 'xk-cmds');
    group.items.forEach(function (cmd) {
      var row = el('div', 'xk-cmd' + (cmd.danger ? ' danger' : ''));
      row.appendChild(el('code', 'xk-flag', cmd.flag));
      row.appendChild(el('span', 'xk-cdesc', cmd.desc));
      var b = el('button', 'theme-btn xk-btn' + (cmd.danger ? ' danger' : ''), 'Выполнить');
      b.type = 'button';
      b.setAttribute('aria-label', 'xkeen ' + cmd.flag + ' - ' + cmd.desc);
      b.addEventListener('click', function () { openDialog(cmd, group); });
      row.appendChild(b);
      rows.appendChild(row);
    });
    box.appendChild(rows);
    c.appendChild(box);
  });
  app.appendChild(c);
  renderLists();
}

// ----- окно-консоль -----

function openDialog(cmd, group) {
  stopXkeenPolling();
  var d = el('dialog', 'xk-dialog');
  var head = el('div', 'xk-head');
  head.appendChild(el('b', null, 'xkeen ' + cmd.flag));
  head.appendChild(el('span', 'hint', group.title));
  var status = el('span', 'xk-status');
  head.appendChild(status);
  var closeX = el('button', 'xk-x', '✕');
  closeX.type = 'button';
  closeX.setAttribute('aria-label', 'Закрыть');
  head.appendChild(closeX);
  d.appendChild(head);
  d.appendChild(el('div', 'xk-about', cmd.desc + (cmd.ia ? ' Команда может задавать вопросы - отвечайте в поле под выводом.' : '')));
  var pre = el('div', 'update-console xk-console');
  d.appendChild(pre);
  var foot = el('div', 'xk-foot');
  d.appendChild(foot);
  document.body.appendChild(d);
  dlg = { node: d, cmd: cmd, pre: pre, status: status, foot: foot, closeX: closeX, busy: false, text: '' };
  closeX.addEventListener('click', function () { if (!dlg.busy) { stopXkeenPolling(); } });
  // Esc не закрывает окно, пока команда идёт.
  d.addEventListener('cancel', function (e) {
    if (dlg && dlg.busy) { e.preventDefault(); } else { e.preventDefault(); stopXkeenPolling(); }
  });
  showReady();
  d.showModal();
}

// Вывод приходит кусками: последняя строка может быть без перевода строки
// (вопрос "Введите порт: ") - она остаётся открытой и продолжается
// следующим куском или ответом пользователя.
function addText(text) {
  var parts = text.replace(/\r\n?/g, '\n').split('\n');
  parts.forEach(function (p, i) {
    var last = i === parts.length - 1;
    if (!dlg.partial) {
      if (last && p === '') { return; }
      dlg.partial = line('', '');
    }
    var n = dlg.partial;
    n.textContent = (n.textContent === ' ' ? '' : n.textContent) + p;
    if (/^--- /.test(n.textContent)) { n.className = 'log-line err'; }
    if (!last) {
      if (n.textContent === '') { n.textContent = ' '; }
      dlg.partial = null;
    }
  });
  dlg.pre.scrollTop = dlg.pre.scrollHeight;
}

function line(text, cls) {
  var n = el('div', 'log-line' + (cls ? ' ' + cls : ''), text === '' ? ' ' : text);
  dlg.pre.appendChild(n);
  dlg.pre.scrollTop = dlg.pre.scrollHeight;
  return n;
}

// Поле ответа: Enter или «Ввод» отправляет строку в stdin команды.
function buildInput() {
  var cur = dlg;
  var row = el('div', 'xk-input');
  var inp = el('input');
  inp.type = 'text';
  inp.placeholder = 'Ответ команде и Enter';
  inp.maxLength = 500;
  inp.autocomplete = 'off';
  inp.setAttribute('aria-label', 'Ответ команде XKeen');
  var sendLine = function (text) {
    if (dlg !== cur || !cur.id || !cur.busy) { return; }
    var echo = cur.partial || line('', 'xk-in');
    cur.partial = null;
    echo.textContent = (echo.textContent === ' ' ? '' : echo.textContent) + text;
    echo.className = 'log-line xk-in';
    cur.pre.scrollTop = cur.pre.scrollHeight;
    fetchJson('/api/xkeen/input?id=' + encodeURIComponent(cur.id), { method: 'POST', body: text, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })
      .then(null, function (err) {
        if (dlg !== cur) { return; }
        line('Ответ не доставлен: ' + ((err && err.data && err.data.message) || (err && err.message) || err), 'err');
      });
  };
  var go = function () { var t = inp.value; inp.value = ''; sendLine(t); inp.focus(); };
  inp.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); go(); }
  });
  row.appendChild(inp);
  var ok = el('button', 'submit', 'Ввод');
  ok.type = 'button';
  ok.addEventListener('click', go);
  row.appendChild(ok);
  [['y', 'y'], ['n', 'n']].forEach(function (q) {
    var b = el('button', 'submit secondary', q[0]);
    b.type = 'button';
    b.title = 'Отправить «' + q[1] + '»';
    b.addEventListener('click', function () { sendLine(q[1]); inp.focus(); });
    row.appendChild(b);
  });
  setTimeout(function () { inp.focus(); }, 0);
  return row;
}

function cancelRun() {
  var cur = dlg;
  if (!cur || !cur.id) { return; }
  fetchJson('/api/xkeen/cancel?id=' + encodeURIComponent(cur.id), { method: 'POST' }).then(null, function (err) {
    if (dlg !== cur) { return; }
    line('Не удалось прервать: ' + ((err && err.data && err.data.message) || (err && err.message) || err), 'err');
  });
}

function button(label, cls, onClick) {
  var b = el('button', cls, label);
  b.type = 'button';
  b.addEventListener('click', onClick);
  dlg.foot.appendChild(b);
  return b;
}

function clearFoot() { while (dlg.foot.firstChild) { dlg.foot.removeChild(dlg.foot.firstChild); } }

function showReady() {
  dlg.pre.textContent = '';
  dlg.text = '';
  dlg.partial = null;
  dlg.status.textContent = '';
  dlg.status.className = 'xk-status';
  line('~ # xkeen ' + dlg.cmd.flag, 'xk-prompt');
  clearFoot();
  dlg.foot.appendChild(el('span', 'xk-grow'));
  button('Отмена', 'submit secondary', function () { stopXkeenPolling(); });
  var send = button('Отправить ⏎', 'submit', send_);
  send.focus();
}

function setBusy(busy) {
  dlg.busy = busy;
  dlg.closeX.disabled = busy;
}

function send_() {
  var cur = dlg;
  setBusy(true);
  clearFoot();
  var note = el('span', 'hint xk-grow', 'Команда отправлена...');
  var inputRow = cur.cmd.ia ? buildInput() : null;
  if (inputRow) { dlg.foot.appendChild(inputRow); }
  dlg.foot.appendChild(note);
  button('Прервать', 'submit secondary', cancelRun);
  fetchJson('/api/xkeen/run?cmd=' + encodeURIComponent(cur.cmd.key), { method: 'POST' }).then(function (data) {
    if (dlg !== cur) { return; }
    cur.id = data.id;
    cur.next = 0;
    cur.note = note;
    cur.partial = null;
    poll();
  }, function (err) {
    if (dlg !== cur) { return; }
    setBusy(false);
    var msg = err && err.status === 409
      ? 'Сейчас уже выполняется команда XKeen или применяется конфиг - попробуйте позже.'
      : 'Не удалось запустить: ' + ((err && err.data && err.data.message) || (err && err.message) || err);
    line(msg, 'err');
    showDone(null, null);
  });
}

function poll() {
  var cur = dlg;
  pollTimer = null;
  fetchJson('/api/xkeen/run-log?id=' + encodeURIComponent(cur.id) + '&from=' + cur.next).then(function (data) {
    if (dlg !== cur) { return; }
    if (data.stale) {
      setBusy(false);
      line('Вывод этой команды уже недоступен: на роутере запущена другая.', 'err');
      showDone(null, null);
      return;
    }
    if (data.text) {
      cur.text += data.text;
      addText(String(data.text));
    }
    cur.next = data.next;
    if (data.running) {
      cur.note.textContent = 'Выполняется ' + data.seconds + ' с. Окно можно будет закрыть после завершения.';
      pollTimer = setTimeout(poll, POLL_MS);
      return;
    }
    setBusy(false);
    showDone(data.exit, data.seconds);
  }, function () {
    if (dlg !== cur) { return; }
    // Обрыв связи: повторяем с того же места.
    pollTimer = setTimeout(poll, POLL_MS * 3);
  });
}

function showDone(code, seconds) {
  if (code !== null && code !== undefined) {
    line('[процесс завершён с кодом ' + code + ']', 'sep');
    if (code === 0) {
      dlg.status.textContent = '✓ готово за ' + seconds + ' с · код 0';
      dlg.status.className = 'xk-status ok';
    } else {
      dlg.status.textContent = (code === 124 ? 'остановлено по таймауту' : 'ошибка, код ' + code) + ' · ' + seconds + ' с';
      dlg.status.className = 'xk-status err';
    }
  }
  clearFoot();
  button('Скопировать вывод', 'submit secondary', copyOutput);
  dlg.foot.appendChild(el('span', 'xk-grow'));
  button('Выполнить ещё раз', 'submit secondary', showReady);
  button('Закрыть', 'submit', function () { stopXkeenPolling(); }).focus();
}

function copyOutput() {
  copyText('~ # xkeen ' + dlg.cmd.flag + '\n' + dlg.text, dlg.node);
}

// host - куда временно вставить textarea (внутри открытого <dialog>,
// иначе выделение вне модального окна не работает).
function copyText(text, host) {
  var fallback = function () {
    // Панель открыта по http - clipboard API там может быть недоступен.
    var ta = el('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    host.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* нечего делать */ }
    host.removeChild(ta);
  };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(null, fallback);
  } else {
    fallback();
  }
}

// ===== Списки XKeen (/api/xkeen, save, backups, restore, log) =====
//
// Файл разбирается построчно в строки-объекты {type, value, raw, err}:
//   entry - запись (порт или адрес), off - "#" + запись (выключена),
//   note  - прочая строка с "#" (заголовок, пояснение), blank - пустая,
//   bad   - строка, которую XKeen не поймёт.
// raw - строка как она будет записана: неизменённые строки сохраняются
// байт в байт, порядок не меняется. Проверка формата повторяет
// validate_lines() в stats_xkeen.sh; сервер всё равно проверяет заново.

var LISTS = [
  { key: 'port_exclude', title: 'Исключённые порты', kind: 'port', placeholder: 'порт или диапазон',
    help: 'Соединения на эти порты идут напрямую, мимо прокси. Один порт (22) или диапазон через двоеточие (5000:5100).' },
  { key: 'port_proxying', title: 'Порты проксирования', kind: 'port', placeholder: 'порт или диапазон',
    help: 'Обратный режим: через прокси идут только эти порты (обычно 80 и 443), всё остальное напрямую. Один порт или диапазон через двоеточие (596:599).' },
  { key: 'ip_exclude', title: 'Исключённые адреса и подсети', kind: 'ip', placeholder: 'адрес или подсеть', wide: true,
    help: 'Трафик к этим адресам идёт напрямую. Один адрес (77.88.8.8) или подсеть с маской (10.0.0.0/8); IPv6 тоже подходит (2001:db8::/32).' }
];

var xk = null; // состояние вкладки: files, json, cards, bar, apply, msg, saving

// Режим карточки списка: 'list' (записи с галочками) или 'text' (файл
// целиком в одном поле - удобно скопировать или вставить с другого роутера).
// Живёт, пока открыта панель.
var listModes = {};

export function xkeenDirty() {
  if (!xk || !xk.files) { return false; }
  return dirtyKeys().length > 0;
}

function portOk(v) { return /^[0-9]+$/.test(v) && +v >= 1 && +v <= 65535; }

function checkPort(t) {
  if (/^[0-9]+$/.test(t)) { return portOk(t) ? '' : 'порт должен быть от 1 до 65535'; }
  var m = /^([0-9]+):([0-9]+)$/.exec(t);
  if (m) {
    if (!portOk(m[1]) || !portOk(m[2])) { return 'порт должен быть от 1 до 65535'; }
    if (+m[1] > +m[2]) { return 'в диапазоне N:M начало больше конца'; }
    return '';
  }
  return 'ожидается порт (22) или диапазон через двоеточие (596:599)';
}

function v4ok(s) {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(s)) { return false; }
  return s.split('.').every(function (p) { return p.length <= 3 && +p <= 255; });
}

function v6ok(s) {
  if (!/^[0-9A-Fa-f:]+$/.test(s) || s.indexOf(':') < 0 || /:::/.test(s)) { return false; }
  var dbl = s.split('::').length - 1;
  if (dbl > 1) { return false; }
  var g = s.split(':');
  if (g.some(function (x) { return x.length > 4; })) { return false; }
  var cnt = g.filter(function (x) { return x !== ''; }).length;
  return dbl === 0 ? (g.length === 8 && cnt === 8) : cnt <= 7;
}

function checkIp(t) {
  var p = t.indexOf('/');
  var addr = p >= 0 ? t.slice(0, p) : t;
  var mask = p >= 0 ? t.slice(p + 1) : null;
  var max;
  if (v4ok(addr)) { max = 32; } else if (v6ok(addr)) { max = 128; } else { return 'ожидается адрес IPv4/IPv6 или подсеть (10.0.0.0/8)'; }
  if (mask !== null && (!/^[0-9]+$/.test(mask) || +mask > max)) { return 'маска подсети должна быть от 0 до ' + max; }
  return '';
}

function checkValue(kind, t) { return kind === 'port' ? checkPort(t) : checkIp(t); }

function parseRows(text, kind) {
  var lines = text.split('\n');
  if (lines.length && lines[lines.length - 1] === '') { lines.pop(); }
  return lines.map(function (raw) {
    var t = raw.replace(/\r$/, '').trim();
    if (t === '') { return { type: 'blank', raw: raw }; }
    if (t.charAt(0) === '#') {
      var rest = t.slice(1).trim();
      if (rest && !checkValue(kind, rest)) { return { type: 'off', value: rest, raw: raw }; }
      return { type: 'note', raw: raw };
    }
    var err = checkValue(kind, t);
    return err ? { type: 'bad', value: t, raw: raw, err: err } : { type: 'entry', value: t, raw: raw };
  });
}

function fileText(f) {
  var body = f.rows.map(function (r) { return r.raw; }).join('\n');
  return f.rows.length ? body + (f.trailing ? '\n' : '') : '';
}

function dirtyKeys() {
  var out = [];
  LISTS.forEach(function (d) { if (fileText(xk.files[d.key]) !== xk.files[d.key].orig) { out.push(d.key); } });
  if (xk.json.text !== xk.json.orig) { out.push('xkeen_json'); }
  return out;
}

function jsonError(text) {
  if (!text.trim()) { return ''; }
  try { JSON.parse(text); return ''; } catch (e) { return e.message; }
}

function hasErrors() {
  var bad = LISTS.some(function (d) {
    return xk.files[d.key].rows.some(function (r) { return r.type === 'bad' || r.err; });
  });
  return bad || !!jsonError(xk.json.text);
}

function loadFiles(data) {
  xk.files = {};
  LISTS.forEach(function (d) {
    var src = (data.files && data.files[d.key]) || { text: '', base: 'none', name: d.key };
    var text = src.text || '';
    xk.files[d.key] = { name: src.name, base: src.base, orig: text, trailing: text === '' || /\n$/.test(text), rows: parseRows(text, d.kind) };
  });
  var j = (data.files && data.files.xkeen_json) || { text: '', base: 'none' };
  xk.json = { base: j.base, orig: j.text || '', text: j.text || '' };
}

function renderLists() {
  var guard = viewGuard();
  var root = el('div');
  app.appendChild(root);
  root.appendChild(el('p', 'hint', 'Загрузка списков XKeen...'));
  fetchJson('/api/xkeen').then(function (data) {
    if (!guard()) { return; }
    xk = { cards: {} };
    loadFiles(data);
    while (root.firstChild) { root.removeChild(root.firstChild); }
    buildLists(root);
  }, function (err) {
    if (!guard()) { return; }
    root.textContent = '';
    root.appendChild(el('p', 'msg-err', 'Не удалось прочитать списки XKeen: ' + (err && err.message ? err.message : err)));
  });
}

function buildLists(root) {
  var intro = card('Что идёт мимо прокси');
  intro.appendChild(el('p', 'hint', 'Здесь задаётся, какой трафик XKeen не отправляет через прокси. Каждый список - файл в /opt/etc/xkeen/. ' +
    'Строки с # - заголовки или выключенные записи, они сохраняются как есть. После сохранения XKeen перезапустится (5-10 с); ' +
    'если ядро не поднимется, прежние файлы вернутся сами.'));
  root.appendChild(intro);
  xk.msg = el('div');
  root.appendChild(xk.msg);
  var grid = el('div', 'xk-grid');
  root.appendChild(grid);
  LISTS.forEach(function (d) {
    var c = el('section', 'card xk-list' + (d.wide ? ' wide' : ''));
    xk.cards[d.key] = c;
    grid.appendChild(c);
    drawCard(d);
  });
  root.appendChild(buildJson());
  xk.backups = el('div');
  root.appendChild(xk.backups);
  xk.apply = el('div', 'card');
  xk.apply.hidden = true;
  root.appendChild(xk.apply);
  xk.bar = el('div', 'card xk-savebar');
  root.appendChild(xk.bar);
  drawBar();
}

function drawCard(d) {
  var c = xk.cards[d.key];
  var f = xk.files[d.key];
  while (c.firstChild) { c.removeChild(c.firstChild); }
  var head = el('div', 'xk-list-head');
  head.appendChild(el('h2', null, d.title));
  var count = el('span', 'hint xk-grow', countText(f));
  head.appendChild(count);
  head.appendChild(modeSwitch(d));
  c.appendChild(head);
  c.appendChild(el('p', 'hint', d.help));
  if (d.key === 'port_exclude') {
    var prox = xk.files.port_proxying.rows.some(function (r) { return r.type === 'entry'; });
    if (prox) {
      c.appendChild(el('div', 'xk-warn', 'Сейчас заполнены «Порты проксирования» - XKeen учитывает только их, этот список не действует. Используйте что-то одно.'));
    }
  }
  if (listModes[d.key] === 'text') { drawText(d, f, c, count); return; }
  var list = el('div', 'xk-rows');
  f.rows.forEach(function (r, i) {
    if (r.type === 'blank') { return; }
    list.appendChild(drawRow(d, f, r, i));
  });
  if (!f.rows.some(function (r) { return r.type !== 'blank'; })) {
    list.appendChild(el('div', 'xk-empty', 'Список пуст'));
  }
  c.appendChild(list);
  var add = el('div', 'xk-add');
  var inp = el('input');
  inp.type = 'text';
  inp.placeholder = d.placeholder;
  inp.setAttribute('aria-label', 'Новая запись: ' + d.title);
  var addErr = el('div', 'xk-err');
  var addBtn = el('button', 'submit secondary', '+ Добавить');
  addBtn.type = 'button';
  var doAdd = function () {
    var v = inp.value.trim();
    if (!v) { return; }
    var err = checkValue(d.kind, v);
    if (err) { addErr.textContent = err; inp.classList.add('input-err'); return; }
    var at = -1;
    f.rows.forEach(function (r, i) { if (r.type === 'entry' || r.type === 'off') { at = i; } });
    f.rows.splice(at >= 0 ? at + 1 : f.rows.length, 0, { type: 'entry', value: v, raw: v });
    changed(d);
    var again = xk.cards[d.key].querySelector('.xk-add input');
    if (again) { again.focus(); }
  };
  addBtn.addEventListener('click', doAdd);
  inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); doAdd(); } });
  inp.addEventListener('input', function () { addErr.textContent = ''; inp.classList.remove('input-err'); });
  add.appendChild(inp);
  add.appendChild(addBtn);
  c.appendChild(add);
  c.appendChild(addErr);
}

function countText(f) {
  var on = f.rows.filter(function (r) { return r.type === 'entry'; }).length;
  return f.name + ' · включено ' + on;
}

function modeSwitch(d) {
  var box = el('div', 'xk-mode');
  box.setAttribute('role', 'group');
  box.setAttribute('aria-label', 'Вид списка');
  [['list', 'Список'], ['text', 'Текст']].forEach(function (m) {
    var b = el('button', null, m[1]);
    b.type = 'button';
    var cur = (listModes[d.key] || 'list') === m[0];
    b.setAttribute('aria-pressed', cur ? 'true' : 'false');
    b.title = m[0] === 'text' ? 'Весь файл одним текстом - скопировать или вставить целиком' : 'Записи по одной, с галочками';
    b.addEventListener('click', function () {
      if (cur) { return; }
      listModes[d.key] = m[0];
      drawCard(d);
    });
    box.appendChild(b);
  });
  return box;
}

// Текстовый режим: файл целиком. Каждое изменение разбирается теми же
// parseRows(), так что ошибки, счётчик и сохранение работают как в списке.
// Карточку не перерисовываем при вводе - иначе пропадёт курсор.
function drawText(d, f, c, count) {
  var ta = el('textarea', 'xk-json xk-text');
  ta.rows = Math.min(Math.max(f.rows.length + 1, 6), 20);
  ta.spellcheck = false;
  ta.wrap = 'off';
  ta.value = fileText(f);
  ta.placeholder = 'По одной записи в строке. # в начале - выключено или пояснение.';
  ta.setAttribute('aria-label', d.title + ' - текст файла');
  c.appendChild(ta);
  var errs = el('div');
  c.appendChild(errs);
  var showErrs = function () {
    while (errs.firstChild) { errs.removeChild(errs.firstChild); }
    var bad = 0;
    f.rows.forEach(function (r, i) {
      if (!r.err) { return; }
      bad += 1;
      if (bad <= 5) { errs.appendChild(el('div', 'xk-err', 'Строка ' + (i + 1) + ' «' + (r.value || r.raw) + '»: ' + r.err)); }
    });
    if (bad > 5) { errs.appendChild(el('div', 'xk-err', '...и ещё строк с ошибками: ' + (bad - 5))); }
    ta.classList.toggle('input-err', bad > 0);
  };
  showErrs();
  ta.addEventListener('input', function () {
    f.rows = parseRows(ta.value, d.kind);
    f.trailing = ta.value === '' || /\n$/.test(ta.value);
    count.textContent = countText(f);
    showErrs();
    if (d.key === 'port_proxying') { drawCard(LISTS[0]); }
    drawBar();
  });
  var foot = el('div', 'xk-add');
  foot.appendChild(el('span', 'hint xk-grow', 'Можно вставить список целиком - например, скопированный с другого роутера.'));
  var cp = el('button', 'submit secondary', 'Скопировать');
  cp.type = 'button';
  cp.addEventListener('click', function () {
    copyText(ta.value, c);
    cp.textContent = 'Скопировано ✓';
    setTimeout(function () { cp.textContent = 'Скопировать'; }, 1500);
  });
  foot.appendChild(cp);
  c.appendChild(foot);
}

function drawRow(d, f, r, i) {
  var row = el('div', 'xk-row ' + r.type);
  var del = el('button', 'xk-x', '✕');
  del.type = 'button';
  if (r.type === 'note') {
    var note = el('input', 'xk-note');
    note.type = 'text';
    note.value = r.raw;
    note.setAttribute('aria-label', 'Заголовок или пояснение');
    note.addEventListener('change', function () {
      var v = note.value.replace(/^\s+/, '');
      r.raw = v.charAt(0) === '#' ? v : '#' + v;
      changed(d);
    });
    row.appendChild(el('span', 'xk-cb'));
    row.appendChild(note);
    del.setAttribute('aria-label', 'Удалить строку');
  } else {
    var cb = el('input');
    cb.type = 'checkbox';
    cb.checked = r.type !== 'off';
    cb.disabled = r.type === 'bad';
    cb.title = 'Включено';
    cb.setAttribute('aria-label', 'Включить ' + (r.value || ''));
    cb.addEventListener('change', function () {
      r.type = cb.checked ? 'entry' : 'off';
      r.raw = (cb.checked ? '' : '#') + r.value;
      changed(d);
    });
    var val = el('input', 'xk-val' + (r.err ? ' input-err' : ''));
    val.type = 'text';
    val.value = r.type === 'bad' ? r.raw : r.value;
    val.setAttribute('aria-label', 'Значение');
    val.addEventListener('change', function () {
      var v = val.value.trim();
      if (!v) { f.rows.splice(i, 1); changed(d); return; }
      var err = checkValue(d.kind, v);
      var off = r.type === 'off';
      r.value = v;
      r.raw = (off ? '#' : '') + v;
      r.err = err || '';
      r.type = err ? (off ? 'off' : 'bad') : (off ? 'off' : 'entry');
      changed(d);
    });
    row.appendChild(cb);
    row.appendChild(val);
    del.setAttribute('aria-label', 'Удалить ' + (r.value || 'строку'));
  }
  del.addEventListener('click', function () { f.rows.splice(i, 1); changed(d); });
  row.appendChild(del);
  var wrap = el('div');
  wrap.appendChild(row);
  if (r.err) { wrap.appendChild(el('div', 'xk-err', r.err)); }
  return wrap;
}

function changed(d) {
  drawCard(d);
  if (d.key === 'port_proxying') { drawCard(LISTS[0]); }
  drawBar();
}

function buildJson() {
  var det = el('details', 'card');
  det.appendChild(el('summary', null, 'Основные настройки XKeen (xkeen.json) - для опытных'));
  det.appendChild(el('p', 'hint', 'Файл /opt/etc/xkeen/xkeen.json целиком. Меняйте, только если знаете ключ из документации XKeen. Пустой файл допустим.'));
  var ta = el('textarea', 'xk-json');
  ta.rows = 8;
  ta.spellcheck = false;
  ta.value = xk.json.text;
  ta.setAttribute('aria-label', 'xkeen.json');
  var st = el('div', 'hint');
  var upd = function () {
    xk.json.text = ta.value;
    var err = jsonError(ta.value);
    st.textContent = err ? 'Ошибка JSON: ' + err : (ta.value.trim() ? '✓ JSON корректен' : 'Файл пуст');
    st.className = err ? 'xk-err' : 'hint';
    ta.classList.toggle('input-err', !!err);
    drawBar();
  };
  ta.addEventListener('input', upd);
  det.appendChild(ta);
  det.appendChild(st);
  xk.jsonArea = ta;
  xk.jsonSync = upd;
  return det;
}

function drawBar() {
  if (!xk || !xk.bar) { return; }
  var b = xk.bar;
  while (b.firstChild) { b.removeChild(b.firstChild); }
  var keys = dirtyKeys();
  var errs = hasErrors();
  var txt = xk.saving ? 'Применяю, не закрывайте страницу...' :
    keys.length ? ('Не сохранено файлов: ' + keys.length + (errs ? ' · есть ошибки, сохранение недоступно' : '')) :
    (errs ? 'В файлах есть строки с ошибками' : 'Изменений нет');
  b.appendChild(el('span', 'hint xk-grow', txt));
  var bk = el('button', 'submit secondary', 'Бэкапы');
  bk.type = 'button';
  bk.disabled = !!xk.saving;
  bk.addEventListener('click', toggleBackups);
  b.appendChild(bk);
  var undo = el('button', 'submit secondary', 'Отменить правки');
  undo.type = 'button';
  undo.disabled = !keys.length || !!xk.saving;
  undo.addEventListener('click', function () {
    if (!window.confirm('Отменить все несохранённые правки?')) { return; }
    reloadLists();
  });
  b.appendChild(undo);
  var save = el('button', 'submit', 'Сохранить и перезапустить XKeen');
  save.type = 'button';
  save.disabled = !keys.length || errs || !!xk.saving;
  save.addEventListener('click', function () { saveLists(keys); });
  b.appendChild(save);
}

function reloadLists(msgNode) {
  var guard = viewGuard();
  return fetchJson('/api/xkeen').then(function (data) {
    if (!guard() || !xk) { return; }
    loadFiles(data);
    LISTS.forEach(drawCard);
    if (xk.jsonArea) { xk.jsonArea.value = xk.json.text; xk.jsonSync(); }
    drawBar();
    setMsg(msgNode || null);
  });
}

function setMsg(node) {
  while (xk.msg.firstChild) { xk.msg.removeChild(xk.msg.firstChild); }
  if (node) { xk.msg.appendChild(node); xk.msg.scrollIntoView({ block: 'nearest' }); }
}

// Журнал применения: опрос /api/xkeen/log, пока идёт запрос сохранения.
// Возвращает функцию остановки - она ещё раз дочитывает журнал.
function startApplyLog() {
  var a = xk.apply;
  a.hidden = false;
  while (a.firstChild) { a.removeChild(a.firstChild); }
  a.appendChild(el('h2', null, 'Журнал применения'));
  var pre = el('div', 'update-console config-apply-log');
  a.appendChild(pre);
  var timer = null;
  var load = function () {
    return fetchJson('/api/xkeen/log').then(function (data) {
      pre.textContent = '';
      String(data.text || '').split('\n').forEach(function (l) {
        if (l) { pre.appendChild(el('div', 'log-line' + (/ОШИБКА/.test(l) ? ' err' : /ГОТОВО/.test(l) ? ' ok' : ''), l)); }
      });
      pre.scrollTop = pre.scrollHeight;
    }, function () {});
  };
  var tick = function () { load().then(function () { if (timer !== false) { timer = setTimeout(tick, 1000); } }); };
  tick();
  return function () { if (timer) { clearTimeout(timer); } timer = false; load(); };
}

function bodyFor(keys) {
  return keys.map(function (k) {
    var text = k === 'xkeen_json' ? xk.json.text : fileText(xk.files[k]);
    var base = k === 'xkeen_json' ? xk.json.base : xk.files[k].base;
    if (text !== '' && !/\n$/.test(text)) { text += '\n'; }
    return '### MST-FILE ' + k + ' ' + base + '\n' + text;
  }).join('');
}

function applyRequest(url, body, okText) {
  var guard = viewGuard();
  xk.saving = true;
  drawBar();
  setMsg(null);
  var stopLog = startApplyLog();
  var opts = { method: 'POST' };
  if (body !== null) { opts.body = body; opts.headers = { 'Content-Type': 'text/plain; charset=utf-8' }; }
  return fetchJson(url, opts).then(function (data) {
    stopLog();
    if (!guard() || !xk) { return; }
    xk.saving = false;
    var text = data.unchanged ? 'Файлы не изменились - перезапуск не понадобился.' :
      data.restarted === false ? 'Файлы записаны, но XKeen не найден - перезапустите его вручную.' : okText;
    return reloadLists(el('p', 'msg-ok', text));
  }, function (err) {
    stopLog();
    if (!guard() || !xk) { return; }
    xk.saving = false;
    var d = (err && err.data) || {};
    if (d.error === 'invalid' && d.errors) {
      d.errors.forEach(function (e) {
        var f = xk.files[e.key];
        var r = f && f.rows[e.line - 1];
        if (r) { r.err = e.reason; }
      });
      LISTS.forEach(drawCard);
      drawBar();
      setMsg(el('p', 'msg-err', 'Сервер нашёл ошибки в строках - они подсвечены. Ничего не записано.'));
      return;
    }
    var msg = d.error === 'conflict' ? 'Файл изменили на роутере, пока вкладка была открыта. Обновите страницу - ваши правки не записаны.' :
      d.error === 'busy' ? 'Сейчас уже выполняется команда XKeen или применяется конфиг - попробуйте через минуту.' :
      d.error === 'restart_failed' ? (d.rolled_back ? 'Ядро не поднялось с новыми списками - прежние файлы возвращены, XKeen перезапущен.' :
        'Ядро не поднялось, и откат не удался - проверьте XKeen по SSH.') :
      'Не удалось сохранить: ' + (d.message || (err && err.message) || err);
    drawBar();
    if (d.error === 'restart_failed') { return reloadLists(el('p', 'msg-err', msg)); }
    setMsg(el('p', 'msg-err', msg));
  });
}

function saveLists(keys) {
  if (!keys.length || hasErrors()) { return; }
  applyRequest('/api/xkeen/save', bodyFor(keys), 'Сохранено, XKeen перезапущен.');
}

function toggleBackups() {
  var box = xk.backups;
  if (box.firstChild) { while (box.firstChild) { box.removeChild(box.firstChild); } return; }
  var c = card('Бэкапы списков');
  c.appendChild(el('p', 'hint', 'Перед каждым сохранением прежние файлы копируются сюда. «Вернуть» записывает файлы бэкапа и перезапускает XKeen.'));
  var list = el('div', 'xk-rows');
  c.appendChild(list);
  box.appendChild(c);
  fetchJson('/api/xkeen/backups').then(function (data) {
    if (!data.backups || !data.backups.length) { list.appendChild(el('div', 'xk-empty', 'Бэкапов пока нет')); return; }
    c.appendChild(el('p', 'hint', 'Хранятся последние ' + data.keep + '.'));
    data.backups.forEach(function (b) {
      var row = el('div', 'xk-row');
      var when = b.name.replace(/^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(\d{2}).*$/, '$3.$2.$1 $4:$5:$6');
      row.appendChild(el('span', 'xk-grow', when + ' · ' + (b.files.length ? b.files.join(', ') : 'только новые файлы')));
      var btn = el('button', 'submit secondary', 'Вернуть');
      btn.type = 'button';
      btn.disabled = !b.files.length;
      btn.addEventListener('click', function () {
        if (xkeenDirty() && !window.confirm('Несохранённые правки пропадут. Продолжить?')) { return; }
        if (!window.confirm('Вернуть файлы из бэкапа ' + when + ' и перезапустить XKeen?')) { return; }
        while (box.firstChild) { box.removeChild(box.firstChild); }
        applyRequest('/api/xkeen/restore?name=' + encodeURIComponent(b.name), null, 'Файлы из бэкапа возвращены, XKeen перезапущен.');
      });
      row.appendChild(btn);
      list.appendChild(row);
    });
  }, function (err) {
    list.appendChild(el('p', 'msg-err', 'Не удалось получить список: ' + (err && err.message ? err.message : err)));
  });
}
