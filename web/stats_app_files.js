// Вкладка «Файлы» (/files): файловый менеджер от корня «/» - дерево каталогов,
// список текущего каталога и редактор текстового файла (макет B).
//
// Сервер (stats_files.py через /api/fm/*) сам отклоняет всё опасное: выход за
// пределы пути, чтение устройств, удаление системных каталогов. Здесь только
// интерфейс. Все строки с сервера выводятся только через textContent.
// На узком экране колонки превращаются в экраны (дерево -> список -> редактор).

import { app, clearApp, el, fetchJson, session, viewGuard } from './app-core.js';

var ERRORS = {
  bad_path: 'Некорректный путь.',
  bad_name: 'Некорректное имя файла.',
  not_found: 'Не найдено.',
  not_dir: 'Это не каталог.',
  permission: 'Нет прав на эту операцию.',
  readonly: 'Файл панели доступен только для чтения.',
  protected: 'Системный каталог нельзя удалить или переименовать.',
  exists: 'Такое имя уже есть.',
  not_empty: 'Каталог не пуст.',
  confirm_required: 'Нужно подтверждение удаления.',
  conflict: 'Файл на роутере изменился после открытия.',
  too_large: 'Файл слишком большой.',
  not_text: 'Это не текстовый файл - его можно только скачать.',
  not_regular: 'Это не обычный файл (устройство, сокет или каталог).',
  no_space: 'Не хватает места на диске.',
  truncated: 'Загрузка оборвалась.',
  rate_limited: 'Слишком много операций подряд, подождите.',
  io: 'Ошибка ввода-вывода на роутере.'
};

var fm = null;        // состояние открытой вкладки; null - вкладка закрыта
var cmPromise = null;

function errText(err) {
  var code = err && err.message;
  return ERRORS[code] || (code ? 'Ошибка: ' + code : 'Ошибка запроса.');
}

function enc(s) { return encodeURIComponent(s); }

function fmtSize(n) {
  if (n === null || n === undefined) { return '-'; }
  if (n < 1024) { return n + ' Б'; }
  if (n < 1048576) { return (n / 1024).toFixed(1).replace('.', ',') + ' КБ'; }
  if (n < 1073741824) { return (n / 1048576).toFixed(1).replace('.', ',') + ' МБ'; }
  return (n / 1073741824).toFixed(1).replace('.', ',') + ' ГБ';
}

function fmtTime(t) {
  if (!t) { return '-'; }
  var d = new Date(t * 1000);
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return p(d.getDate()) + '.' + p(d.getMonth() + 1) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function joinPath(dir, name) { return (dir === '/' ? '' : dir) + '/' + name; }
function parentPath(path) {
  var i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.slice(0, i);
}
function baseName(path) { return path.slice(path.lastIndexOf('/') + 1) || '/'; }

export function filesDirty() { return !!(fm && fm.file && fm.dirty); }

export function stopFiles() {
  if (fm) {
    fm.uploads.forEach(function (x) { try { x.abort(); } catch (e) { /* уже завершён */ } });
    fm = null;
  }
}

// ----- CodeMirror (грузится только на этой вкладке) -----

function loadCodeMirror() {
  if (window.CodeMirror) { return Promise.resolve(window.CodeMirror); }
  if (cmPromise) { return cmPromise; }
  var cssReady = new Promise(function (resolve) {
    var link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = 'codemirror.css';
    link.onload = resolve;
    link.onerror = resolve;
    document.head.appendChild(link);
  });
  cmPromise = cssReady.then(function () { return new Promise(function (resolve, reject) {
    var s = document.createElement('script');
    s.src = 'codemirror.js';
    s.onload = function () { window.CodeMirror ? resolve(window.CodeMirror) : reject(new Error('cm')); };
    s.onerror = function () { cmPromise = null; reject(new Error('cm')); };
    document.head.appendChild(s);
  }); });
  return cmPromise;
}

// Обёртка одинаковая для CodeMirror и запасного textarea.
function createEditor(host, text, readonly, onChange) {
  return loadCodeMirror().then(function (CM) {
    var cm = CM(host, {
      value: text, lineNumbers: true, indentUnit: 2, tabSize: 2, indentWithTabs: false,
      readOnly: readonly ? 'nocursor' : false,
      extraKeys: { Tab: function (c) { c.replaceSelection('  '); } }
    });
    cm.on('change', onChange);
    return { getValue: function () { return cm.getValue(); }, refresh: function () { cm.refresh(); } };
  }, function () {
    var ta = el('textarea', 'fm-textarea');
    ta.value = text;
    ta.readOnly = readonly;
    ta.spellcheck = false;
    ta.addEventListener('input', onChange);
    host.appendChild(ta);
    return { getValue: function () { return ta.value; }, refresh: function () {} };
  });
}

// ----- каркас -----

export function renderFiles() {
  stopFiles();
  clearApp();
  fm = {
    guard: viewGuard(), cwd: null, listing: null, hidden: false, sort: 'name',
    tree: {}, file: null, dirty: false, editor: null, uploads: [], busy: false
  };
  var root = el('div', 'fm');
  root.setAttribute('data-view', 'list');
  fm.root = root;
  fm.treeCol = el('div', 'fm-col fm-tree');
  fm.listCol = el('div', 'fm-col fm-list');
  fm.editCol = el('div', 'fm-col fm-edit');
  root.appendChild(fm.treeCol);
  root.appendChild(fm.listCol);
  root.appendChild(fm.editCol);
  app.appendChild(root);
  fm.tree['/'] = { open: true, dirs: null };
  drawEditor();
  var start = '/';
  try { start = sessionStorage.getItem('fm.cwd') || '/'; } catch (e) { /* хранилище недоступно */ }
  openDir(start, true);
}

function setView(v) { if (fm) { fm.root.setAttribute('data-view', v); } }

function notice(text, bad) {
  if (!fm) { return; }
  var old = fm.listCol.querySelector('.fm-msg');
  if (old) { old.parentNode.removeChild(old); }
  if (!text) { return; }
  var n = el('div', bad ? 'msg-err fm-msg' : 'msg-ok fm-msg', text);
  fm.listCol.insertBefore(n, fm.listCol.firstChild);
}

function fail(err) { notice(errText(err), true); }

// ----- дерево -----

function loadChildren(path) {
  var node = fm.tree[path] || (fm.tree[path] = { open: false, dirs: null });
  if (node.dirs) { return Promise.resolve(node); }
  var guard = fm.guard;
  return fetchJson('/api/fm/tree?path=' + enc(path)).then(function (d) {
    if (!guard()) { return node; }
    node.dirs = d.dirs || [];
    return node;
  }, function () { node.dirs = []; return node; });
}

function revealPath(path) {
  var parts = path.split('/').filter(Boolean);
  var chain = Promise.resolve();
  var cur = '/';
  var steps = ['/'];
  parts.forEach(function (p) { cur = joinPath(cur, p); steps.push(cur); });
  steps.forEach(function (p, i) {
    chain = chain.then(function () {
      if (!fm || i === steps.length - 1) { return null; }
      return loadChildren(p).then(function (node) { node.open = true; });
    });
  });
  return chain.then(drawTree);
}

function drawTree() {
  if (!fm) { return; }
  var col = fm.treeCol;
  while (col.firstChild) { col.removeChild(col.firstChild); }
  col.appendChild(el('div', 'fm-head', 'ФАЙЛОВАЯ СИСТЕМА'));
  function walk(path, depth) {
    var node = fm.tree[path] || { open: false, dirs: null };
    var row = el('div', 'fm-trow' + (path === fm.cwd ? ' on' : ''));
    row.style.paddingLeft = (8 + depth * 14) + 'px';
    var tog = el('button', 'fm-tog', node.open ? '▾' : '▸');
    tog.type = 'button';
    tog.setAttribute('aria-label', node.open ? 'Свернуть' : 'Развернуть');
    tog.addEventListener('click', function () {
      if (node.open) { node.open = false; drawTree(); return; }
      loadChildren(path).then(function (n) { n.open = true; drawTree(); });
    });
    var name = el('button', 'fm-tname', path === '/' ? '/' : baseName(path));
    name.type = 'button';
    name.addEventListener('click', function () { openDir(path); });
    row.appendChild(tog);
    row.appendChild(name);
    col.appendChild(row);
    if (node.open && node.dirs) {
      node.dirs.forEach(function (d) { walk(joinPath(path, d), depth + 1); });
    }
  }
  walk('/', 0);
}

// ----- список -----

function openDir(path, silent) {
  if (!fm) { return Promise.resolve(); }
  if (fm.dirty && !silent && !window.confirm('Несохранённые правки файла пропадут. Перейти?')) { return Promise.resolve(); }
  var guard = fm.guard;
  return fetchJson('/api/fm/list?path=' + enc(path) + '&hidden=' + (fm.hidden ? '1' : '0')).then(function (data) {
    if (!guard()) { return; }
    fm.cwd = data.path;
    fm.listing = data;
    try { sessionStorage.setItem('fm.cwd', data.path); } catch (e) { /* не страшно */ }
    drawList();
    setView('list');
    return revealPath(data.path);
  }, function (err) {
    if (!guard()) { return; }
    if (!fm.listing) { fm.cwd = '/'; fm.listing = { entries: [], path: '/', truncated: false }; drawList(); drawTree(); }
    fail(err);
  });
}

function sortedEntries() {
  var list = fm.listing.entries.slice();
  var key = fm.sort;
  list.sort(function (a, b) {
    var ad = a.type === 'dir' || a.link_dir ? 0 : 1;
    var bd = b.type === 'dir' || b.link_dir ? 0 : 1;
    if (ad !== bd) { return ad - bd; }
    if (key === 'size') { return (b.size || 0) - (a.size || 0); }
    if (key === 'mtime') { return (b.mtime || 0) - (a.mtime || 0); }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  });
  return list;
}

function drawCrumbs(host) {
  var parts = fm.cwd.split('/').filter(Boolean);
  var cur = '/';
  var root = el('button', 'fm-crumb', '/');
  root.type = 'button';
  root.addEventListener('click', function () { openDir('/'); });
  host.appendChild(root);
  parts.forEach(function (p) {
    cur = joinPath(cur, p);
    var target = cur;
    host.appendChild(el('span', 'hint', '/'));
    var b = el('button', 'fm-crumb', p);
    b.type = 'button';
    b.addEventListener('click', function () { openDir(target); });
    host.appendChild(b);
  });
}

function toolBtn(label, cls, fn) {
  var b = el('button', 'theme-btn fm-btn' + (cls ? ' ' + cls : ''), label);
  b.type = 'button';
  b.addEventListener('click', fn);
  return b;
}

function drawList() {
  var col = fm.listCol;
  while (col.firstChild) { col.removeChild(col.firstChild); }
  var back = toolBtn('← Дерево', 'fm-back', function () { setView('tree'); });
  col.appendChild(back);
  var crumbs = el('div', 'fm-crumbs');
  drawCrumbs(crumbs);
  col.appendChild(crumbs);

  var bar = el('div', 'fm-bar');
  var input = el('input');
  input.type = 'file';
  input.multiple = true;
  input.hidden = true;
  input.addEventListener('change', function () { uploadFiles(input.files); input.value = ''; });
  bar.appendChild(input);
  bar.appendChild(toolBtn('Загрузить', 'fm-primary', function () { input.click(); }));
  bar.appendChild(toolBtn('Папка', '', makeDir));
  bar.appendChild(toolBtn('Файл', '', makeFile));
  var sort = el('select', 'fm-sort');
  [['name', 'по имени'], ['size', 'по размеру'], ['mtime', 'по дате']].forEach(function (o) {
    var opt = el('option', null, o[1]);
    opt.value = o[0];
    if (o[0] === fm.sort) { opt.selected = true; }
    sort.appendChild(opt);
  });
  sort.setAttribute('aria-label', 'Сортировка');
  sort.addEventListener('change', function () { fm.sort = sort.value; drawList(); });
  bar.appendChild(sort);
  var hid = el('label', 'fm-hid');
  var cb = el('input');
  cb.type = 'checkbox';
  cb.checked = fm.hidden;
  cb.addEventListener('change', function () { fm.hidden = cb.checked; openDir(fm.cwd, true); });
  hid.appendChild(cb);
  hid.appendChild(document.createTextNode(' .bak/.part'));
  bar.appendChild(hid);
  col.appendChild(bar);

  var drop = el('div', 'fm-drop', 'Перетащите файлы сюда');
  ['dragenter', 'dragover'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.add('over'); });
  });
  ['dragleave', 'drop'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.remove('over'); });
  });
  drop.addEventListener('drop', function (e) {
    if (e.dataTransfer && e.dataTransfer.files) { uploadFiles(e.dataTransfer.files); }
  });
  col.appendChild(drop);
  fm.progress = el('div', 'fm-progress');
  col.appendChild(fm.progress);

  var table = el('div', 'fm-rows');
  if (fm.cwd !== '/') {
    table.appendChild(rowFor({ name: '..', type: 'dir' }, parentPath(fm.cwd), true));
  }
  sortedEntries().forEach(function (e) { table.appendChild(rowFor(e, joinPath(fm.cwd, e.name), false)); });
  col.appendChild(table);
  if (fm.listing.truncated) {
    col.appendChild(el('p', 'hint', 'Показаны не все записи: в каталоге их слишком много.'));
  }
}

function rowFor(e, path, isUp) {
  var isDir = e.type === 'dir' || e.link_dir;
  var row = el('div', 'fm-row' + (fm.file && fm.file.path === path ? ' on' : ''));
  var main = el('button', 'fm-rmain');
  main.type = 'button';
  main.appendChild(el('span', 'fm-ico ' + (isDir ? 'dir' : 'file')));
  var label = e.name + (e.type === 'link' ? ' -> ' + (e.link || '') : '');
  main.appendChild(el('span', 'fm-name', label));
  main.appendChild(el('span', 'fm-size', isDir || isUp ? '' : fmtSize(e.size)));
  main.appendChild(el('span', 'fm-time', isUp ? '' : fmtTime(e.mtime)));
  main.addEventListener('click', function () {
    if (isDir) { openDir(path); }
    else if (e.type === 'file' || e.type === 'link') { openFile(path); }
  });
  row.appendChild(main);
  if (!isUp) {
    var del = el('button', 'fm-rdel', '×');
    del.type = 'button';
    del.setAttribute('aria-label', 'Удалить ' + e.name);
    del.addEventListener('click', function () { removePath(path, false); });
    row.appendChild(del);
  }
  return row;
}

// ----- операции со списком -----

function makeDir() {
  var name = window.prompt('Имя новой папки:');
  if (!name) { return; }
  fetchJson('/api/fm/mkdir', jsonBody({ path: joinPath(fm.cwd, name) })).then(function () {
    return openDir(fm.cwd, true);
  }, fail);
}

function makeFile() {
  var name = window.prompt('Имя нового файла:');
  if (!name) { return; }
  var path = joinPath(fm.cwd, name);
  fetchJson('/api/fm/write', jsonBody({ path: path, content: '' }, 'PUT')).then(function () {
    return openDir(fm.cwd, true).then(function () { return openFile(path); });
  }, fail);
}

function jsonBody(obj, method) {
  return { method: method || 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function uploadFiles(files) {
  var queue = Array.prototype.slice.call(files || []);
  var dir = fm.cwd;
  var guard = fm.guard;
  function next() {
    if (!guard() || !queue.length) {
      if (guard()) { openDir(dir, true); }
      return;
    }
    var file = queue.shift();
    var line = el('div', 'fm-up');
    var label = el('span', null, file.name + ' - 0%');
    var bar = el('div', 'run-progress');
    var fill = el('div', 'run-progress-fill');
    bar.appendChild(fill);
    line.appendChild(label);
    line.appendChild(bar);
    fm.progress.appendChild(line);
    var xhr = new XMLHttpRequest();
    fm.uploads.push(xhr);
    xhr.open('POST', '/api/fm/upload?path=' + enc(dir) + '&name=' + enc(file.name));
    xhr.setRequestHeader('X-CSRF-Token', csrf());
    xhr.upload.onprogress = function (ev) {
      if (!ev.lengthComputable) { return; }
      var pct = Math.round(ev.loaded * 100 / ev.total);
      label.textContent = file.name + ' - ' + pct + '%';
      fill.style.width = pct + '%';
    };
    xhr.onload = function () {
      if (xhr.status === 200) { label.textContent = file.name + ' - готово'; fill.style.width = '100%'; }
      else {
        var code = '';
        try { code = JSON.parse(xhr.responseText).error; } catch (e) { /* не JSON */ }
        label.textContent = file.name + ' - ' + errText({ message: code });
        line.classList.add('bad');
      }
      next();
    };
    xhr.onerror = function () { label.textContent = file.name + ' - ошибка сети'; line.classList.add('bad'); next(); };
    xhr.send(file);
  }
  next();
}

function csrf() {
  return (session.auth && session.auth.csrf) || '';
}

// ----- редактор -----

function drawEditor() {
  var col = fm.editCol;
  while (col.firstChild) { col.removeChild(col.firstChild); }
  fm.editor = null;
  col.appendChild(toolBtn('← Список', 'fm-back', function () {
    if (fm.dirty && !window.confirm('Несохранённые правки пропадут. Вернуться к списку?')) { return; }
    fm.file = null; fm.dirty = false; drawEditor(); drawList(); setView('list');
  }));
  if (!fm.file) {
    col.appendChild(el('p', 'hint fm-empty', 'Выберите файл в списке: текстовые файлы откроются здесь.'));
  }
}

function openFile(path) {
  if (fm.dirty && !window.confirm('Несохранённые правки пропадут. Открыть другой файл?')) { return Promise.resolve(); }
  var guard = fm.guard;
  return fetchJson('/api/fm/read?path=' + enc(path)).then(function (data) {
    if (!guard()) { return; }
    showFile(path, data);
  }, function (err) {
    if (!guard()) { return; }
    var text = errText(err);
    fm.file = { path: path, binary: true };
    fm.dirty = false;
    drawEditor();
    drawFileHead(path, text, null);
    drawList();
    setView('edit');
  });
}

function drawFileHead(path, info, data) {
  var head = el('div', 'fm-fhead');
  head.appendChild(el('strong', 'fm-fname', baseName(path)));
  head.appendChild(el('span', 'hint', info));
  var acts = el('span', 'fm-acts');
  var ro = !!(data && data.readonly);
  if (data) {
    var save = toolBtn('Сохранить', 'fm-primary', saveFile);
    save.disabled = ro;
    fm.saveBtn = save;
    acts.appendChild(save);
  }
  var dl = el('a', 'theme-btn fm-btn', 'Скачать');
  dl.href = '/api/fm/download?path=' + enc(path);
  dl.setAttribute('download', baseName(path));
  acts.appendChild(dl);
  acts.appendChild(toolBtn('Переименовать', '', renameFile));
  acts.appendChild(toolBtn('Удалить', 'danger', function () { removePath(path, false); }));
  head.appendChild(acts);
  fm.editCol.appendChild(head);
}

function showFile(path, data) {
  fm.file = { path: path, mtime: data.mtime, readonly: data.readonly };
  fm.dirty = false;
  drawEditor();
  drawFileHead(path, fmtSize(data.size) + ' · изменён ' + fmtTime(data.mtime) +
    (data.readonly ? ' · только чтение' : ''), data);
  var host = el('div', 'fm-cm');
  fm.editCol.appendChild(host);
  fm.status = el('div', 'fm-status hint', data.readonly ? 'Файл панели: только чтение' : 'Ctrl+S - сохранить');
  fm.editCol.appendChild(fm.status);
  setView('edit');
  var guard = fm.guard;
  createEditor(host, data.content, data.readonly, function () {
    if (!fm || !fm.file) { return; }
    fm.dirty = true;
    fm.status.textContent = 'Изменено, не сохранено · при сохранении создаётся ' + baseName(path) + '.bak';
  }).then(function (ed) {
    if (!guard() || !fm.file || fm.file.path !== path) { return; }
    fm.editor = ed;
    ed.refresh();
  });
  host.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) { e.preventDefault(); saveFile(); }
  });
  drawList();
}

function saveFile() {
  if (!fm || !fm.file || !fm.editor || fm.file.readonly) { return; }
  var f = fm.file;
  fetchJson('/api/fm/write', jsonBody({ path: f.path, content: fm.editor.getValue(), mtime: f.mtime }, 'PUT')).then(function (res) {
    f.mtime = res.mtime;
    fm.dirty = false;
    fm.status.textContent = 'Сохранено ' + fmtTime(Date.now() / 1000);
  }, function (err) {
    if (err && err.message === 'conflict') {
      fm.status.textContent = errText(err) + ' Откройте файл заново, чтобы увидеть чужие правки.';
    } else {
      fm.status.textContent = errText(err);
    }
  });
}

function renameFile() {
  var f = fm.file;
  var dst = window.prompt('Новый полный путь:', f.path);
  if (!dst || dst === f.path) { return; }
  fetchJson('/api/fm/rename', jsonBody({ src: f.path, dst: dst })).then(function () {
    fm.file = null; fm.dirty = false; drawEditor();
    return openDir(fm.cwd, true);
  }, fail);
}

function removePath(path, recursive) {
  var what = baseName(path);
  if (!recursive && !window.confirm('Удалить «' + what + '»?')) { return; }
  var body = { path: path };
  if (recursive) { body.recursive = true; body.confirm = path; }
  fetchJson('/api/fm/delete', jsonBody(body)).then(function () {
    if (fm.file && fm.file.path === path) { fm.file = null; fm.dirty = false; drawEditor(); }
    return openDir(fm.cwd, true);
  }, function (err) {
    if (err && err.message === 'not_empty' && !recursive) {
      var typed = window.prompt('Каталог не пуст. Чтобы удалить его вместе со всем содержимым, введите его путь:\n' + path);
      if (typed === path) { removePath(path, true); }
      return;
    }
    fail(err);
  });
}
