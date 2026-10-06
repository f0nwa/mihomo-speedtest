// Модель блоков конструктора конфига «Подписки», «Свои прокси» и «Исключения
// нод» - без DOM, проверяется node (tests/test_constructor_modules_model.sh).
// Проверки - те же, что у migrate_config.awk (подписки, ноды) и
// render_services.awk (слова фильтра): сервер всё равно перепроверит, но
// ошибку человек видит сразу.
//
// Состояние (файлы $DIR/config-state/):
//   subscriptions.tsv  url<TAB>User-Agent<TAB>имя, по строке на подписку;
//   proxies.yaml       блок своих нод: записи "  - name: ..." с вложенными
//                      строками (без заголовка proxies:);
//   geofilter.txt      слова фильтра нод, по слову в строке (нет - слова
//                      шаблона).

var TAB = '\t';

function lines(text) {
  return String(text || '').replace(/\r/g, '').split('\n');
}

function yq(v) { return "'" + String(v).replace(/'/g, "''") + "'"; }

// ----- подписки -----

// User-Agent, под которыми панели подписок отдают нужный формат
// (config-tools/detect_ua.sh); первый - как в шаблоне.
export var UA_PRESETS = ['v2rayNG/1.8.0', 'clash.meta', 'mihomo/1.18.0', 'clash-verge/v2.0.5', 'ClashforWindows/0.20.39', 'Shadowrocket/1897'];

export function parseSubs(text) {
  var out = [];
  lines(text).forEach(function (l) {
    if (!l) { return; }
    var f = l.split(TAB);
    if (f.length < 3) { return; }
    out.push({ url: f[0], ua: f[1], name: f[2] });
  });
  return out;
}

export function serializeSubs(list) {
  return list.map(function (s) { return [s.url, s.ua, s.name].join(TAB); }).join('\n') + (list.length ? '\n' : '');
}

export function checkSubName(name, others) {
  if (!/^[A-Za-z0-9_-]+$/.test(name || '')) { throw new Error('Имя подписки: латиница, цифры, - и _'); }
  if (name === 'fast') { throw new Error('Имя fast занято быстрым пулом'); }
  if (others.indexOf(name) >= 0) { throw new Error('Подписка ' + name + ' уже есть'); }
}

export function checkSubUrl(url) {
  if (!/^https?:\/\/[^ "\\\t]+$/.test(url || '')) {
    throw new Error('Адрес подписки должен начинаться с http:// или https:// и не содержать пробелов, кавычек и обратных косых черт');
  }
}

export function checkUa(ua) {
  if (/["\\\t\r\n]/.test(ua || '')) { throw new Error('User-Agent: нельзя кавычки, обратную косую черту и табуляцию'); }
}

// Имя подписки по адресу: домен без www и зоны, латиницей; занятое -
// с номером.
export function suggestSubName(url, taken) {
  var m = /^https?:\/\/([^\/?#:]+)/.exec(url || '');
  var base = m ? m[1].toLowerCase().replace(/^www\./, '').split('.').slice(0, -1).join('-') || m[1] : 'sub';
  base = base.replace(/[^a-z0-9_-]/g, '-').replace(/^-+|-+$/g, '').replace(/-+/g, '-') || 'sub';
  if (base === 'fast') { base = 'fast-sub'; }
  var name = base, k = 2;
  while (taken.indexOf(name) >= 0) { name = base + '-' + k; k++; }
  return name;
}

// ----- свои прокси -----

// Записи блока proxies: с первой строкой "  - ..." и вложенными строками.
export function parseProxies(text) {
  var out = [], cur = null;
  lines(text).forEach(function (l) {
    if (!l.trim() || /^\s*#/.test(l)) { return; }
    if (/^  - /.test(l)) {
      cur = { lines: [l] };
      out.push(cur);
    } else if (cur) { cur.lines.push(l); }
  });
  out.forEach(function (p) {
    p.name = fieldOf(p, 'name');
    p.type = fieldOf(p, 'type');
    p.server = fieldOf(p, 'server');
    p.port = fieldOf(p, 'port');
  });
  return out;
}

function unq(v) {
  v = String(v).trim().replace(/\s+#.*$/, '');
  if (/^'.*'$/.test(v)) { return v.slice(1, -1).replace(/''/g, "'"); }
  if (/^".*"$/.test(v)) { return v.slice(1, -1); }
  return v;
}

function fieldOf(p, key) {
  var re = new RegExp('^(?:  - |    )' + key + ':[ ]*(.*)$');
  for (var i = 0; i < p.lines.length; i++) {
    var m = re.exec(p.lines[i]);
    if (m) { return unq(m[1]); }
  }
  return '';
}

export function serializeProxies(list) {
  var out = [];
  list.forEach(function (p) { p.lines.forEach(function (l) { out.push(l); }); });
  return out.length ? out.join('\n') + '\n' : '';
}

export function checkProxyName(name, others) {
  var n = String(name || '');
  if (!n || /[\x00-\x1f\x7f|]/.test(n) || /^\s|\s$/.test(n)) { throw new Error('Имя ноды: непустое, без | и управляющих символов, без пробелов по краям'); }
  if (Array.from(n).length > 64) { throw new Error('Имя ноды длиннее 64 символов'); }
  if (others.indexOf(n) >= 0) { throw new Error('Нода «' + n + '» уже есть'); }
}

// Записи из вставленного YAML (записи "  - name: ..."), с отступом 2.
export function proxiesFromYaml(text) {
  var src = lines(text);
  // вставка без отступа ("- name: ...") сдвигается на 2 пробела
  var base = -1;
  src.forEach(function (l) { if (base < 0 && /^\s*- /.test(l)) { base = l.indexOf('-'); } });
  if (base < 0) { throw new Error('Нужны записи нод: «- name: ...» с полями type, server, port'); }
  var shifted = src.filter(function (l) { return l.trim() && !/^\s*#/.test(l); }).map(function (l) {
    if (/\t/.test(l)) { throw new Error('Табуляция в YAML недопустима - только пробелы'); }
    var cut = Math.min(base, l.length - l.replace(/^ +/, '').length);
    return '  ' + l.slice(cut);
  });
  var list = parseProxies(shifted.join('\n'));
  if (!list.length) { throw new Error('Нужны записи нод: «- name: ...»'); }
  list.forEach(function (p) {
    if (!/^  - name:[ ]*\S/.test(p.lines[0])) { throw new Error('Первым ключом каждой ноды должен идти name'); }
    if (!p.type) { throw new Error('У ноды «' + p.name + '» нет type'); }
  });
  return list;
}

function b64decode(s) {
  var t = String(s).replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, '');
  while (t.length % 4) { t += '='; }
  var bin = atob(t), bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
  return new TextDecoder('utf-8').decode(bytes);
}

function dec(s) {
  try { return decodeURIComponent(String(s)); } catch (e) { return String(s); }
}

function parseLink(link) {
  var m = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/(.*)$/.exec(String(link || '').trim());
  if (!m) { throw new Error('Ссылка должна выглядеть как hy2://..., vless://..., trojan://..., ss:// или vmess://'); }
  var rest = m[2], frag = '', query = '';
  var h = rest.indexOf('#');
  if (h >= 0) { frag = dec(rest.slice(h + 1)); rest = rest.slice(0, h); }
  var qi = rest.indexOf('?');
  if (qi >= 0) { query = rest.slice(qi + 1); rest = rest.slice(0, qi); }
  return { scheme: m[1].toLowerCase(), rest: rest, query: new URLSearchParams(query), name: frag };
}

// "user@host:port/путь" -> {user, host, port}
function authority(rest) {
  var path = rest.indexOf('/');
  if (path >= 0) { rest = rest.slice(0, path); }
  var at = rest.lastIndexOf('@'), user = '';
  if (at >= 0) { user = dec(rest.slice(0, at)); rest = rest.slice(at + 1); }
  var hm = /^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/.exec(rest);
  if (!hm) { throw new Error('В ссылке не разобрать адрес сервера'); }
  var host = hm[1].replace(/^\[|\]$/g, '');
  if (!/^[A-Za-z0-9._:-]+$/.test(host)) { throw new Error('Адрес сервера: недопустимые символы'); }
  var port = hm[2] ? Number(hm[2]) : 0;
  if (!(port >= 1 && port <= 65535)) { throw new Error('В ссылке нет порта или он вне 1-65535'); }
  return { user: user, host: host, port: port };
}

function noCtl(v, what) {
  if (/[\x00-\x1f\x7f]/.test(v)) { throw new Error(what + ': управляющие символы недопустимы'); }
  return v;
}

function listq(v) {
  return '[' + String(v).split(',').map(function (x) { return x.trim(); }).filter(Boolean).map(yq).join(', ') + ']';
}

// Общие для vless/vmess/trojan настройки транспорта и TLS -> строки полей.
function transportLines(net, p, host, sni) {
  var out = [];
  net = net || 'tcp';
  if (net === 'ws') {
    var ws = 'path: ' + yq(p.path || '/');
    if (host) { ws += ', headers: { Host: ' + yq(host) + ' }'; }
    out.push('    network: ws', '    ws-opts: { ' + ws + ' }');
  } else if (net === 'grpc') {
    out.push('    network: grpc', '    grpc-opts: { grpc-service-name: ' + yq(p.service || '') + ' }');
  } else if (net === 'h2') {
    out.push('    network: h2', '    h2-opts: { path: ' + yq(p.path || '/') + (host ? ', host: [' + yq(host) + ']' : '') + ' }');
  } else if (net === 'tcp') {
    out.push('    network: tcp');
  } else {
    throw new Error('Транспорт ' + net + ' не поддерживается (нужен tcp, ws, grpc или h2) - вставьте YAML ноды');
  }
  return out;
}

// Ссылка (hy2/hysteria2/vless/trojan/ss/vmess) -> {name, yaml}.
export function linkToProxy(link) {
  var L = parseLink(link), q = L.query, a, out = [], name = L.name, sni;
  function qv(k) { return noCtl(q.get(k) || '', k); }
  var t = L.scheme;
  if (t === 'vmess') {
    var j;
    try { j = JSON.parse(b64decode(L.rest)); } catch (e) { throw new Error('vmess: не разобрать тело ссылки'); }
    var port = Number(j.port);
    if (!(port >= 1 && port <= 65535) || !j.add || !j.id) { throw new Error('vmess: нет адреса, порта или id'); }
    if (!/^[A-Za-z0-9._:-]+$/.test(String(j.add))) { throw new Error('Адрес сервера: недопустимые символы'); }
    name = name || noCtl(String(j.ps || ''), 'имя');
    out.push('    type: vmess', '    server: ' + yq(j.add), '    port: ' + port, '    uuid: ' + yq(noCtl(String(j.id), 'id')),
      '    alterId: ' + (Number(j.aid) >= 0 ? Number(j.aid) : 0), '    cipher: ' + yq(j.scy || 'auto'), '    udp: true');
    if (j.tls === 'tls') {
      out.push('    tls: true');
      sni = j.sni || j.host; if (sni) { out.push('    servername: ' + yq(noCtl(String(sni), 'sni'))); }
    }
    transportLines(j.net, { path: j.path, service: j.path }, j.host && j.net !== 'grpc' ? String(j.host) : '', '').forEach(function (l) { out.push(l); });
  } else if (t === 'ss') {
    var body = L.rest, method, password, srv;
    if (body.indexOf('@') < 0) {
      var d;
      try { d = b64decode(body.replace(/\/.*$/, '')); } catch (e) { throw new Error('ss: не разобрать тело ссылки'); }
      body = d;
      var at = body.lastIndexOf('@');
      if (at < 0) { throw new Error('ss: нет адреса сервера'); }
      var cred = body.slice(0, at), ci = cred.indexOf(':');
      method = cred.slice(0, ci); password = cred.slice(ci + 1); a = authority('x@' + body.slice(at + 1));
    } else {
      var at2 = body.lastIndexOf('@'), c2 = body.slice(0, at2), dc;
      if (c2.indexOf(':') < 0) { try { dc = b64decode(dec(c2)); } catch (e) { throw new Error('ss: не разобрать данные доступа'); } } else { dc = dec(c2); }
      var ci2 = dc.indexOf(':');
      method = dc.slice(0, ci2); password = dc.slice(ci2 + 1); a = authority('x@' + body.slice(at2 + 1));
    }
    if (!method || !password) { throw new Error('ss: нет метода шифрования или пароля'); }
    if (q.get('plugin')) { throw new Error('ss: плагины (obfs, v2ray-plugin) не переводятся - вставьте YAML ноды'); }
    out.push('    type: ss', '    server: ' + yq(a.host), '    port: ' + a.port, '    cipher: ' + yq(noCtl(method, 'метод')),
      '    password: ' + yq(noCtl(password, 'пароль')), '    udp: true');
  } else if (t === 'hy2' || t === 'hysteria2') {
    a = authority(L.rest);
    if (!a.user) { throw new Error('hy2: в ссылке нет пароля (hy2://пароль@сервер:порт)'); }
    out.push('    type: hysteria2', '    server: ' + yq(a.host), '    port: ' + a.port, '    password: ' + yq(noCtl(a.user, 'пароль')));
    if (qv('obfs')) { out.push('    obfs: ' + yq(qv('obfs')), '    obfs-password: ' + yq(qv('obfs-password'))); }
    sni = qv('sni') || qv('peer'); if (sni) { out.push('    sni: ' + yq(sni)); }
    if (qv('alpn')) { out.push('    alpn: ' + listq(qv('alpn'))); }
    if (qv('insecure') === '1' || qv('allowInsecure') === '1') { out.push('    skip-cert-verify: true'); }
    out.push('    udp: true');
  } else if (t === 'vless' || t === 'trojan') {
    a = authority(L.rest);
    if (!a.user) { throw new Error(t + ': в ссылке нет ' + (t === 'vless' ? 'uuid' : 'пароля')); }
    out.push('    type: ' + t, '    server: ' + yq(a.host), '    port: ' + a.port);
    out.push(t === 'vless' ? '    uuid: ' + yq(noCtl(a.user, 'uuid')) : '    password: ' + yq(noCtl(a.user, 'пароль')));
    var sec = qv('security') || (t === 'trojan' ? 'tls' : 'none');
    sni = qv('sni');
    if (t === 'vless' && qv('encryption') && qv('encryption') !== 'none') { throw new Error('vless: encryption ' + qv('encryption') + ' не поддерживается'); }
    if (t === 'vless' && qv('flow')) { out.push('    flow: ' + yq(qv('flow'))); }
    out.push('    udp: true');
    if (sec === 'tls' || sec === 'reality') {
      out.push('    tls: true');
      if (sni) { out.push('    ' + (t === 'vless' ? 'servername' : 'sni') + ': ' + yq(sni)); }
      if (qv('fp')) { out.push('    client-fingerprint: ' + yq(qv('fp'))); }
      if (qv('alpn')) { out.push('    alpn: ' + listq(qv('alpn'))); }
      if (qv('allowInsecure') === '1' || qv('insecure') === '1') { out.push('    skip-cert-verify: true'); }
    } else if (sec !== 'none') { throw new Error('security=' + sec + ' не поддерживается'); }
    if (sec === 'reality') {
      if (!qv('pbk')) { throw new Error('vless reality: нет pbk (публичного ключа)'); }
      out.push('    reality-opts: { public-key: ' + yq(qv('pbk')) + (qv('sid') ? ', short-id: ' + yq(qv('sid')) : '') + ' }');
    }
    transportLines(qv('type'), { path: qv('path'), service: qv('serviceName') }, qv('host'), sni).forEach(function (l) { out.push(l); });
  } else {
    throw new Error('Схема ' + t + '://  не поддерживается: hy2, vless, trojan, ss, vmess - или вставьте YAML ноды');
  }
  if (!name) { name = (a ? a.host + ':' + a.port : 'node'); }
  noCtl(name, 'имя');
  return { name: name, yaml: '  - name: ' + yq(name) + '\n' + out.join('\n') + '\n' };
}

// ----- исключения нод (exclude-filter) -----

export function parseWords(text) {
  var out = [];
  lines(text).forEach(function (l) {
    l = l.replace(/^\s+|\s+$/g, '');
    if (l && out.indexOf(l) < 0) { out.push(l); }
  });
  return out;
}

export function checkWord(w) {
  if (/['|\t]/.test(w)) { throw new Error('Слово фильтра: нельзя апостроф, | и табуляцию'); }
}

// ----- модель -----

// data - ответ /api/constructor: subscriptions, proxies (текст или null -
// сервер их не отдал), geofilter (null - слова шаблона), geofilter_default.
export function createModules(data) {
  var subs = parseSubs(data.subscriptions);
  var proxies = parseProxies(data.proxies);
  var defWords = parseWords(data.geofilter_default);
  var words = data.geofilter ? parseWords(data.geofilter) : null;
  var present = { subs: data.subscriptions != null, proxies: data.proxies != null };

  function subNames() { return subs.map(function (s) { return s.name; }); }
  function proxyNames() { return proxies.map(function (p) { return p.name; }); }

  var model = {
    available: function () { return present; },
    // ----- подписки -----
    subs: function () { return subs.map(function (s) { return { url: s.url, ua: s.ua, name: s.name }; }); },
    addSub: function (url, ua, name) {
      url = String(url || '').trim(); ua = String(ua || '').trim();
      checkSubUrl(url); checkUa(ua);
      name = String(name || '').trim() || suggestSubName(url, subNames());
      checkSubName(name, subNames());
      subs.push({ url: url, ua: ua, name: name });
      return name;
    },
    editSub: function (name, patch) {
      var s = subs.filter(function (x) { return x.name === name; })[0];
      if (!s) { throw new Error('Нет подписки ' + name); }
      var n = Object.assign({}, s, patch);
      n.url = String(n.url).trim(); n.ua = String(n.ua || '').trim(); n.name = String(n.name).trim();
      checkSubUrl(n.url); checkUa(n.ua);
      if (n.name !== name) { checkSubName(n.name, subNames()); }
      s.url = n.url; s.ua = n.ua; s.name = n.name;
    },
    removeSub: function (name) { subs = subs.filter(function (s) { return s.name !== name; }); },
    // ----- свои прокси -----
    proxies: function () {
      return proxies.map(function (p) { return { name: p.name, type: p.type, server: p.server, port: p.port }; });
    },
    addProxyLink: function (link) {
      var r = linkToProxy(link);
      checkProxyName(r.name, proxyNames());
      proxies.push(parseProxies(r.yaml)[0]);
      return r.name;
    },
    addProxyYaml: function (text) {
      var list = proxiesFromYaml(text), taken = proxyNames();
      list.forEach(function (p) { checkProxyName(p.name, taken); taken.push(p.name); });
      list.forEach(function (p) { proxies.push(p); });
      return list.map(function (p) { return p.name; });
    },
    removeProxy: function (name) { proxies = proxies.filter(function (p) { return p.name !== name; }); },
    renameProxy: function (name, to) {
      var p = proxies.filter(function (x) { return x.name === name; })[0];
      if (!p) { throw new Error('Нет ноды ' + name); }
      to = String(to || '').trim();
      if (to === name) { return; }
      checkProxyName(to, proxyNames());
      if (!/^  - name:/.test(p.lines[0])) { throw new Error('Первым ключом ноды должен идти name'); }
      p.lines[0] = '  - name: ' + yq(to);
      p.name = to;
    },
    // ----- исключения нод -----
    words: function () { return (words || defWords).slice(); },
    defaultWords: function () { return defWords.slice(); },
    setWords: function (list) {
      var out = [];
      list.forEach(function (w) { w = String(w).trim(); if (w && out.indexOf(w) < 0) { checkWord(w); out.push(w); } });
      if (!out.length) { throw new Error('Фильтр пуст: пустой фильтр исключил бы все ноды'); }
      words = out;
    },
    resetWords: function () { words = null; },
    isDefaultWords: function () {
      if (!words) { return true; }
      function key(list) { return list.map(function (w) { return w.toLowerCase(); }).sort().join('\n'); }
      return key(words) === key(defWords);
    },
    // Что не даст применить: нет ни подписок, ни своих нод.
    problems: function () {
      var out = [];
      if (present.subs && present.proxies && !subs.length && !proxies.length) {
        out.push('Нужна хотя бы одна подписка или своя нода');
      }
      return out;
    },
    serialize: function () {
      return {
        subscriptions: present.subs ? serializeSubs(subs) : null,
        proxies: present.proxies ? serializeProxies(proxies) : null,
        geofilter: words && !model.isDefaultWords() ? words.join('\n') + '\n' : ''
      };
    },
    // Сводка относительно исходного состояния - только имена, без адресов
    // подписок и паролей.
    summary: function (initial) {
      var res = [];
      var s0 = parseSubs(initial.subscriptions), p0 = parseProxies(initial.proxies);
      var n0 = s0.map(function (s) { return s.name; });
      subs.forEach(function (s) {
        var old = s0.filter(function (x) { return x.name === s.name; })[0];
        if (!old) { res.push('+ подписка ' + s.name); }
        else if (old.url !== s.url) { res.push('Подписка ' + s.name + ': новый адрес'); }
        else if (old.ua !== s.ua) { res.push('Подписка ' + s.name + ': другой User-Agent'); }
      });
      n0.forEach(function (n) { if (subNames().indexOf(n) < 0) { res.push('Убрать подписку ' + n); } });
      var pn0 = p0.map(function (p) { return p.name; });
      proxies.forEach(function (p) {
        if (pn0.indexOf(p.name) < 0) { res.push('+ нода ' + p.name); }
        else {
          var old = p0.filter(function (x) { return x.name === p.name; })[0];
          if (old.lines.join('\n') !== p.lines.join('\n')) { res.push('Нода ' + p.name + ' изменена'); }
        }
      });
      pn0.forEach(function (n) { if (proxyNames().indexOf(n) < 0) { res.push('Убрать ноду ' + n); } });
      if ((initial.geofilter || '') !== model.serialize().geofilter) { res.push('Исключения нод изменены'); }
      return res;
    }
  };
  return model;
}
