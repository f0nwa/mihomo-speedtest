// Вкладка «Конфиг», режим «Конструктор»: сервисы, свои домены и свои
// правила без правки YAML. Данные - /api/constructor (stats_constructor.sh),
// модель правок - app-constructor-model.js. Применение идёт тем же путём,
// что и сохранение в YAML-режиме: сборка на роутере, mihomo -t, бэкап,
// перезапуск, автооткат; состояние пишется только после успеха.
// См. docs/superpowers/specs/2026-10-05-config-constructor-design.md, п. 3-4.

import { app, card, clearApp, el, fetchJson, nextView, setLoading, showError, viewGuard } from './app-core.js';
import { createModel, parseCatalog, searchCatalog, stateBody } from './app-constructor-model.js';

var view = null;   // {dirty:bool}
var catalogPromise = null;   // каталог наборов правил грузится один раз

function loadCatalog() {
  if (!catalogPromise) {
    catalogPromise = fetchJson('/api/constructor/catalog').then(function (d) { return parseCatalog(d.text || ''); })
      ['catch'](function (e) { catalogPromise = null; throw e; });
  }
  return catalogPromise;
}

var SOURCE_LABELS = { metacubex: 'MetaCubeX', 'zxc-rv': 'zxc-rv', itdog: 'itdog', legiz: 'legiz' };
var KIND_LABELS = { domain: 'домены', ipcidr: 'IP-адреса', classical: 'правила' };

// Имя группы из названия набора: без пометки источника в скобках и
// символов, недопустимых в имени группы.
function suggestName(title) {
  return String(title || '').replace(/\s*\([^)]*\)\s*$/, '').replace(/[,#:'"]/g, ' ').replace(/\s+/g, ' ').trim();
}

export function constructorDirty() { return !!(view && view.dirty); }
export function leaveConstructor() { view = null; }

var TYPE_LABELS = { suffix: 'домен и поддомены', full: 'точный адрес', keyword: 'по слову' };

function button(text, cls) {
  var b = el('button', cls || 'small', text);
  b.type = 'button';
  return b;
}

function typeSelect() {
  var s = el('select');
  s.setAttribute('aria-label', 'Как сопоставлять');
  Object.keys(TYPE_LABELS).forEach(function (k) {
    var o = el('option', null, TYPE_LABELS[k]); o.value = k; s.appendChild(o);
  });
  return s;
}

function errText(err) {
  return err && err.data && err.data.message ? err.data.message : (err && err.message ? err.message : String(err));
}

// modeBar - переключатель режимов (рисует app-config.js); opts.renderDiff -
// показ различий (из app-config.js); opts.forceImport - «Перенести в
// конструктор» (?import=1).
export function renderConstructor(modeBar, opts) {
  opts = opts || {};
  // перерисовка изнутри конструктора (отмена, перенос, после применения):
  // ответы прежней отрисовки больше не нужны
  if (opts.again) { nextView(); }
  setLoading();
  view = { dirty: false };
  var v = view;
  var alive = viewGuard();
  fetchJson('/api/constructor' + (opts.forceImport ? '?import=1' : '')).then(function (data) {
    if (!alive()) { return; }
    clearApp();
    app.appendChild(modeBar);
    var model = createModel(data.defaults || '', data.services || '', data.user_rules || '');
    var geofilter = data.geofilter || '';
    // Перенос (состояния ещё нет или «Перенести в конструктор») - в
    // состоянии пока ничего не записано: всё перенесённое - изменения.
    var initial = data.imported ? { services: '', user_rules: '' } : model.serialize();
    var expanded = {};

    var head = card('Конструктор конфига');
    head.appendChild(el('p', 'hint', 'Сервисы, свои домены и правила без правки YAML. Подписки, свои прокси, dns и ' +
      'прочие настройки config.yaml переносятся при применении как есть. Перед применением конфиг собирается ' +
      'на роутере и проверяется mihomo -t, текущая версия уходит в бэкап.'));
    var msgBox = el('div');
    head.appendChild(msgBox);
    if (opts.flash) { msgBox.appendChild(el('p', 'msg-ok', opts.flash)); }
    if (data.manual_edits) {
      var w = el('div', 'geo-warn warn');
      w.appendChild(el('span', 'geo-warn-tag', 'ВНИМАНИЕ'));
      var wt = el('div');
      wt.appendChild(el('div', null, 'Группы и правила в config.yaml менялись вручную (в YAML-режиме или откатом к бэкапу). ' +
        'Применение конструктора перезапишет их по настройкам ниже.'));
      var importBtn = button('Перенести в конструктор');
      importBtn.addEventListener('click', function () {
        if (v.dirty && !window.confirm('Несохранённые правки конструктора пропадут. Продолжить?')) { return; }
        renderConstructor(modeBar, { forceImport: true, renderDiff: opts.renderDiff, again: true });
      });
      wt.appendChild(importBtn);
      w.appendChild(wt);
      head.appendChild(w);
    }
    if (data.imported) {
      var info = el('div', 'geo-warn');
      info.appendChild(el('span', 'geo-warn-tag', 'ПЕРЕНОС'));
      var it = el('div', null, 'Настройки перенесены из текущего config.yaml. Проверьте их и нажмите «Проверить и применить» - ' +
        'после этого конструктор будет помнить их и при обновлении шаблона.');
      var review = (data.report || []).filter(function (l) { return /^REVIEW\|/.test(l); });
      if (review.length) {
        var det = el('details');
        det.appendChild(el('summary', null, 'Не перенесено автоматически: ' + review.length));
        det.appendChild(el('pre', null, review.join('\n')));
        it.appendChild(det);
      }
      info.appendChild(it);
      head.appendChild(info);
    }
    app.appendChild(head);

    var svcCard = card('Сервисы');
    svcCard.appendChild(el('p', 'hint', 'Сервис - группа в Mihomo и правила, по которым в неё попадает трафик. ' +
      'Куда направить группу (прокси, напрямую), выбирается как обычно в панели Mihomo.'));
    var svcHost = el('div');
    svcCard.appendChild(svcHost);
    app.appendChild(svcCard);

    var domCard = card('Свои домены');
    domCard.appendChild(el('p', 'hint', 'Все добавленные вами домены. Свои домены проверяются раньше любых наборов правил.'));
    var domHost = el('div');
    domCard.appendChild(domHost);
    app.appendChild(domCard);

    var rulesCard = card('Свои правила');
    rulesCard.appendChild(el('p', 'hint', 'Правила Mihomo как есть, по одному в строке, без «- » (например ' +
      'DOMAIN-SUFFIX,example.com,DIRECT). Проверяются первыми. Сюда попадают и правила, которые не удалось разложить по сервисам при переносе.'));
    var rulesArea = el('textarea', 'xk-text');
    rulesArea.rows = 6;
    rulesArea.value = model.userRules();
    rulesArea.setAttribute('aria-label', 'Свои правила');
    var rulesErr = el('p', 'xk-err');
    rulesCard.appendChild(rulesArea);
    rulesCard.appendChild(rulesErr);
    app.appendChild(rulesCard);
    rulesArea.addEventListener('input', function () {
      try { model.setUserRules(rulesArea.value); rulesErr.textContent = ''; } catch (e) { rulesErr.textContent = e.message; }
      refreshChanges();
    });

    var chCard = card('Изменения');
    chCard.className += ' config-apply';
    var chStatus = el('p', 'hint config-status');
    var chList = el('ul', 'config-fixes');
    var chRow = el('div', 'btn-row');
    var diffBtn = button('Показать изменения config.yaml', 'submit secondary');
    var applyBtn = button('Проверить и применить', 'submit');
    var resetBtn = button('Отменить изменения', 'submit secondary');
    chRow.appendChild(diffBtn); chRow.appendChild(applyBtn); chRow.appendChild(resetBtn);
    var chOut = el('div');
    chCard.appendChild(chStatus); chCard.appendChild(chList); chCard.appendChild(chRow); chCard.appendChild(chOut);
    app.appendChild(chCard);

    function msg(text, kind) {
      while (msgBox.firstChild) { msgBox.removeChild(msgBox.firstChild); }
      if (text) {
        msgBox.appendChild(el('p', kind === 'ok' ? 'msg-ok' : (kind === 'err' ? 'msg-err' : 'hint'), text));
        head.scrollIntoView({ block: 'start', behavior: 'smooth' });
      }
    }
    function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }
    function busy(on) { [diffBtn, applyBtn, resetBtn].forEach(function (b) { b.disabled = on; }); }
    function edit(fn) {
      try { fn(); msg(''); } catch (e) { msg(e.message, 'err'); return; }
      draw();
    }

    function refreshChanges() {
      var list = model.summary(initial);
      // перенос ещё не сохранён в конструкторе - это изменение, даже если
      // переносить нечего (иначе предупреждение о ручных правках не снять)
      if (data.imported) { list.unshift('Перенос из config.yaml (настройки ещё не сохранены в конструкторе)'); }
      if (rulesErr.textContent) { list.push('Свои правила: исправьте ошибку'); }
      v.dirty = list.length > 0;
      clear(chList);
      list.forEach(function (t) { chList.appendChild(el('li', null, t)); });
      chStatus.textContent = list.length ? ('Не применено изменений: ' + list.length) : 'Изменений нет.';
      chStatus.className = 'hint config-status' + (list.length ? ' config-dirty' : '');
      applyBtn.disabled = !list.length || !!rulesErr.textContent;
      diffBtn.disabled = !!rulesErr.textContent;
    }

    function domainRow(id, d) {
      var r = el('div', 'xk-row cx-row' + (d.removed ? ' off' : ''));
      r.appendChild(el('span', 'xk-val', d.value));
      r.appendChild(el('span', 'geo-code', TYPE_LABELS[d.type] + (d.builtin ? ', встроенный' : '')));
      var b = button(d.removed ? 'Вернуть' : 'Убрать', 'small muted');
      b.addEventListener('click', function () {
        edit(function () {
          if (d.removed) { model.addDomain(id, d.type, d.value); } else { model.removeDomain(id, d.type, d.value); }
        });
      });
      r.appendChild(b);
      return r;
    }

    function addDomainRow(services, fixedId) {
      var row = el('div', 'xk-add');
      var inp = el('input'); inp.type = 'text'; inp.placeholder = 'example.com';
      inp.setAttribute('aria-label', 'Домен');
      var ts = typeSelect();
      var sel = null;
      row.appendChild(inp); row.appendChild(ts);
      if (!fixedId) {
        sel = el('select'); sel.setAttribute('aria-label', 'Сервис');
        services.forEach(function (s) { if (!s.deleted) { var o = el('option', null, s.name); o.value = s.id; sel.appendChild(o); } });
        row.appendChild(sel);
      }
      var add = button('Добавить', 'submit');
      add.addEventListener('click', function () {
        edit(function () { model.addDomain(fixedId || sel.value, ts.value, inp.value); });
      });
      inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { add.click(); } });
      row.appendChild(add);
      return row;
    }

    function serviceRow(s) {
      var box = el('div');
      var r = el('div', 'xk-row cx-row' + (s.deleted ? ' off' : ''));
      var doms = model.domains(s.id).filter(function (d) { return !d.removed; }).length;
      var rules = model.sources(s.id).length + (s.user ? 0 : model.rules(s.id).filter(function (x) { return !x.removed; }).length);
      r.appendChild(el('span', 'xk-val', s.name));
      r.appendChild(el('span', 'geo-code', (s.user ? 'свой · ' : '') + 'доменов: ' + doms + ', наборов и правил: ' + rules));
      if (!s.deleted) {
        var t = button(expanded[s.id] ? 'Свернуть' : 'Домены и правила', 'small muted');
        t.setAttribute('aria-expanded', expanded[s.id] ? 'true' : 'false');
        t.addEventListener('click', function () { expanded[s.id] = !expanded[s.id]; draw(); });
        r.appendChild(t);
      }
      var del = button(s.deleted ? 'Вернуть' : (s.user ? 'Удалить' : 'Убрать'), 'small muted');
      del.addEventListener('click', function () {
        edit(function () {
          if (s.deleted) { model.restoreService(s.id); }
          else if (s.user) { model.removeUserService(s.id); }
          else { model.deleteService(s.id); }
        });
      });
      r.appendChild(del);
      box.appendChild(r);
      if (expanded[s.id] && !s.deleted) {
        var p = el('div', 'xk-rows');
        p.style.marginLeft = '16px';
        model.domains(s.id).forEach(function (d) { p.appendChild(domainRow(s.id, d)); });
        p.appendChild(addDomainRow(null, s.id));
        var chips = el('div', 'geo-chips');
        model.rules(s.id).forEach(function (x) {
          var c = button(x.text + (x.removed ? '  ↺' : '  ×'), 'geo-chip' + (x.removed ? ' removed' : ''));
          c.title = x.removed ? 'Вернуть правило' : 'Убрать правило';
          c.addEventListener('click', function () {
            edit(function () { if (x.removed) { model.restoreRule(s.id, x.text); } else { model.removeRule(s.id, x.text); } });
          });
          chips.appendChild(c);
        });
        var addSrc = button('+ набор из базы', 'small muted');
        addSrc.addEventListener('click', function () { openAdd(s.id); });
        chips.appendChild(addSrc);
        model.sources(s.id).forEach(function (src) {
          var c = button('набор ' + src.name + (src.kind === 'ipcidr' ? ' (IP)' : '') + '  ×', 'geo-chip');
          c.title = 'Отключить набор';
          c.addEventListener('click', function () { edit(function () { model.removeSource(s.id, src.name, src.kind); }); });
          chips.appendChild(c);
        });
        if (chips.firstChild) { p.appendChild(chips); }
        box.appendChild(p);
      }
      return box;
    }

    // Окно «Добавить сервис из базы» (targetId пуст) или «Подключить набор»
    // к сервису targetId: поиск по каталогу, отметка наборов, имя и раздел.
    function openAdd(targetId) {
      var target = targetId ? model.services().filter(function (x) { return x.id === targetId; })[0] : null;
      var d = el('dialog', 'xk-dialog');
      var hd = el('div', 'xk-head');
      hd.appendChild(el('b', null, target ? 'Подключить набор правил к ' + target.name : 'Добавить сервис из базы'));
      var x = el('button', 'xk-x', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Закрыть');
      hd.appendChild(el('span', 'xk-grow'));
      hd.appendChild(x);
      d.appendChild(hd);
      d.appendChild(el('div', 'xk-about', 'База наборов правил: MetaCubeX (geosite), zxc-rv, itdog, legiz. ' +
        'Отметьте нужные наборы: «домены» ловят сайты по адресам, «IP-адреса» - по сетям сервиса.'));
      var bodyBox = el('div', 'cx-dlg-body');
      var q = el('input'); q.type = 'search'; q.placeholder = 'Поиск: netflix, chatgpt, заблокированное...';
      q.setAttribute('aria-label', 'Поиск по базе');
      bodyBox.appendChild(q);
      var results = el('div', 'cx-results');
      bodyBox.appendChild(results);
      var picked = {};   // имя@вид -> запись каталога
      var nameRow = null, nameIn = null, secSel = null;
      if (!target) {
        nameRow = el('div', 'xk-add');
        nameIn = el('input'); nameIn.type = 'text'; nameIn.placeholder = 'Имя группы';
        nameIn.setAttribute('aria-label', 'Имя группы');
        secSel = el('select'); secSel.setAttribute('aria-label', 'Раздел');
        model.sections().forEach(function (sec) { var o = el('option', null, sec.title); o.value = sec.id; secSel.appendChild(o); });
        secSel.value = 'other';
        nameRow.appendChild(nameIn); nameRow.appendChild(secSel);
        bodyBox.appendChild(el('label', null, 'Новая группа'));
        bodyBox.appendChild(nameRow);
      }
      var preview = el('div', 'geo-summary');
      var err = el('p', 'xk-err');
      bodyBox.appendChild(preview); bodyBox.appendChild(err);
      d.appendChild(bodyBox);
      var ft = el('div', 'xk-foot');
      var ok = button(target ? 'Подключить' : 'Добавить', 'submit');
      var cancel = button('Отмена', 'submit secondary');
      ft.appendChild(el('span', 'xk-grow'));
      ft.appendChild(cancel); ft.appendChild(ok);
      d.appendChild(ft);
      document.body.appendChild(d);
      function close() { d.close(); if (d.parentNode) { d.parentNode.removeChild(d); } }
      x.addEventListener('click', close);
      cancel.addEventListener('click', close);
      d.addEventListener('cancel', function (e) { e.preventDefault(); close(); });

      function keys() { return Object.keys(picked); }
      function updatePreview() {
        clear(preview);
        var ks = keys();
        ok.disabled = !ks.length;
        if (!ks.length) { preview.appendChild(el('span', 'hint', 'Отметьте хотя бы один набор.')); return; }
        var group = target ? target.name : (nameIn.value.trim() || '...');
        preview.appendChild(el('div', 'geo-group-title', 'Что появится в конфиге'));
        if (!target) { preview.appendChild(el('div', null, '+ группа ' + group + ' (как у остальных сервисов)')); }
        var used = model.usedSources(), taken = [];
        ks.forEach(function (k) {
          var e = picked[k];
          preview.appendChild(el('div', null, '+ набор ' + e.name + ' (' + (SOURCE_LABELS[e.source] || e.source) + ', ' + KIND_LABELS[e.kind] + ') → ' + group));
          (used[k] || []).forEach(function (n) { if (n !== group && taken.indexOf(n) < 0) { taken.push(n); } });
        });
        if (taken.length) {
          var w = el('div', 'geo-warn warn');
          w.appendChild(el('span', 'geo-warn-tag', 'ПЕРЕХВАТ'));
          w.appendChild(el('div', null, 'Эти наборы уже работают в: ' + taken.join(', ') + '. Правила ' + group +
            ' проверяются раньше, поэтому группа ' + group + ' заберёт (перехватит) этот трафик себе. ' +
            'Если нужно просто поменять, куда идёт трафик сервиса, - выберите это в панели Mihomo, новая группа не нужна.'));
          preview.appendChild(w);
        }
      }
      function show(cat) {
        clear(results);
        var used = model.usedSources();
        var groups = searchCatalog(cat, q.value, 30);
        if (!q.value.trim()) { results.appendChild(el('p', 'hint', 'Начните вводить название сервиса.')); return; }
        if (!groups.length) {
          results.appendChild(el('p', 'hint', 'Ничего не нашлось. Можно создать свой сервис и добавить ему домены вручную.'));
          return;
        }
        groups.forEach(function (g) {
          results.appendChild(el('div', 'geo-group-title', g.title));
          g.items.forEach(function (e) {
            var k = e.name + '@' + e.kind;
            var lab = el('label', 'geo-country' + (picked[k] ? ' on' : ''));
            var cb = el('input'); cb.type = 'checkbox'; cb.checked = !!picked[k];
            var usedBy = used[k] || [];
            if (target && usedBy.indexOf(target.name) >= 0) { cb.disabled = true; }
            cb.addEventListener('change', function () {
              if (cb.checked) { picked[k] = e; } else { delete picked[k]; }
              lab.className = 'geo-country' + (cb.checked ? ' on' : '');
              if (nameIn && cb.checked && !nameIn.value.trim()) { nameIn.value = suggestName(g.title); }
              updatePreview();
            });
            lab.appendChild(cb);
            lab.appendChild(el('span', 'geo-name', e.name + ' · ' + KIND_LABELS[e.kind]));
            lab.appendChild(el('span', 'geo-code', (SOURCE_LABELS[e.source] || e.source) +
              (usedBy.length ? ' · уже в: ' + usedBy.join(', ') : '')));
            results.appendChild(lab);
          });
        });
      }
      if (nameIn) { nameIn.addEventListener('input', updatePreview); }
      updatePreview();
      results.appendChild(el('p', 'hint', 'Загружаю базу...'));
      loadCatalog().then(function (cat) {
        show(cat);
        q.addEventListener('input', function () { show(cat); });
      })['catch'](function (e) { clear(results); results.appendChild(el('p', 'msg-err', 'База не загрузилась: ' + errText(e))); });

      ok.addEventListener('click', function () {
        err.textContent = '';
        var id = targetId, created = false, note = '';
        try {
          if (!target) {
            // имя занято существующей группой - подключить наборы к ней
            var existing = model.findByName(nameIn.value.trim());
            if (existing) { id = existing; note = 'Группа ' + nameIn.value.trim() + ' уже есть - наборы подключены к ней.'; }
            else { id = model.addService(nameIn.value.trim(), secSel.value); created = true; }
          }
          // сначала проверить все отмеченные наборы, потом добавлять - без «половины»
          keys().forEach(function (k) { var e = picked[k]; model.checkSource(id, e.name, e.kind, e.url); });
          keys().forEach(function (k) { var e = picked[k]; model.addSource(id, e.name, e.kind, e.url); });
        } catch (e) {
          if (created) { model.removeUserService(id); }
          err.textContent = e.message; return;
        }
        close();
        expanded[id] = true;
        msg(note, note ? 'ok' : null);
        draw();
      });
      d.showModal();
      q.focus();
    }

    function draw() {
      var services = model.services();
      clear(svcHost);
      var top = el('div', 'btn-row');
      var addFromBase = button('+ Добавить сервис из базы', 'submit');
      addFromBase.style.marginTop = '0';
      addFromBase.addEventListener('click', function () { openAdd(null); });
      top.appendChild(addFromBase);
      svcHost.appendChild(top);
      model.sections().forEach(function (sec) {
        var inSec = services.filter(function (s) { return s.section === sec.id; });
        if (!inSec.length) { return; }
        svcHost.appendChild(el('div', 'geo-group-title', sec.title));
        var rows = el('div', 'xk-rows');
        inSec.forEach(function (s) { rows.appendChild(serviceRow(s)); });
        svcHost.appendChild(rows);
      });
      // свой сервис без набора из базы - только с доменами
      svcHost.appendChild(el('div', 'geo-group-title', 'Свой сервис вручную'));
      var add = el('div', 'xk-add');
      var name = el('input'); name.type = 'text'; name.placeholder = 'Имя группы, например Netflix';
      name.setAttribute('aria-label', 'Имя своего сервиса');
      var secSel = el('select'); secSel.setAttribute('aria-label', 'Раздел');
      model.sections().forEach(function (sec) { var o = el('option', null, sec.title); o.value = sec.id; secSel.appendChild(o); });
      secSel.value = 'other';
      var addBtn = button('Создать', 'submit');
      addBtn.addEventListener('click', function () {
        var id = null;
        edit(function () { id = model.addService(name.value.trim(), secSel.value); });
        if (id) { expanded[id] = true; draw(); }
      });
      add.appendChild(name); add.appendChild(secSel); add.appendChild(addBtn);
      svcHost.appendChild(add);
      svcHost.appendChild(el('p', 'hint', 'Новый сервис появится как группа с выбором (как остальные); добавьте ему домены.'));

      clear(domHost);
      var any = false;
      var rows2 = el('div', 'xk-rows');
      services.forEach(function (s) {
        if (s.deleted) { return; }
        model.domains(s.id).forEach(function (d) {
          if (d.builtin) { return; }
          any = true;
          var r = domainRow(s.id, d);
          r.insertBefore(el('span', 'geo-code', '→ ' + s.name), r.lastChild);
          rows2.appendChild(r);
        });
      });
      if (!any) { rows2.appendChild(el('div', 'xk-empty', 'Своих доменов пока нет.')); }
      domHost.appendChild(rows2);
      domHost.appendChild(addDomainRow(services, null));
      refreshChanges();
    }

    function body() {
      var st = model.serialize();
      st.geofilter = geofilter;
      return stateBody(st);
    }
    function post(url) {
      return fetchJson(url, { method: 'POST', body: body(), headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }

    diffBtn.addEventListener('click', function () {
      busy(true); clear(chOut); chOut.appendChild(el('p', 'hint', 'Собираю конфиг на роутере...'));
      Promise.all([fetchJson('/api/config'), post('/api/constructor/preview')]).then(function (res) {
        if (!alive()) { return; }
        clear(chOut);
        if (res[1].check && !res[1].check.ok) {
          chOut.appendChild(el('p', 'msg-err', 'Собранный конфиг не проходит mihomo -t:'));
          chOut.appendChild(el('pre', null, res[1].check.output || ''));
        }
        opts.renderDiff(chOut, res[0].text || '', res[1].text || '', 'сейчас', 'после применения');
      })['catch'](function (e) { clear(chOut); chOut.appendChild(el('p', 'msg-err', 'Не удалось собрать: ' + errText(e))); })
        .then(function () { busy(false); refreshChanges(); });
    });

    applyBtn.addEventListener('click', function () {
      busy(true); clear(chOut);
      chOut.appendChild(el('p', 'hint', 'Применяю: сборка, mihomo -t, бэкап, перезапуск ядра - до пары минут...'));
      post('/api/constructor/apply?base=' + encodeURIComponent(data.base || '')).then(function (r) {
        if (!alive()) { return; }
        v.dirty = false;
        // перечитать состояние с роутера, сообщение - сверху новой страницы
        renderConstructor(modeBar, { renderDiff: opts.renderDiff, again: true, flash: r.unchanged
          ? 'Конфиг не изменился, настройки конструктора сохранены.'
          : ('Применено' + (r.restarted === false ? ' (ядро не перезапускалось - перезапустите XKeen вручную)' : ', ядро перезапущено') +
             (r.backup ? '. Бэкап прежнего конфига: ' + r.backup : '') + '.') });
      })['catch'](function (e) {
        clear(chOut);
        var d = e.data || {};
        if (d.error === 'check_failed' && d.check) {
          chOut.appendChild(el('p', 'msg-err', 'Конфиг не прошёл mihomo -t - ничего не записано:'));
          chOut.appendChild(el('pre', null, d.check.output || ''));
        } else if (d.error === 'restart_failed') {
          if (d.base) { data.base = d.base; }
          chOut.appendChild(el('p', 'msg-err', 'Ядро не поднялось с новым конфигом' + (d.rolled_back ? ' - вернул прежний конфиг.' : ' - откат не удался, проверьте по SSH.')));
        } else if (d.error === 'conflict') {
          // config.yaml поменяли с момента открытия - правки конструктора от
          // текста не зависят: берём новый отпечаток и применяем ещё раз
          chOut.appendChild(el('p', 'msg-err', 'config.yaml изменился, пока была открыта вкладка (например, в YAML-режиме). ' +
            'Ваши правки сохранены - нажмите «Проверить и применить» ещё раз.'));
          fetchJson('/api/constructor').then(function (fresh) { if (alive()) { data.base = fresh.base; } })['catch'](function () {});
        } else {
          chOut.appendChild(el('p', 'msg-err', 'Не применено: ' + errText(e)));
        }
        busy(false); refreshChanges();
      });
    });

    resetBtn.addEventListener('click', function () {
      if (v.dirty && !window.confirm('Отменить все несохранённые изменения конструктора?')) { return; }
      v.dirty = false;
      renderConstructor(modeBar, { renderDiff: opts.renderDiff, again: true });
    });

    draw();
  })['catch'](function (err) {
    if (!alive()) { return; }
    showError('Не удалось загрузить конструктор: ', { message: errText(err) });
    app.insertBefore(modeBar, app.firstChild);
  });
}
