// Веб-интерфейс mihomo-speedtest: точка входа (ES-модуль, без сборки).
// Клиентский роутер (меню, history API), футер, вход и выход.
// Разделы - в соседних модулях app-*.js; все файлы ставит install.sh как
// $DIR/stats_app*.js, stats_httpd.py раздаёт их как /app.js и /app-*.js.
//
// Порядок модулей не важен: модули ссылаются друг на друга только внутри
// функций, состояние общее только через session (app-core.js),
// configDirty()/leaveConfig() (app-config.js) и экспортируемые функции.

import { app, card, clearApp, el, fetchJson, logoutBtn, mainNav, nextView, session, setLoading, setUnauthorizedHandler, showError, showFormMessage } from './app-core.js';
import { renderStats, stopProgressPolling } from './app-stats.js';
import { renderSettings } from './app-settings.js';
import { refreshUpdatesBadge, renderUpdates, stopUpdateJobPolling } from './app-updates.js';
import { renderLog, stopLogPolling } from './app-log.js';
import { configDirty, leaveConfig, renderConfig } from './app-config.js';
import { renderXkeen, stopXkeenPolling, xkeenDirty } from './app-xkeen.js';

function updateActiveNav(path) {
  var links = document.querySelectorAll('nav a[data-link]');
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute('href');
    var isActive = href === path || (path === '/' && href === '/stats');
    links[i].classList.toggle('active', isActive);
  }
}

function navigate(path) {
  // Несохранённые правки на вкладке "Конфиг".
  if (configDirty() && path !== location.pathname &&
      !window.confirm('В редакторе конфига есть несохранённые изменения. Уйти со страницы?')) { return; }
  if (xkeenDirty() && path !== location.pathname &&
      !window.confirm('В списках XKeen есть несохранённые изменения. Уйти со страницы?')) { return; }
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
  if (session.auth) {
    render(location.pathname);
    updateActiveNav(location.pathname);
  } else {
    loadAuth();
  }
});

function render(path) {
  nextView();
  leaveConfig();
  stopProgressPolling();
  stopUpdateJobPolling();
  stopLogPolling();
  stopXkeenPolling();
  if (path === '/updates') { renderUpdates(); }
  else if (path === '/settings') { renderSettings(); }
  else if (path === '/log') { renderLog(); }
  else if (path === '/config') { renderConfig(); }
  else if (path === '/xkeen') { renderXkeen(); }
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
  // auth-mode (экран входа без шапки) включает только renderAuthForm().
  document.body.classList.remove('auth-mode');
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
  nextView();
  stopProgressPolling();
  stopUpdateJobPolling();
  stopLogPolling();
  setAuthenticatedUi(false);
  clearApp();
  // Экран входа: шапка скрыта, над карточкой - логотип (тот же, что у
  // вкладки браузера), карточка ~380 px по центру экрана.
  document.body.classList.add('auth-mode');
  var screen = el('div', 'auth-screen');
  var box = el('div', 'auth-box');
  var brand = el('div', 'auth-brand');
  var icon = document.querySelector('link[rel="icon"]');
  if (icon) {
    var logo = el('img', 'auth-logo');
    logo.src = icon.href;
    logo.alt = '';
    brand.appendChild(logo);
  }
  brand.appendChild(el('h1', null, 'MIHOMO-SPEEDTEST'));
  brand.appendChild(el('p', 'meta', 'УЗЕЛ УПРАВЛЕНИЯ'));
  box.appendChild(brand);
  var c = card(mode === 'setup' ? 'Первичная настройка' : 'Вход');
  c.classList.add('auth-card');
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
      session.auth = data;
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
  box.appendChild(c);
  screen.appendChild(box);
  app.appendChild(screen);
}

function renderUninitialized() {
  nextView();
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
      session.auth = data;
      setAuthenticatedUi(true);
      var path = location.pathname;
      if (path === '/login' || path === '/setup') {
        history.replaceState(null, '', '/stats');
        path = '/stats';
      }
      render(path);
      updateActiveNav(path);
    } else if (data.mode === 'setup') {
      session.auth = null;
      if (location.pathname !== '/setup') { history.replaceState(null, '', '/setup'); }
      renderAuthForm('setup');
    } else if (data.mode === 'login') {
      session.auth = null;
      if (location.pathname !== '/login') { history.replaceState(null, '', '/login'); }
      renderAuthForm('login');
    } else {
      session.auth = null;
      renderUninitialized();
    }
  })['catch'](function (error) {
    showError('Не удалось проверить авторизацию: ', error);
  });
}

logoutBtn.addEventListener('click', function () {
  logoutBtn.disabled = true;
  fetchJson('/api/auth/logout', { method: 'POST' }).then(function () {
    session.auth = null;
    history.replaceState(null, '', '/login');
    renderAuthForm('login');
  })['catch'](function (error) {
    if (error.status === 401) {
      session.auth = null;
      history.replaceState(null, '', '/login');
      renderAuthForm('login');
    } else {
      showError('Не удалось выйти: ', error);
    }
  }).then(function () { logoutBtn.disabled = false; });
});

setUnauthorizedHandler(function () { renderAuthForm('login'); });
loadAuth();
