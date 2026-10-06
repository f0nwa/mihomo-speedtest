// Модель конструктора конфига (вкладка «Конфиг», режим «Конструктор») -
// без DOM, проверяется node (tests/test_constructor_model.sh).
//
// Встроенные сервисы - services.default.tsv, отличия пользователя -
// config-state/services.tsv, свои правила - config-state/user-rules.txt.
// Форматы - в шапке config-tools/render_services.awk; порядок сериализации
// отличий тот же, что у config-tools/config_to_state.awk: del, unrule,
// svc (+icon, gkey), src, dom, prov. Проверки имени группы и домена - те
// же, что в render_services.awk, чтобы ошибка была видна до отправки.
// См. docs/superpowers/specs/2026-10-05-config-constructor-design.md.

var TAB = '\t';
var DOMAIN_TYPES = { suffix: 'DOMAIN-SUFFIX', full: 'DOMAIN', keyword: 'DOMAIN-KEYWORD' };
var TYPE_OF = { 'DOMAIN-SUFFIX': 'suffix', 'DOMAIN': 'full', 'DOMAIN-KEYWORD': 'keyword' };

function lines(text) {
  return String(text || '').split('\n').map(function (l) { return l.replace(/\r$/, ''); });
}

// Текст правила без хвостового комментария.
function ruleBody(text) { return String(text).replace(/[ \t]+#.*$/, '').trim(); }

export function checkName(name) {
  if (!name || /[,#:'"]/.test(name) || /^ /.test(name) || / $/.test(name)) {
    throw new Error('Имя группы: нельзя запятую, #, двоеточие, кавычки и пробелы по краям');
  }
}

export function checkDomain(value) {
  if (/[^\x00-\x7f]/.test(value)) {
    throw new Error('Домен с кириллицей записывается в punycode: например, сайт.рф - это xn--80aswg.xn--p1ai');
  }
  if (!/^[A-Za-z0-9*._-]+$/.test(value)) {
    throw new Error('Домен: только латиница, цифры и . - _ *');
  }
}

// Вставленный адрес -> домен: без схемы, пути, порта и точек по краям.
export function cleanDomain(value) {
  return String(value || '').trim().toLowerCase()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//, '').replace(/[/?#].*$/, '').replace(/:\d+$/, '')
    .replace(/^\.+/, '').replace(/\.+$/, '');
}

// Имена, которые нельзя дать своей группе: группы шаблона и цели правил.
var RESERVED = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL', 'MST-SPEEDTEST',
  'Заблок. сервисы', '⚡ Быстрый пул', '⚡ Самые быстрые + Fallback', '🚀 Авто по пингу', '🛡️Fallback-Stable', '⚙️Manual'];

export function parseDefaults(text) {
  var d = { sections: [], services: [], byId: {}, rules: [] };
  lines(text).forEach(function (line) {
    if (!line || line.charAt(0) === '#') { return; }
    var f = line.split(TAB);
    if (f[0] === 'section') { d.sections.push({ id: f[1], title: f[2] }); }
    else if (f[0] === 'svc') {
      var s = { id: f[1], name: f[2], section: f[3] };
      d.services.push(s); d.byId[s.id] = s;
    } else if (f[0] === 'rule') { d.rules.push({ owner: f[1], text: f[2] }); }
  });
  return d;
}

export function createModel(defaultsText, servicesText, userRulesText) {
  var d = parseDefaults(defaultsText);
  var deleted = {};          // id встроенного -> true
  var unruled = [];          // [{owner, text}] в порядке
  var users = [];            // свои сервисы [{id,name,section,extra:[строки icon/gkey]}]
  var srcLines = [];         // строки src как есть
  var doms = [];             // [{owner,type,value}]
  var provLines = [];        // строки prov как есть
  var userRules = [];

  lines(servicesText).forEach(function (line) {
    if (!line || line.charAt(0) === '#') { return; }
    var f = line.split(TAB);
    if (f[0] === 'del') { deleted[f[1]] = true; }
    else if (f[0] === 'unrule') { unruled.push({ owner: f[1], text: f.slice(2).join(TAB) }); }
    else if (f[0] === 'svc') { users.push({ id: f[1], name: f[2], section: f[3], extra: [] }); }
    else if (f[0] === 'icon' || f[0] === 'gkey') {
      var u = findUser(f[1]);
      if (u) { u.extra.push(line); } else { srcLines.push(line); }
    } else if (f[0] === 'src') { srcLines.push(line); }
    else if (f[0] === 'dom') { doms.push({ owner: f[1], type: f[2], value: f[3] }); }
    else { provLines.push(line); }
  });
  lines(userRulesText).forEach(function (l) { l = l.trim(); if (l) { userRules.push(l); } });

  function findUser(id) {
    for (var i = 0; i < users.length; i++) { if (users[i].id === id) { return users[i]; } }
    return null;
  }
  function service(id) { return findUser(id) || d.byId[id] || null; }
  function isUnruled(owner, text) {
    return unruled.some(function (u) { return u.owner === owner && u.text === text; });
  }
  function builtinDomainRule(owner, type, value) {
    var s = d.byId[owner];
    if (!s) { return null; }
    for (var i = 0; i < d.rules.length; i++) {
      var r = d.rules[i];
      if (r.owner !== owner) { continue; }
      var m = /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),([^,]+),(.+)$/.exec(ruleBody(r.text));
      if (m && m[3] === s.name && TYPE_OF[m[1]] === type && m[2].toLowerCase() === value) { return r; }
    }
    return null;
  }
  function allNames() {
    var n = {};
    d.services.forEach(function (s) { if (!deleted[s.id]) { n[s.name] = true; } });
    users.forEach(function (u) { n[u.name] = true; });
    return n;
  }
  function needService(id) {
    var s = service(id);
    if (!s) { throw new Error('Нет сервиса ' + id); }
    return s;
  }

  var model = {
    sections: function () { return d.sections.slice(); },
    services: function () {
      // свой сервис с id или именем встроенного заменяет его (render_services.awk)
      var out = d.services.filter(function (s) {
        return !users.some(function (u) { return u.id === s.id || u.name === s.name; });
      }).map(function (s) {
        return { id: s.id, name: s.name, section: s.section, user: false, deleted: !!deleted[s.id] };
      });
      users.forEach(function (u) { out.push({ id: u.id, name: u.name, section: u.section, user: true, deleted: false }); });
      return out;
    },
    // Домены сервиса: встроенные доменные правила (removed - убраны unrule)
    // и свои.
    domains: function (id) {
      var s = needService(id), out = [];
      if (d.byId[id] && !findUser(id)) {
        d.rules.forEach(function (r) {
          if (r.owner !== id) { return; }
          var m = /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),([^,]+),(.+)$/.exec(ruleBody(r.text));
          if (m && m[3] === s.name) {
            out.push({ type: TYPE_OF[m[1]], value: m[2].toLowerCase(), builtin: true, removed: isUnruled(id, r.text) });
          }
        });
      }
      doms.forEach(function (x) {
        if (x.owner === id) { out.push({ type: x.type, value: x.value.toLowerCase(), builtin: false, removed: false }); }
      });
      return out;
    },
    // Не-доменные встроенные правила сервиса (наборы, GEOSITE, OR...).
    rules: function (id) {
      var s = needService(id), out = [];
      if (findUser(id)) { return out; }
      d.rules.forEach(function (r) {
        if (r.owner !== id) { return; }
        var m = /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),([^,]+),(.+)$/.exec(ruleBody(r.text));
        if (m && m[3] === s.name) { return; }
        out.push({ text: r.text, removed: isUnruled(id, r.text) });
      });
      return out;
    },
    // Наборы правил своего сервиса (строки src) - только для показа.
    sources: function (id) {
      return srcLines.filter(function (l) { var f = l.split(TAB); return f[0] === 'src' && f[1] === id; })
        .map(function (l) { var f = l.split(TAB); return f[2] + '@' + f[3]; });
    },
    deleteService: function (id) { if (d.byId[id] && !findUser(id)) { deleted[id] = true; } },
    restoreService: function (id) {
      var s = d.byId[id];
      if (!s || !deleted[id]) { return; }
      if (users.some(function (u) { return u.name === s.name; })) {
        throw new Error('Есть свой сервис с именем ' + s.name + ' - сначала удалите его');
      }
      delete deleted[id];
    },
    addService: function (name, section) {
      name = String(name || '');
      checkName(name);
      if (!d.sections.some(function (x) { return x.id === section; })) { throw new Error('Нет раздела ' + section); }
      if (allNames()[name]) { throw new Error('Группа ' + name + ' уже есть'); }
      if (RESERVED.some(function (r) { return r.toLowerCase() === name.toLowerCase(); })) {
        throw new Error('Имя ' + name + ' занято группой шаблона или служебным словом');
      }
      var base = name.toLowerCase().replace(/[^a-z0-9_-]/g, '');
      if (!/^[a-z0-9]/.test(base)) { base = ''; }
      var taken = function (x) { return !!d.byId[x] || !!findUser(x); };
      var id = base, k = base ? 2 : 1;
      while (!id || taken(id)) { id = (base || 'svc') + k; k++; }
      users.push({ id: id, name: name, section: section, extra: [] });
      return id;
    },
    removeUserService: function (id) {
      users = users.filter(function (u) { return u.id !== id; });
      doms = doms.filter(function (x) { return x.owner !== id; });
      srcLines = srcLines.filter(function (l) { return l.split(TAB)[1] !== id; });
    },
    addDomain: function (id, type, value) {
      needService(id);
      if (!DOMAIN_TYPES[type]) { throw new Error('Тип домена: suffix, full или keyword'); }
      value = cleanDomain(value);
      checkDomain(value);
      var r = findUser(id) ? null : builtinDomainRule(id, type, value);
      if (r && isUnruled(id, r.text)) { model.restoreRule(id, r.text); return; }
      if (r || doms.some(function (x) { return x.owner === id && x.type === type && x.value.toLowerCase() === value; })) {
        throw new Error('Домен ' + value + ' уже есть');
      }
      doms.push({ owner: id, type: type, value: value });
    },
    removeDomain: function (id, type, value) {
      var r = findUser(id) ? null : builtinDomainRule(id, type, value);
      if (r) { model.removeRule(id, r.text); return; }
      doms = doms.filter(function (x) { return !(x.owner === id && x.type === type && x.value.toLowerCase() === String(value).toLowerCase()); });
    },
    removeRule: function (id, text) { if (!isUnruled(id, text)) { unruled.push({ owner: id, text: text }); } },
    restoreRule: function (id, text) {
      unruled = unruled.filter(function (u) { return !(u.owner === id && u.text === text); });
    },
    userRules: function () { return userRules.join('\n'); },
    setUserRules: function (text) {
      var out = [];
      lines(text).forEach(function (l) {
        l = l.trim();
        if (!l) { return; }
        if (/\t/.test(l)) { throw new Error('Табуляция в правиле недопустима'); }
        if (/^-/.test(l)) { throw new Error('Правило пишется без ведущего «- »'); }
        out.push(l);
      });
      userRules = out;
    },
    serialize: function () {
      var out = [];
      d.services.forEach(function (s) { if (deleted[s.id]) { out.push('del' + TAB + s.id); } });
      unruled.forEach(function (u) { out.push(['unrule', u.owner, u.text].join(TAB)); });
      users.forEach(function (u) {
        out.push(['svc', u.id, u.name, u.section].join(TAB));
        u.extra.forEach(function (l) { out.push(l); });
      });
      srcLines.forEach(function (l) { out.push(l); });
      // домены убранного встроенного сервиса сохраняются (сборка их
      // пропускает) - «Вернуть» сервис возвращает и их
      doms.forEach(function (x) { out.push(['dom', x.owner, x.type, x.value].join(TAB)); });
      provLines.forEach(function (l) { out.push(l); });
      return {
        services: out.length ? out.join('\n') + '\n' : '',
        user_rules: userRules.length ? userRules.join('\n') + '\n' : ''
      };
    },
    // Сводка изменений относительно прежней сериализации - человеческим языком.
    summary: function (initial) {
      var cur = model.serialize();
      var before = lines(initial.services).filter(Boolean), after = lines(cur.services).filter(Boolean);
      var res = [];
      function nameOf(id) { if (id === '-') { return 'общее правило'; } var s = service(id); return s ? s.name : id; }
      function text(line, added) {
        var f = line.split(TAB);
        if (f[0] === 'del') { return (added ? 'Убрать сервис ' : 'Вернуть сервис ') + nameOf(f[1]); }
        if (f[0] === 'unrule') {
          var dm = /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),([^,]+),/.exec(ruleBody(f.slice(2).join(TAB)));
          if (dm && f[1] !== '-') { return (added ? 'Убрать домен ' : 'Вернуть домен ') + dm[2].toLowerCase() + ' (' + nameOf(f[1]) + ')'; }
          return (added ? 'Убрать правило ' : 'Вернуть правило ') + f.slice(2).join(TAB) + ' (' + nameOf(f[1]) + ')';
        }
        if (f[0] === 'svc') { return (added ? 'Новый сервис ' : 'Удалить свой сервис ') + f[2]; }
        if (f[0] === 'dom') { return added ? '+ домен ' + f[3] + ' → ' + nameOf(f[1]) : 'Убрать домен ' + f[3] + ' (' + nameOf(f[1]) + ')'; }
        if (f[0] === 'icon') { return (added ? 'Иконка: ' : 'Убрана иконка: ') + nameOf(f[1]); }
        return (added ? 'Добавлено: ' : 'Убрано: ') + f.join(' ');
      }
      ['del', 'unrule', 'svc', 'dom', ''].forEach(function (kind) {
        function mine(l) {
          var k = l.split(TAB)[0];
          return kind ? k === kind : ['del', 'unrule', 'svc', 'dom'].indexOf(k) < 0;
        }
        before.filter(mine).forEach(function (l) { if (after.indexOf(l) < 0) { res.push(text(l, false)); } });
        after.filter(mine).forEach(function (l) { if (before.indexOf(l) < 0) { res.push(text(l, true)); } });
      });
      if ((initial.user_rules || '') !== cur.user_rules) { res.push('Свои правила изменены'); }
      return res;
    }
  };
  return model;
}

// Тело запроса preview/apply (stats_constructor.sh): блоки ### MST-STATE.
// Пустые свои правила и фильтр не передаются (нет блока - нет файла);
// services.tsv передаётся всегда.
export function stateBody(state) {
  var out = '### MST-STATE services.tsv\n' + (state.services || '');
  if (state.user_rules) { out += '### MST-STATE user-rules.txt\n' + state.user_rules; }
  if (state.geofilter) { out += '### MST-STATE geofilter.txt\n' + state.geofilter; }
  return out;
}
