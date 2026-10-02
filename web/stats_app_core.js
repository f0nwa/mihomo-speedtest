// Общее для всех разделов веб-интерфейса: элемент #app, сессия,
// fetchJson(), DOM-помощники и форматирование чисел.

export var app = document.getElementById('app');
export var mainNav = document.getElementById('mainNav');
export var logoutBtn = document.getElementById('logoutBtn');
// Текущая сессия: {username, csrf} или null. Меняет только app.js
// (вход/выход) и fetchJson() (401).
export var session = { auth: null };

// Что сделать, когда сервер ответил 401 (сессия истекла): app.js
// показывает форму входа.
var onUnauthorized = null;
export function setUnauthorizedHandler(fn) { onUnauthorized = fn; }

export function clearApp() {
  while (app.firstChild) { app.removeChild(app.firstChild); }
}

export function setLoading() {
  clearApp();
  var p = document.createElement('p');
  p.className = 'hint';
  p.textContent = 'Загрузка...';
  app.appendChild(p);
}

export function showNotYetMoved(text) {
  clearApp();
  var p = document.createElement('p');
  p.className = 'hint';
  p.textContent = text;
  app.appendChild(p);
  return p;
}

export function showError(prefix, err) {
  clearApp();
  var p = document.createElement('p');
  p.className = 'msg-err';
  p.textContent = prefix + (err && err.message ? err.message : String(err));
  app.appendChild(p);
}

export function fetchJson(url, opts) {
  opts = opts || {};
  var method = (opts.method || 'GET').toUpperCase();
  var headers = new Headers(opts.headers || {});
  if (session.auth && session.auth.csrf && method !== 'GET' && method !== 'HEAD') {
    headers.set('X-CSRF-Token', session.auth.csrf);
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
          session.auth = null;
          history.replaceState(null, '', '/login');
          if (onUnauthorized) { onUnauthorized(); }
          return new Promise(function () {});
        }
        throw error;
      }
      return data;
    });
  });
}

// ----- мелкие DOM/форматирующие помощники -----

export function el(tag, className, text) {
  var n = document.createElement(tag);
  if (className) { n.className = className; }
  if (text !== undefined && text !== null) { n.textContent = text; }
  return n;
}

export function card(title) {
  var c = el('div', 'card');
  if (title) { c.appendChild(el('h2', null, title)); }
  return c;
}

// Байты/с -> Мбит/с (x8 / 1 000 000, как в спидтестах) числом с одним
// знаком после точки (без лишнего нуля).
export function bytesToMbit(bytes) {
  return Math.round(bytes * 8 / 100000) / 10;
}

// Байты/с -> Мбит/с текстом, null/undefined -> "-".
export function fmtMbit(bytes) {
  if (bytes === null || bytes === undefined) { return '-'; }
  return String(bytesToMbit(bytes));
}

export function fmtSigned(bytes) {
  if (bytes === null || bytes === undefined) { return '-'; }
  var s = fmtMbit(Math.abs(bytes));
  if (bytes > 0) { return '+' + s; }
  if (bytes < 0) { return '-' + s; }
  return s;
}

export function statusLabel(status) {
  if (status === 'alive') { return { text: 'жива', cls: 'status-alive', sw: 'sw-alive' }; }
  if (status === 'down') { return { text: 'недоступна', cls: 'status-down', sw: 'sw-down' }; }
  // skipped - WG/AWG-нода в пуле, но не проверена (нет входа замера в основном ядре)
  if (status === 'skipped') { return { text: 'не проверена', cls: 'status-absent', sw: 'sw-absent' }; }
  return { text: 'нет данных', cls: 'status-absent', sw: 'sw-absent' };
}


export function showFormMessage(form, text, kind) {
  var old = form.querySelector('.form-msg');
  if (old) { old.parentNode.removeChild(old); }
  if (!text) { return; }
  var p = el('p', (kind === 'ok' ? 'msg-ok' : 'msg-err') + ' form-msg', text);
  form.insertBefore(p, form.firstChild);
}
