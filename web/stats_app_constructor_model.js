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
  if (!name) { throw new Error('Введите имя группы'); }
  if ( /[,#:'"]/.test(name) || /^ /.test(name) || / $/.test(name)) {
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

// Куда группа смотрит по умолчанию: первым в списке proxies ставится
// выбранное, остальные - как у select-default шаблона (порядок и состав -
// те же, что в anchors config.example.yaml).
export var ROUTES = ['DIRECT', 'Заблок. сервисы', '🚀 Авто по пингу', '🛡️Fallback-Stable', '⚙️Manual'];

function routeLine(id, route) {
  var list = [route].concat(ROUTES.filter(function (r) { return r !== route; }));
  return ['gkey', id, 'proxies: [' + list.map(function (r) { return /^[A-Za-z]+$/.test(r) ? r : "'" + r + "'"; }).join(', ') + ']'].join(TAB);
}

// Базовая часть шаблона (anchors и proxy-groups до сервисных групп, ответ
// /api/constructor, поле template_base): значения interval/tolerance и
// список proxies базовых групп, слова exclude-filter.
function unquote(v) {
  v = String(v).trim();
  if (/^'.*'$/.test(v)) { return v.slice(1, -1).replace(/''/g, "'"); }
  if (/^".*"$/.test(v)) { return v.slice(1, -1); }
  return v;
}

export function proxyTokens(line) {
  var st = String(line).indexOf('proxies: [');
  if (st < 0) { return []; }
  var out = [], tok = '', q = '';
  for (var j = st + 10; j < line.length; j++) {
    var ch = line.charAt(j);
    if (q) {
      tok += ch;
      if (ch === q) { if (q === "'" && line.charAt(j + 1) === "'") { tok += "'"; j++; } else { q = ''; } }
    } else if (ch === "'" || ch === '"') { q = ch; tok += ch; }
    else if (ch === ',' || ch === ']') {
      if (tok.trim()) { out.push(unquote(tok)); }
      tok = '';
      if (ch === ']') { break; }
    } else { tok += ch; }
  }
  return out;
}

export function parseTemplateBase(text) {
  var res = { groups: {}, order: [], selectDefault: [], geofilter: '' };
  var sect = '', cur = null;
  lines(text).forEach(function (l) {
    if (/^[A-Za-z0-9_-]+:/.test(l)) { sect = l.replace(/:.*/, ''); cur = null; return; }
    var gm = /exclude-filter: &geofilter '([^']*)'/.exec(l);
    if (gm) { res.geofilter = gm[1].replace(/^\(\?i\)/, ''); }
    if (sect === 'anchors' && /^  select-default: &select-default /.test(l)) { res.selectDefault = proxyTokens(l); }
    if (sect !== 'proxy-groups') { return; }
    var nm = /^  - name:\s*(.*)$/.exec(l);
    if (nm) {
      cur = { interval: null, tolerance: null, tokens: [] };
      var name = unquote(nm[1]);
      res.groups[name] = cur; res.order.push(name);
      return;
    }
    if (!cur) { return; }
    var kv = /^    (interval|tolerance):\s*([0-9]+)\s*$/.exec(l);
    if (kv) { cur[kv[1]] = Number(kv[2]); }
    else if (/^    proxies: \[/.test(l)) { cur.tokens = proxyTokens(l); }
  });
  return res;
}

export function createModel(defaultsText, servicesText, userRulesText, templateBase) {
  var d = parseDefaults(defaultsText);
  var tb = parseTemplateBase(templateBase);
  var deleted = {};          // id встроенного -> true
  var unruled = [];          // [{owner, text}] в порядке
  var users = [];            // свои сервисы [{id,name,section,extra:[строки icon/gkey]}]
  var srcLines = [];         // строки src как есть
  var doms = [];             // [{owner,type,value}]
  var provLines = [];        // строки prov как есть
  var userRules = [];
  var bsets = [];            // [{group,key,value}] отличия базовых групп
  var bfirsts = [];          // [{group,value}] первое значение proxies

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
    else if (f[0] === 'bset') { bsets.push({ group: f[1], key: f[2], value: Number(f[3]) }); }
    else if (f[0] === 'bfirst') { bfirsts.push({ group: f[1], value: f.slice(2).join(TAB) }); }
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
    // Наборы правил, подключённые к сервису (строки src).
    sources: function (id) {
      return srcLines.filter(function (l) { var f = l.split(TAB); return f[0] === 'src' && f[1] === id; })
        .map(function (l) { var f = l.split(TAB); return { name: f[2], kind: f[3], url: f[4] }; });
    },
    // Какие наборы (имя@вид) уже используются и какими сервисами:
    // встроенные правила RULE-SET и подключённые src.
    usedSources: function () {
      var used = {};
      function add(key, name) { (used[key] = used[key] || []).indexOf(name) < 0 && used[key].push(name); }
      d.rules.forEach(function (r) {
        if (r.owner === '-' || deleted[r.owner] || isUnruled(r.owner, r.text)) { return; }
        var s = service(r.owner), re = /RULE-SET,([^,)]+)/g, m;
        while ((m = re.exec(r.text))) { add(m[1], s ? s.name : r.owner); }
      });
      srcLines.forEach(function (l) {
        var f = l.split(TAB);
        if (f[0] === 'src') { var s = service(f[1]); add(f[2] + '@' + f[3], s ? s.name : f[1]); }
      });
      return used;
    },
    // Свой или живой встроенный сервис с таким именем группы, или null.
    findByName: function (name) {
      var hit = model.services().filter(function (x) { return !x.deleted && x.name === name; })[0];
      return hit ? hit.id : null;
    },
    // Проверка набора без добавления (чтобы проверить все отмеченные заранее).
    checkSource: function (id, name, kind, url) {
      var s = needService(id);
      if (!/^[A-Za-z0-9][A-Za-z0-9._!-]*$/.test(name)) { throw new Error('Имя набора: только латиница, цифры и . _ ! -'); }
      if (['domain', 'ipcidr', 'classical'].indexOf(kind) < 0) { throw new Error('Вид набора: domain, ipcidr или classical'); }
      if (!/^https?:\/\/[^ "'#]+$/.test(url)) { throw new Error('Адрес набора должен начинаться с http(s):// без пробелов и кавычек'); }
      var users = model.usedSources()[name + '@' + kind] || [];
      if (users.indexOf(s.name) >= 0) { throw new Error('Набор ' + name + ' уже подключён к ' + s.name); }
    },
    addSource: function (id, name, kind, url) {
      model.checkSource(id, name, kind, url);
      srcLines.push(['src', id, name, kind, url].join(TAB));
    },
    removeSource: function (id, name, kind) {
      srcLines = srcLines.filter(function (l) {
        var f = l.split(TAB);
        return !(f[0] === 'src' && f[1] === id && f[2] === name && f[3] === kind);
      });
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
    addService: function (name, section, route) {
      name = String(name || '');
      if (route && ROUTES.indexOf(route) < 0) { throw new Error('Неизвестное направление ' + route); }
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
      users.push({ id: id, name: name, section: section, extra: route ? [routeLine(id, route)] : [] });
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
    // Базовые группы шаблона: interval и tolerance (если есть у группы),
    // def - значение шаблона, value - с учётом отличий.
    baseGroups: function () {
      var out = [];
      tb.order.forEach(function (name) {
        var g = tb.groups[name];
        if (g.interval == null && g.tolerance == null) { return; }
        var row = { name: name, interval: null, tolerance: null };
        ['interval', 'tolerance'].forEach(function (k) {
          if (g[k] == null) { return; }
          var o = bsets.filter(function (x) { return x.group === name && x.key === k; })[0];
          row[k] = { def: g[k], value: o ? o.value : g[k] };
        });
        out.push(row);
      });
      return out;
    },
    setBase: function (name, key, value) {
      var g = tb.groups[name];
      if (!g || g[key] == null) { throw new Error('У группы ' + name + ' нет параметра ' + key); }
      var n = Number(value);
      if (String(value).trim() === '' || !/^[0-9]+$/.test(String(value).trim())) { throw new Error(key + ' - целое число'); }
      if (key === 'interval' && (n < 10 || n > 86400)) { throw new Error('interval - от 10 до 86400 секунд'); }
      if (key === 'tolerance' && n > 10000) { throw new Error('tolerance - от 0 до 10000 мс'); }
      bsets = bsets.filter(function (x) { return !(x.group === name && x.key === key); });
      if (n !== g[key]) { bsets.push({ group: name, key: key, value: n }); }
    },
    // Куда по умолчанию смотрят группы: «*» - сервисные группы шаблона
    // (якорь select-default), прочие - базовые группы с выбором. def -
    // первое значение шаблона, tokens - из чего выбирать.
    routes: function () {
      var out = [];
      function row(name, label, tokens) {
        var o = bfirsts.filter(function (x) { return x.group === name; })[0];
        out.push({ name: name, label: label, tokens: tokens, def: tokens[0], value: o ? o.value : tokens[0] });
      }
      if (tb.selectDefault.length) { row('*', 'Все сервисные группы', tb.selectDefault); }
      ['Заблок. сервисы'].forEach(function (n) {
        if (tb.groups[n] && tb.groups[n].tokens.length) { row(n, n, tb.groups[n].tokens); }
      });
      return out;
    },
    setRoute: function (name, token) {
      var r = model.routes().filter(function (x) { return x.name === name; })[0];
      if (!r) { throw new Error('Нет группы ' + name); }
      if (r.tokens.indexOf(token) < 0) { throw new Error('«' + token + '» нет в списке группы ' + name); }
      bfirsts = bfirsts.filter(function (x) { return x.group !== name; });
      if (token !== r.def) { bfirsts.push({ group: name, value: token }); }
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
      bsets.forEach(function (x) { out.push(['bset', x.group, x.key, x.value].join(TAB)); });
      bfirsts.forEach(function (x) { out.push(['bfirst', x.group, x.value].join(TAB)); });
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
        if (f[0] === 'src') { return added ? '+ набор ' + f[2] + ' → ' + nameOf(f[1]) : 'Убрать набор ' + f[2] + ' (' + nameOf(f[1]) + ')'; }
        if (f[0] === 'bset') { return added ? 'Группа ' + f[1] + ': ' + f[2] + ' = ' + f[3] : 'Группа ' + f[1] + ': ' + f[2] + ' как в шаблоне'; }
        if (f[0] === 'bfirst') {
          return added ? (f[1] === '*' ? 'Сервисные группы: по умолчанию ' : 'Группа ' + f[1] + ': по умолчанию ') + f[2]
            : (f[1] === '*' ? 'Сервисные группы' : 'Группа ' + f[1]) + ': по умолчанию как в шаблоне';
        }
        if (f[0] === 'icon') { return (added ? 'Иконка: ' : 'Убрана иконка: ') + nameOf(f[1]); }
        return (added ? 'Добавлено: ' : 'Убрано: ') + f.join(' ');
      }
      ['del', 'unrule', 'svc', 'src', 'dom', 'bset', 'bfirst', ''].forEach(function (kind) {
        function mine(l) {
          var k = l.split(TAB)[0];
          return kind ? k === kind : ['del', 'unrule', 'svc', 'src', 'dom', 'bset', 'bfirst'].indexOf(k) < 0;
        }
        // изменённое значение базовой группы - одна строка («стало»), без «было»
        function replaced(l) {
          var f = l.split(TAB);
          if (f[0] !== 'bset' && f[0] !== 'bfirst') { return false; }
          var n = f[0] === 'bset' ? 3 : 2;
          return after.some(function (a) { return a.split(TAB).slice(0, n).join(TAB) === f.slice(0, n).join(TAB); });
        }
        before.filter(mine).forEach(function (l) { if (after.indexOf(l) < 0 && !replaced(l)) { res.push(text(l, false)); } });
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
  // подписки и свои ноды - блок передаётся и пустым (пустой список - тоже
  // состояние); null - сервер этого не отдал, состояние не трогаем
  if (state.subscriptions != null) { out += '### MST-STATE subscriptions.tsv\n' + state.subscriptions; }
  if (state.proxies != null) { out += '### MST-STATE proxies.yaml\n' + state.proxies; }
  return out;
}

// ----- каталог наборов правил (config-tools/rule-catalog.tsv) -----

// Строки каталога -> [{name, kind, source, url, title}]; битые строки
// пропускаются.
export function parseCatalog(text) {
  var out = [];
  lines(text).forEach(function (l) {
    if (!l || l.charAt(0) === '#') { return; }
    var f = l.split(TAB);
    if (f.length !== 5 || !/^[A-Za-z0-9][A-Za-z0-9._!-]*$/.test(f[0]) || ['domain', 'ipcidr', 'classical'].indexOf(f[1]) < 0 ||
        !/^https?:\/\/[^ "'#]+$/.test(f[3])) { return; }
    out.push({ name: f[0], kind: f[1], source: f[2], url: f[3], title: f[4] });
  });
  return out;
}

// Дата сборки каталога из строки «# собран: ГГГГ-ММ-ДД», или ''.
export function parseCatalogDate(text) {
  var m = /^# собран: (\d{4}-\d{2}-\d{2})\s*$/m.exec(String(text || ''));
  return m ? m[1] : '';
}

// Поиск без учёта регистра по имени и названию. Результат - группы по
// имени без префикса источника (youtube: MetaCubeX, zxc-rv, itdog), лучшие
// совпадения первыми; не больше limit групп.
export function searchCatalog(entries, query, limit) {
  var q = String(query || '').trim().toLowerCase();
  if (!q) { return []; }
  var groups = {}, order = [];
  entries.forEach(function (e) {
    var key = e.name.replace(/^(itdog|legiz)-/, '');
    var hay = (e.name + ' ' + e.title).toLowerCase();
    if (hay.indexOf(q) < 0) { return; }
    if (!groups[key]) { groups[key] = { key: key, title: e.title, items: [], score: 9 }; order.push(key); }
    var g = groups[key];
    g.items.push(e);
    var score = key === q ? 0 : (key.indexOf(q) === 0 ? 1 : (e.title.toLowerCase().indexOf(q) === 0 ? 2 : 3));
    if (score < g.score) { g.score = score; }
  });
  return order.map(function (k) { return groups[k]; })
    .sort(function (a, b) { return a.score - b.score || (a.key < b.key ? -1 : (a.key > b.key ? 1 : 0)); })
    .slice(0, limit || 30)
    .map(function (g) { return { key: g.key, title: g.title, items: g.items }; });
}
