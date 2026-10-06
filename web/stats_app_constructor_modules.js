// Блоки конструктора конфига: «Подписки», «Свои прокси», «Исключения нод» и
// «Базовые группы». Логика - app-constructor-modules-model.js (подписки,
// ноды, фильтр) и app-constructor-model.js (базовые группы в отличиях
// сервисов); здесь только отрисовка. Применяется вместе с остальным
// конструктором (см. app-constructor.js): сборка на роутере, mihomo -t.

import { card, el, fetchJson } from './app-core.js';
import { GEO_CATALOG, geoBuild, geoParse } from './app-settings.js';
import { UA_PRESETS } from './app-constructor-modules-model.js';

function button(text, cls) {
  var b = el('button', cls || 'small', text);
  b.type = 'button';
  return b;
}

function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }

function errText(err) {
  return err && err.data && err.data.message ? err.data.message : (err && err.message ? err.message : String(err));
}

// Адрес подписки содержит ключ доступа - в списке только домен.
function hostOf(url) {
  var m = /^https?:\/\/([^\/?#]+)/.exec(url || '');
  return m ? m[1] : '...';
}

var CUSTOM_UA = '__custom__';

// Выбор User-Agent: готовые значения, «без заголовка» и свой вариант.
function uaField(value) {
  var wrap = el('span', 'cx-ua');
  var sel = el('select');
  sel.setAttribute('aria-label', 'User-Agent');
  var opts = [['', 'без User-Agent']].concat(UA_PRESETS.map(function (u) { return [u, u]; })).concat([[CUSTOM_UA, 'другой...']]);
  opts.forEach(function (o) { var op = el('option', null, o[1]); op.value = o[0]; sel.appendChild(op); });
  var custom = el('input'); custom.type = 'text'; custom.placeholder = 'User-Agent';
  custom.setAttribute('aria-label', 'Свой User-Agent');
  function sync() { custom.hidden = sel.value !== CUSTOM_UA; }
  var known = opts.some(function (o) { return o[0] === value; });
  sel.value = known ? value : CUSTOM_UA;
  custom.value = known ? '' : value;
  sel.addEventListener('change', function () { sync(); if (!custom.hidden) { custom.focus(); } });
  sync();
  wrap.appendChild(sel); wrap.appendChild(custom);
  wrap.value = function () { return sel.value === CUSTOM_UA ? custom.value.trim() : sel.value; };
  return wrap;
}

// ctx: {mods, model, edit(fn), msg(text, kind), redraw(), changed()}. Возвращает {cards, render}:
// карточки созданы один раз, render() перерисовывает их содержимое.
export function createModuleCards(ctx) {
  var mods = ctx.mods, model = ctx.model;

  // ----- подписки -----
  var subsCard = card('Подписки');
  subsCard.appendChild(el('p', 'hint', 'Ссылки на подписки с нодами. Адрес содержит ключ доступа, поэтому в списке виден только домен. ' +
    'User-Agent выбирает формат ответа панели: для Mihomo нужен clash-YAML (v2rayNG и clash.meta обычно подходят).'));
  var subsHost = el('div');
  subsCard.appendChild(subsHost);
  var editingSub = null;

  function subRow(s) {
    if (editingSub === s.name) { return subEditor(s); }
    var r = el('div', 'xk-row cx-row');
    r.appendChild(el('span', 'xk-val', s.name));
    r.appendChild(el('span', 'geo-code', hostOf(s.url) + (s.ua ? ' · ' + s.ua : '')));
    var ed = button('Изменить', 'small muted');
    ed.addEventListener('click', function () { editingSub = s.name; render(); });
    var rm = button('Убрать', 'small muted');
    rm.addEventListener('click', function () { ctx.edit(function () { mods.removeSub(s.name); }); });
    r.appendChild(ed); r.appendChild(rm);
    return r;
  }

  function subEditor(s) {
    var r = el('div', 'cx-editor');
    var url = el('input'); url.type = 'text'; url.value = s.url; url.setAttribute('aria-label', 'Адрес подписки');
    var name = el('input'); name.type = 'text'; name.value = s.name; name.setAttribute('aria-label', 'Имя подписки');
    var ua = uaField(s.ua);
    var row = el('div', 'xk-add');
    var ok = button('Сохранить', 'submit'), cancel = button('Отмена', 'submit secondary');
    ok.addEventListener('click', function () {
      ctx.edit(function () { mods.editSub(s.name, { url: url.value, name: name.value, ua: ua.value() }); editingSub = null; });
    });
    cancel.addEventListener('click', function () { editingSub = null; render(); });
    r.appendChild(el('label', null, 'Адрес')); r.appendChild(url);
    r.appendChild(el('label', null, 'Имя (латиница, цифры, - и _)')); r.appendChild(name);
    r.appendChild(el('label', null, 'User-Agent')); r.appendChild(ua);
    row.appendChild(ok); row.appendChild(cancel);
    r.appendChild(row);
    return r;
  }

  function renderSubs() {
    clear(subsHost);
    var rows = el('div', 'xk-rows');
    var list = mods.subs();
    list.forEach(function (s) { rows.appendChild(subRow(s)); });
    if (!list.length) { rows.appendChild(el('div', 'xk-empty', 'Подписок нет.')); }
    subsHost.appendChild(rows);
    var add = el('div', 'cx-editor');
    var url = el('input'); url.type = 'text'; url.placeholder = 'https://...'; url.setAttribute('aria-label', 'Адрес новой подписки');
    var name = el('input'); name.type = 'text'; name.placeholder = 'имя (необязательно)'; name.setAttribute('aria-label', 'Имя подписки');
    var ua = uaField(UA_PRESETS[0]);
    var btn = button('Добавить подписку', 'submit');
    btn.addEventListener('click', function () {
      ctx.edit(function () { mods.addSub(url.value, ua.value(), name.value); });
    });
    url.addEventListener('keydown', function (e) { if (e.key === 'Enter') { btn.click(); } });
    add.appendChild(el('div', 'geo-group-title', 'Новая подписка'));
    add.appendChild(url);
    var row = el('div', 'xk-add');
    row.appendChild(name); row.appendChild(ua); row.appendChild(btn);
    add.appendChild(row);
    subsHost.appendChild(add);
  }

  // ----- свои прокси -----
  var proxCard = card('Свои прокси');
  proxCard.appendChild(el('p', 'hint', 'Свои ноды (Hysteria2, VLESS, Trojan, Shadowsocks, VMess, WireGuard/AmneziaWG). ' +
    'Они сами попадают в группы «Авто по пингу», Fallback и Manual. Пароли и ключи в списке не показываются.'));
  var proxHost = el('div');
  proxCard.appendChild(proxHost);

  function renameProxy(p) {
    var to = window.prompt('Новое имя ноды', p.name);
    if (to === null) { return; }
    ctx.edit(function () { mods.renameProxy(p.name, to); });
  }

  // Вставленный текст: ссылки по одной в строке или YAML нод. Возвращает
  // {added, errs, rest}: сколько нод добавлено, ошибки по строкам и строки,
  // которые не добавились (остаются в поле для правки).
  function addPasted(text) {
    var t = String(text || '');
    if (!t.trim()) { throw new Error('Вставьте ссылку на ноду (hy2://, vless://, trojan://, ss://, vmess://) или YAML'); }
    if (/^\s*-\s/m.test(t) || /^\s*name:/m.test(t)) {
      return { added: mods.addProxyYaml(t).length, errs: [], rest: [] };
    }
    var res = { added: 0, errs: [], rest: [] };
    t.split(/\r?\n/).forEach(function (l, i) {
      var line = l.trim();
      if (!line) { return; }
      try { mods.addProxyLink(line); res.added++; } catch (e) { res.errs.push('строка ' + (i + 1) + ': ' + e.message); res.rest.push(line); }
    });
    return res;
  }

  var proxDraft = '';

  function renderProxies() {
    clear(proxHost);
    var rows = el('div', 'xk-rows');
    var list = mods.proxies();
    list.forEach(function (p) {
      var r = el('div', 'xk-row cx-row');
      r.appendChild(el('span', 'xk-val', p.name));
      r.appendChild(el('span', 'geo-code', (p.type || '?') + (p.server ? ' · ' + p.server + (p.port ? ':' + p.port : '') : '')));
      var rn = button('Имя', 'small muted'); rn.setAttribute('aria-label', 'Переименовать ' + p.name);
      rn.addEventListener('click', function () { renameProxy(p); });
      var rm = button('Убрать', 'small muted');
      rm.addEventListener('click', function () { ctx.edit(function () { mods.removeProxy(p.name); }); });
      r.appendChild(rn); r.appendChild(rm);
      rows.appendChild(r);
    });
    if (!list.length) { rows.appendChild(el('div', 'xk-empty', 'Своих нод нет - работают только подписки.')); }
    proxHost.appendChild(rows);

    var area = el('textarea', 'xk-text');
    area.rows = 3;
    area.placeholder = 'Вставьте ссылку hy2:// vless:// trojan:// ss:// vmess:// (по одной в строке) или YAML ноды';
    area.setAttribute('aria-label', 'Ссылки или YAML нод');
    area.value = proxDraft;
    area.addEventListener('input', function () { proxDraft = area.value; });
    var row = el('div', 'btn-row');
    var add = button('Добавить', 'submit');
    add.addEventListener('click', function () {
      var res = null;
      try { res = addPasted(area.value); } catch (e) { ctx.msg(e.message, 'err'); return; }
      proxDraft = res.rest.join('\n');
      ctx.redraw();
      if (res.errs.length) { ctx.msg((res.added ? 'Добавлено нод: ' + res.added + '. ' : '') + 'Не добавлено - ' + res.errs.join('; '), 'err'); }
      else { ctx.msg('Добавлено нод: ' + res.added, 'ok'); }
    });
    var file = el('input'); file.type = 'file'; file.accept = '.conf'; file.multiple = true; file.hidden = true;
    file.setAttribute('aria-label', 'WireGuard .conf');
    var wg = button('из .conf файла', 'submit secondary');
    wg.title = 'WireGuard или AmneziaWG (формат wg-quick); имя ноды - по имени файла';
    wg.addEventListener('click', function () { file.click(); });
    file.addEventListener('change', function () {
      var files = Array.prototype.slice.call(file.files || []);
      file.value = '';
      importConf(files);
    });
    row.appendChild(add); row.appendChild(wg); row.appendChild(file);
    proxHost.appendChild(area);
    proxHost.appendChild(row);
  }

  // .conf файлы -> ноды (перевод на роутере: wg_import.awk), по одному запросу.
  function importConf(files) {
    if (!files.length) { return; }
    var done = [], errs = [];
    var chain = Promise.resolve();
    files.forEach(function (f) {
      chain = chain.then(function () { return f.text(); }).then(function (text) {
        var name = f.name.replace(/\.conf$/i, '');
        return fetchJson('/api/constructor/wgconf', { method: 'POST', body: '### MST-WG ' + name + '\n' + text,
          headers: { 'Content-Type': 'text/plain; charset=utf-8' } }).then(function (r) {
          try { mods.addProxyYaml(r.yaml || ''); done.push(name); } catch (e) { errs.push(f.name + ': ' + e.message); }
        }, function (e) { errs.push(f.name + ': ' + errText(e)); });
      });
    });
    chain.then(function () {
      render(); ctx.changed();
      if (errs.length) { ctx.msg((done.length ? 'Добавлено: ' + done.join(', ') + '. ' : '') + 'Не добавлено - ' + errs.join('; '), 'err'); }
      else { ctx.msg('Добавлено: ' + done.join(', '), 'ok'); }
    });
  }

  // ----- исключения нод -----
  var filtCard = card('Исключения нод');
  filtCard.appendChild(el('p', 'hint', 'Ноды, в имени которых есть любое из этих слов, не попадают в группы «Авто по пингу» и Fallback ' +
    '(exclude-filter подписок). Регистр не важен. Обязательно исключите Россию - иначе российская нода может выиграть замер по пингу.'));
  var filtHost = el('div');
  filtCard.appendChild(filtHost);

  function setFromState(sel, custom) {
    ctx.edit(function () { mods.setWords(geoBuild(sel, custom)); });
  }

  function renderFilter() {
    clear(filtHost);
    var words = mods.words();
    var st = geoParse(words.join('|'));
    var gridTitle = el('div', 'geo-group-title', 'Страны');
    filtHost.appendChild(gridTitle);
    function group(list) {
      var grid = el('div', 'geo-grid');
      list.forEach(function (c) {
        var lab = el('label', 'geo-country' + (st.sel[c.code] ? ' on' : ''));
        var cb = el('input'); cb.type = 'checkbox'; cb.checked = !!st.sel[c.code];
        cb.addEventListener('change', function () {
          var sel = Object.assign({}, st.sel);
          if (cb.checked) { sel[c.code] = true; } else { delete sel[c.code]; }
          setFromState(sel, st.custom);
        });
        lab.appendChild(cb);
        lab.appendChild(el('span', null, c.flag + ' ' + c.ru));
        grid.appendChild(lab);
      });
      return grid;
    }
    filtHost.appendChild(group(GEO_CATALOG.filter(function (c) { return c.common; })));
    var more = el('details');
    more.appendChild(el('summary', null, 'Другие страны'));
    more.appendChild(group(GEO_CATALOG.filter(function (c) { return !c.common; })));
    filtHost.appendChild(more);

    filtHost.appendChild(el('label', null, 'Свои слова (по одному в строке)'));
    var area = el('textarea', 'xk-text');
    area.rows = 4;
    area.value = st.custom.join('\n');
    area.setAttribute('aria-label', 'Свои слова фильтра');
    var err = el('p', 'xk-err');
    area.addEventListener('change', function () {
      var custom = area.value.split(/\r?\n|\|/).map(function (w) { return w.trim(); }).filter(Boolean);
      ctx.edit(function () { mods.setWords(geoBuild(st.sel, custom)); });
    });
    filtHost.appendChild(area); filtHost.appendChild(err);
    var row = el('div', 'btn-row');
    var reset = button('Вернуть слова шаблона', 'submit secondary');
    reset.disabled = mods.isDefaultWords();
    reset.addEventListener('click', function () { ctx.edit(function () { mods.resetWords(); }); });
    row.appendChild(reset);
    filtHost.appendChild(row);
    if (!st.sel.RU) {
      filtHost.appendChild(el('p', 'msg-err', 'Россия не выбрана - российская нода может выиграть замер по пингу.'));
    }
  }

  // ----- базовые группы -----
  var baseCard = card('Базовые группы');
  baseCard.appendChild(el('p', 'hint', 'Автовыбор нод и общий режим для сервисов. interval - как часто проверять ноды (секунды), ' +
    'tolerance - на сколько мс текущая нода может отставать от лучшей, прежде чем группа переключится. ' +
    'Для групп со всеми нодами подписок interval ниже 300 не ставьте (при 100+ нодах - 600).'));
  var baseHost = el('div');
  baseCard.appendChild(baseHost);

  function numField(group, key, info) {
    var wrap = el('label', 'cx-num');
    wrap.appendChild(el('span', null, key));
    var inp = el('input'); inp.type = 'text'; inp.inputMode = 'numeric'; inp.value = String(info.value);
    inp.setAttribute('aria-label', key + ' группы ' + group);
    inp.title = 'в шаблоне: ' + info.def;
    inp.addEventListener('change', function () {
      var v = inp.value.trim();
      ctx.edit(function () { model.setBase(group, key, v === '' ? String(info.def) : v); });
    });
    wrap.appendChild(inp);
    if (info.value !== info.def) { wrap.appendChild(el('span', 'hint', 'шаблон: ' + info.def)); }
    return wrap;
  }

  function renderBase() {
    clear(baseHost);
    var groups = model.baseGroups();
    var rows = el('div', 'xk-rows');
    groups.forEach(function (g) {
      var r = el('div', 'xk-row cx-row');
      r.appendChild(el('span', 'xk-val', g.name));
      if (g.interval) { r.appendChild(numField(g.name, 'interval', g.interval)); }
      if (g.tolerance) { r.appendChild(numField(g.name, 'tolerance', g.tolerance)); }
      rows.appendChild(r);
    });
    if (groups.length) { baseHost.appendChild(rows); }
    var routes = model.routes();
    if (routes.length) {
      baseHost.appendChild(el('div', 'geo-group-title', 'Что выбрано по умолчанию'));
      routes.forEach(function (rt) {
        var r = el('div', 'xk-row cx-row');
        r.appendChild(el('span', 'xk-val', rt.label));
        var sel = el('select'); sel.setAttribute('aria-label', 'По умолчанию: ' + rt.label);
        rt.tokens.forEach(function (tk) { var o = el('option', null, tk); o.value = tk; sel.appendChild(o); });
        sel.value = rt.value;
        sel.addEventListener('change', function () { ctx.edit(function () { model.setRoute(rt.name, sel.value); }); });
        r.appendChild(sel);
        if (rt.value !== rt.def) { r.appendChild(el('span', 'hint', 'шаблон: ' + rt.def)); }
        baseHost.appendChild(r);
      });
      baseHost.appendChild(el('p', 'hint', 'Это значение до первого ручного выбора: в панели Mihomo группу по-прежнему можно переключить, ' +
        'выбор запоминается (store-selected).'));
    }
    if (!groups.length && !routes.length) { baseHost.appendChild(el('div', 'xk-empty', 'Шаблон не отдал базовые группы.')); }
  }

  function render() {
    renderSubs(); renderProxies(); renderFilter(); renderBase();
  }

  return {
    cards: { subs: subsCard, proxies: proxCard, filter: filtCard, base: baseCard },
    render: render
  };
}
