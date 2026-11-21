// Модель блоков конструктора конфига «Подписки», «Прокси» и «Исключения
// нод» - без DOM, проверяется node (tests/test_constructor_modules_model.sh).
// Проверки - те же, что у migrate_config.awk (подписки, ноды) и
// render_services.awk (слова фильтра): сервер всё равно перепроверит, но
// ошибку человек видит сразу.
//
// Состояние (файлы $DIR/config-state/):
//   subscriptions.tsv  url<TAB>User-Agent<TAB>имя[<TAB>1], по строке на подписку;
//                      1 - подписке нужен HWID устройства (панель с лимитом
//                      устройств; данные устройства - config-tools/detect_ua.sh);
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
export var UA_PRESETS = ['v2rayNG/1.8.0', 'FlClashX/0.3.2', 'Happ/4.11.0', 'clash.meta', 'mihomo/1.18.0', 'clash-verge/v2.0.5', 'ClashforWindows/0.20.39', 'Shadowrocket/1897'];

export function parseSubs(text) {
  var out = [];
  lines(text).forEach(function (l) {
    if (!l) { return; }
    var f = l.split(TAB);
    if (f.length < 3) { return; }
    out.push({ url: f[0], ua: f[1], name: f[2], hwid: f[3] === '1' });
  });
  return out;
}

export function serializeSubs(list) {
  return list.map(function (s) { return [s.url, s.ua, s.name].concat(s.hwid ? ['1'] : []).join(TAB); }).join('\n') + (list.length ? '\n' : '');
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
  var out = [], cur = null, src = lines(text);
  if (src.length && src[src.length - 1] === '') { src.pop(); }
  src.forEach(function (l) {
    if (!l.trim() || /^\s*#/.test(l)) {
      if (cur) { cur.lines.push(l); }
      return;
    }
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

function fieldEntries(p, key) {
  var re = new RegExp('^(  - |    )' + key + ':[ ]*(.*)$'), out = [];
  p.lines.forEach(function (line, index) {
    var m = re.exec(line);
    if (m) { out.push({ index: index, prefix: m[1], raw: m[2], value: unq(m[2]) }); }
  });
  return out;
}

function fieldOf(p, key) {
  var found = fieldEntries(p, key);
  return found.length ? found[0].value : '';
}

function simpleScalar(raw) {
  var v = String(raw).trim();
  return /^(?:'(?:[^']|'')*'|"(?:[^"\\]|\\.)*"|[A-Za-z0-9._:-]+)(?:\s+#.*)?$/.test(v);
}

function scalarOption(p, key, valueRe) {
  var found = fieldEntries(p, key);
  if (!found.length) { return { present: false, supported: true, value: '' }; }
  return {
    present: true,
    supported: found.length === 1 && simpleScalar(found[0].raw) && valueRe.test(found[0].value),
    value: found.length === 1 ? found[0].value : ''
  };
}

function alpnOption(p) {
  var found = fieldEntries(p, 'alpn');
  if (!found.length) { return { present: false, supported: true, values: [] }; }
  if (found.length !== 1) { return { present: true, supported: false, values: [] }; }
  var raw = found[0].raw.trim().replace(/\s+#.*$/, ''), values = [];
  if (/^\[.*\]$/.test(raw)) {
    var body = raw.slice(1, -1).trim();
    if (body) {
      var parts = body.split(',');
      for (var i = 0; i < parts.length; i++) {
        if (!simpleScalar(parts[i]) || /[\[\]{}]/.test(parts[i])) { return { present: true, supported: false, values: [] }; }
        values.push(unq(parts[i]));
      }
    }
    return { present: true, supported: true, values: values };
  }
  if (raw) { return { present: true, supported: false, values: [] }; }
  for (var j = found[0].index + 1; j < p.lines.length; j++) {
    var line = p.lines[j];
    if (/^(?:  - |    )\S/.test(line)) { break; }
    if (!line.trim() || /^\s*#/.test(line)) { continue; }
    var m = /^      - (.*)$/.exec(line);
    if (!m || !simpleScalar(m[1])) { return { present: true, supported: false, values: [] }; }
    values.push(unq(m[1]));
  }
  return { present: true, supported: true, values: values };
}

function proxyOptionsOf(p) {
  var quic = scalarOption(p, 'quic', /^(?:true|false)$/);
  return {
    ipv6: fieldEntries(p, 'ipv6').length > 0,
    mtu: scalarOption(p, 'mtu', /^\d+$/),
    keepalive: scalarOption(p, 'persistent-keepalive', /^\d+$/),
    quic: { present: quic.present, supported: quic.supported, value: quic.value === 'true' },
    fingerprint: scalarOption(p, 'client-fingerprint', /^\S+$/),
    alpn: alpnOption(p)
  };
}

export function serializeProxies(list) {
  var out = [];
  list.forEach(function (p) { p.lines.forEach(function (l) { out.push(l); }); });
  return out.length ? out.join('\n') + '\n' : '';
}

// Укладывает имя в 64 символа, сохраняя хвост tail (адрес или номер).
function fitName(base, tail) {
  var room = 64 - Array.from(tail).length;
  return Array.from(base).slice(0, Math.max(room, 1)).join('') + tail;
}

// Свободное имя ноды. Занято (одинаковый #фрагмент у разных серверов,
// например "hy2") - к имени добавляется адрес сервера ("hy2 nl.example"), а
// если и оно занято или адреса нет - номер ("hy2-2", "hy2-3"). Имя, уже
// содержащее адрес, адресом не дополняется.
export function uniqueProxyName(base, server, taken) {
  var name = String(base);
  if (taken.indexOf(name) < 0) { return name; }
  if (server && name.indexOf(server) < 0) {
    var withHost = fitName(name, ' ' + server);
    if (taken.indexOf(withHost) < 0) { return withHost; }
  }
  var k = 2, cand = fitName(name, '-' + k);
  while (taken.indexOf(cand) >= 0) { k++; cand = fitName(name, '-' + k); }
  return cand;
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

function yamlEscaped(raw, index) {
  var count = 0;
  for (var i = index - 1; i >= 0 && raw[i] === '\\'; i--) { count++; }
  return count % 2 === 1;
}

function yamlComment(raw) {
  var single = false, double = false;
  for (var i = 0; i < raw.length; i++) {
    var c = raw[i];
    if (single && c === "'" && raw[i + 1] === "'") { i++; continue; }
    if (c === "'" && !double) { single = !single; continue; }
    if (c === '"' && !single) {
      if (double && yamlEscaped(raw, i)) { continue; }
      double = !double; continue;
    }
    if (c === '#' && !single && !double && (!i || /\s/.test(raw[i - 1]))) { return raw.slice(0, i); }
  }
  return raw;
}

function yamlMarkers(raw) {
  var single = false, double = false;
  for (var i = 0; i < raw.length; i++) {
    var c = raw[i];
    if (single && c === "'" && raw[i + 1] === "'") { i++; continue; }
    if (c === "'" && !double) { single = !single; continue; }
    if (c === '"' && !single) {
      if (double && yamlEscaped(raw, i)) { continue; }
      double = !double; continue;
    }
    if (!single && !double && (c === '&' || c === '*' || c === '!') && (!i || /[\s\[{,:]/.test(raw[i - 1]))) {
      throw new Error('YAML anchors, aliases и явные теги не поддерживаются');
    }
  }
}

function yamlScalar(raw) {
  var v = yamlComment(String(raw)).trim();
  if (!v) { throw new Error('Пустой скаляр YAML не поддерживается'); }
  if (v[0] === "'") {
    if (!/^'(?:[^']|'')*'$/.test(v)) { throw new Error('Незакрытая одиночная кавычка в YAML'); }
    return v.slice(1, -1).replace(/''/g, "'");
  }
  if (v[0] === '"') {
    var decoded;
    try { decoded = JSON.parse(v); } catch (e) { throw new Error('Некорректная двойная кавычка или escape в YAML'); }
    if (typeof decoded !== 'string') { throw new Error('name и type должны быть строками'); }
    return decoded;
  }
  yamlMarkers(v);
  if (/^(?:---|\.\.\.|%)/.test(v)) { throw new Error('Директивы и маркеры документов YAML не поддерживаются'); }
  if (/:\s/.test(v)) { throw new Error('Неподдерживаемый многострочный или составной скаляр YAML'); }
  return v;
}

function yamlFlow(raw) {
  var text = yamlComment(raw).trim(), at = 0;
  function spaces() { while (/\s/.test(text[at] || '')) { at++; } }
  function quoted() {
    var quote = text[at], start = at++;
    while (at < text.length) {
      if (quote === "'" && text[at] === "'" && text[at + 1] === "'") { at += 2; continue; }
      if (text[at] === quote && (quote === "'" || !yamlEscaped(text, at))) { at++; return yamlScalar(text.slice(start, at)); }
      at++;
    }
    throw new Error('Незакрытая кавычка в flow-коллекции YAML');
  }
  function plain(stop) {
    var start = at;
    while (at < text.length && stop.indexOf(text[at]) < 0) { at++; }
    var value = text.slice(start, at).trim();
    if (/[\[\]{}]/.test(value)) { throw new Error('Скобки внутри plain-скаляра flow-коллекции YAML не поддерживаются'); }
    return yamlScalar(value);
  }
  function value() {
    spaces();
    if (text[at] === '[') { return list(); }
    if (text[at] === '{') { return map(); }
    if (text[at] === "'" || text[at] === '"') { return quoted(); }
    return plain(',]}');
  }
  function list() {
    at++; spaces();
    if (text[at] === ']') { at++; return; }
    while (at < text.length) {
      value(); spaces();
      if (text[at] === ']') { at++; return; }
      if (text[at] !== ',') { throw new Error('В flow-последовательности YAML нужна запятая или закрывающая скобка'); }
      at++; spaces();
      if (text[at] === ']') { at++; return; }
    }
    throw new Error('Незакрытая flow-последовательность YAML');
  }
  function map() {
    var keys = Object.create(null);
    at++; spaces();
    if (text[at] === '}') { at++; return; }
    while (at < text.length) {
      var key = text[at] === "'" || text[at] === '"' ? quoted() : plain(':');
      if (!key || key === '<<') { throw new Error('Пустой ключ или merge в flow-отображении YAML не поддерживается'); }
      if (keys[key]) { throw new Error('Повтор ключа ' + key + ' в flow-отображении YAML'); }
      keys[key] = true;
      spaces();
      if (text[at] !== ':') { throw new Error('В flow-отображении YAML после ключа нужно двоеточие'); }
      at++; value(); spaces();
      if (text[at] === '}') { at++; return; }
      if (text[at] !== ',') { throw new Error('В flow-отображении YAML нужна запятая или закрывающая скобка'); }
      at++; spaces();
      if (text[at] === '}') { at++; return; }
    }
    throw new Error('Незакрытое flow-отображение YAML');
  }
  if (!text || (text[0] !== '[' && text[0] !== '{')) { throw new Error('Некорректная flow-коллекция YAML'); }
  value(); spaces();
  if (at !== text.length) { throw new Error('Лишний текст после flow-коллекции YAML'); }
}

function yamlValue(raw) {
  var v = yamlComment(raw).trim();
  if (v[0] === '[' || v[0] === '{') { yamlFlow(v); return; }
  yamlScalar(v);
}

function yamlEntry(content) {
  var single = false, double = false, colon = -1;
  for (var i = 0; i < content.length; i++) {
    var c = content[i];
    if (single && c === "'" && content[i + 1] === "'") { i++; continue; }
    if (c === "'" && !double) { single = !single; continue; }
    if (c === '"' && !single) {
      if (double && yamlEscaped(content, i)) { continue; }
      double = !double; continue;
    }
    if (c === ':' && !single && !double && (i + 1 === content.length || /\s/.test(content[i + 1]))) { colon = i; break; }
  }
  if (colon < 0) { throw new Error('В отображении YAML нужна строка «ключ: значение»'); }
  var key = content.slice(0, colon).trim();
  if (key === '<<') { throw new Error('YAML merge << не поддерживается'); }
  if (!/^[A-Za-z0-9_.-]+$/.test(key)) { throw new Error('Ключи YAML должны быть простыми: латиница, цифры, точка, дефис и подчёркивание'); }
  return { key: key, value: content.slice(colon + 1).trim() };
}

function advancedProxyFromYaml(text, expectedName, expectedType) {
  var raw = lines(String(text == null ? '' : text));
  if (raw.length && raw[raw.length - 1] === '') { raw.pop(); }
  if (!raw.length) { throw new Error('Вставьте одну запись ноды YAML'); }
  raw.forEach(function (line) {
    if (/\t/.test(line)) { throw new Error('Табуляция в YAML недопустима - только пробелы'); }
    if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(line)) { throw new Error('Управляющие символы в YAML недопустимы'); }
  });
  if (/^(?:---|\.\.\.|%)/.test(raw[0])) { throw new Error('Директивы и маркеры документов YAML не поддерживаются'); }
  var first = /^( {0,2})- (.*)$/.exec(raw[0]);
  if (!first) { throw new Error('Нужна ровно одна блочная запись «- name: ...», без верхнеуровневых разделов'); }
  if (first[1].length === 1) { throw new Error('Базовый отступ записи YAML должен быть 0 или 2 пробела'); }
  var base = first[1].length;
  var src = raw.map(function (line) {
    if (!line.trim()) { return ''; }
    var cut = Math.min(base, line.length - line.replace(/^ +/, '').length);
    return '  ' + line.slice(cut);
  });
  var pos = 0;
  function info(index) {
    var line = src[index], indent = (line.match(/^ */) || [''])[0].length;
    return { line: line, indent: indent, content: line.slice(indent) };
  }
  function soft(index) { return !src[index].trim() || /^\s*#/.test(src[index]); }
  function nextSignificant() {
    var at = pos;
    while (at < src.length && soft(at)) { at++; }
    return at;
  }
  function marker(cur) {
    if (/^(?:---|\.\.\.|%)/.test(cur.content)) { throw new Error('Директивы и маркеры документов YAML не поддерживаются'); }
  }
  function block(parentIndent) {
    var contentIndent = -1;
    while (pos < src.length) {
      if (!src[pos].trim()) { pos++; continue; }
      var cur = info(pos);
      if (cur.indent <= parentIndent) { return; }
      if (contentIndent < 0) { contentIndent = cur.indent; }
      else if (cur.indent < contentIndent) { throw new Error('Неверный отступ содержимого блочного скаляра YAML'); }
      pos++;
    }
  }
  function entry(content, mapIndent, keys) {
    var item = yamlEntry(content);
    if (keys[item.key]) { throw new Error('Повтор ключа ' + item.key + ' в одном отображении YAML'); }
    keys[item.key] = true;
    if (!item.value) {
      pos++;
      var next = nextSignificant();
      if (next < src.length && info(next).indent > mapIndent) { pos = next; node(info(next).indent); }
      return item;
    }
    if (/^(?:\||>)(?:-|\+)?(?:\s+#.*)?$/.test(item.value)) {
      pos++; block(mapIndent);
    } else {
      yamlValue(item.value); pos++;
    }
    return item;
  }
  function map(indent, keys, root) {
    while (pos < src.length) {
      if (soft(pos)) { pos++; continue; }
      var cur = info(pos); marker(cur);
      if (cur.indent < indent) { return; }
      if (cur.indent > indent) { throw new Error('Неверный отступ вложенного отображения YAML'); }
      if (/^-(?:\s|$)/.test(cur.content)) { return; }
      var item = entry(cur.content, indent, keys);
      if (root && item.key === 'type') {
        if (!item.value || /^(?:\||>)/.test(item.value) || yamlScalar(item.value) !== expectedType) { throw new Error('Поле type должно остаться однострочным и сохранить прежнее значение'); }
      }
    }
  }
  function sequence(indent) {
    while (pos < src.length) {
      if (soft(pos)) { pos++; continue; }
      var cur = info(pos); marker(cur);
      if (cur.indent < indent) { return; }
      if (cur.indent > indent) { throw new Error('Неверный отступ вложенной последовательности YAML'); }
      if (!/^-(?:\s|$)/.test(cur.content)) { throw new Error('Строка не принадлежит вложенной последовательности YAML'); }
      var item = cur.content.slice(1).trim();
      if (!item) {
        pos++;
        var next = nextSignificant();
        if (next < src.length && info(next).indent > indent) { pos = next; node(info(next).indent); }
      } else if (item[0] === '[' || item[0] === '{') {
        yamlFlow(item); pos++;
      } else if (/^(?:\||>)(?:-|\+)?(?:\s+#.*)?$/.test(item)) {
        pos++; block(indent);
      } else {
        var candidate;
        try { candidate = yamlEntry(item); } catch (e) { candidate = null; }
        if (candidate) {
          var keys = Object.create(null);
          entry(item, indent + 2, keys);
          map(indent + 2, keys, false);
        } else { yamlValue(item); pos++; }
      }
    }
  }
  function node(indent) {
    var cur = info(pos);
    if (cur.indent !== indent) { throw new Error('Неверный отступ вложенной конструкции YAML'); }
    if (/^-(?:\s|$)/.test(cur.content)) { sequence(indent); } else { map(indent, Object.create(null), false); }
  }
  var root = info(0);
  if (root.indent !== 2 || !/^- /.test(root.content)) { throw new Error('Нужна одна блочная запись ноды YAML'); }
  if (/^[\[{]/.test(root.content.slice(2))) { throw new Error('Flow-запись всей ноды не поддерживается'); }
  var rootEntry = yamlEntry(root.content.slice(2));
  if (rootEntry.key !== 'name') { throw new Error('Первым ключом ноды должен идти name'); }
  if (!rootEntry.value || /^(?:\||>)/.test(rootEntry.value) || yamlScalar(rootEntry.value) !== expectedName) {
    throw new Error('Поле name должно остаться однострочным и сохранить прежнее значение');
  }
  pos = 1;
  var rootKeys = Object.create(null); rootKeys.name = true;
  map(4, rootKeys, true);
  while (pos < src.length && soft(pos)) { pos++; }
  if (pos < src.length) {
    marker(info(pos));
    throw new Error('Нужна ровно одна запись ноды, без второй записи или верхнеуровнего раздела');
  }
  if (!rootKeys.type) { throw new Error('У ноды нет type'); }
  return src;
}

function proxyFieldGroups(p) {
  var groups = Object.create(null), order = [], current = null;
  p.lines.forEach(function (line) {
    var m = /^(?:  - |    )([A-Za-z0-9_.-]+):/.exec(line);
    if (m) {
      current = m[1];
      if (!groups[current]) { groups[current] = []; order.push(current); }
      groups[current].push(line);
    } else if (current) { groups[current].push(line); }
  });
  return { groups: groups, order: order };
}

function changedProxyFields(oldProxy, newProxy) {
  var before = proxyFieldGroups(oldProxy), after = proxyFieldGroups(newProxy), out = [];
  before.order.concat(after.order.filter(function (key) { return before.order.indexOf(key) < 0; })).forEach(function (key) {
    if ((before.groups[key] || []).join('\n') !== (after.groups[key] || []).join('\n')) { out.push(key); }
  });
  return out;
}

function b64decode(s) {
  var t = String(s).replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, '');
  while (t.length % 4) { t += '='; }
  var bin = atob(t), bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
  return new TextDecoder('utf-8').decode(bytes);
}

function trustTunnelBytes(payload) {
  // 64 КиБ данных занимают не более 87382 символов Base64url без padding.
  if (payload.length > 87382) { throw new Error('TrustTunnel: данные ссылки больше 64 КиБ'); }
  if (!/^[A-Za-z0-9_-]+$/.test(payload) || payload.length % 4 === 1) {
    throw new Error('TrustTunnel: нужен Base64url без padding, пробелов и посторонних символов');
  }
  var standard = payload.replace(/-/g, '+').replace(/_/g, '/');
  while (standard.length % 4) { standard += '='; }
  var decoded;
  try { decoded = atob(standard); } catch (e) { throw new Error('TrustTunnel: не разобрать Base64url'); }
  if (decoded.length > 65536) { throw new Error('TrustTunnel: данные ссылки больше 64 КиБ'); }
  var out = new Uint8Array(decoded.length);
  for (var i = 0; i < decoded.length; i++) { out[i] = decoded.charCodeAt(i); }
  return out;
}

function trustTunnelVarint(data, at) {
  if (at >= data.length) { throw new Error('TrustTunnel: обрезан TLS/QUIC varint'); }
  var first = data[at++], size = 1 << (first >> 6), value = first & 0x3f;
  for (var i = 1; i < size; i++) {
    if (at >= data.length) { throw new Error('TrustTunnel: обрезан TLS/QUIC varint'); }
    value = value * 256 + data[at++];
    if (!Number.isSafeInteger(value)) { throw new Error('TrustTunnel: целое вне безопасного диапазона JavaScript'); }
  }
  return { value: value, next: at };
}

export function parseTrustTunnelLink(link) {
  var m = /^tt:\/\/(\??)(.*)$/i.exec(String(link || ''));
  if (!m) { throw new Error('TrustTunnel: ссылка должна начинаться с tt://? или tt://'); }
  var data = trustTunnelBytes(m[2]), at = 0;
  var utf8 = new TextDecoder('utf-8', { fatal: true });
  var fields = {
    version: 0, hostname: '', addresses: [], customSni: '', hasIpv6: true,
    username: '', password: '', skipVerification: false, certificate: new Uint8Array(0),
    upstreamProtocol: 1, antiDpi: false, clientRandomPrefix: '', name: '',
    dnsUpstreams: [], clientRandomAuthKey: ''
  };
  var subscription = false;
  function string(value) {
    try { return utf8.decode(value); } catch (e) { throw new Error('TrustTunnel: повреждённая строка UTF-8'); }
  }
  function bool(value) {
    if (value.length !== 1 || (value[0] !== 0 && value[0] !== 1)) {
      throw new Error('TrustTunnel: Bool должен иметь длину 1 и значение 0x00 или 0x01');
    }
    return value[0] === 1;
  }
  function strings(value) {
    var out = [], pos = 0;
    while (pos < value.length) {
      var length = trustTunnelVarint(value, pos); pos = length.next;
      if (length.value > value.length - pos) { throw new Error('TrustTunnel: неверная длина элемента String[]'); }
      out.push(string(value.subarray(pos, pos + length.value))); pos += length.value;
    }
    return out;
  }
  while (at < data.length) {
    var tag = trustTunnelVarint(data, at); at = tag.next;
    var length = trustTunnelVarint(data, at); at = length.next;
    if (length.value > data.length - at) { throw new Error('TrustTunnel: неверная длина или обрезанный TLV'); }
    var value = data.subarray(at, at + length.value); at += length.value;
    if (tag.value === 0) {
      if (value.length < 1) { throw new Error('TrustTunnel: пустой varint version'); }
      fields.version = trustTunnelVarint(value, 0).value;
      if (trustTunnelVarint(value, 0).next !== value.length) { throw new Error('TrustTunnel: лишние байты в version'); }
    } else if (tag.value === 1) { fields.hostname = string(value); }
    else if (tag.value === 2) { fields.addresses.push(string(value)); }
    else if (tag.value === 3) { fields.customSni = string(value); }
    else if (tag.value === 4) { fields.hasIpv6 = bool(value); }
    else if (tag.value === 5) { fields.username = string(value); }
    else if (tag.value === 6) { fields.password = string(value); }
    else if (tag.value === 7) { fields.skipVerification = bool(value); }
    else if (tag.value === 8) { fields.certificate = value; }
    else if (tag.value === 9) {
      if (value.length < 1) { throw new Error('TrustTunnel: пустой varint upstream_protocol'); }
      var protocol = trustTunnelVarint(value, 0);
      if (protocol.next !== value.length) { throw new Error('TrustTunnel: лишние байты в upstream_protocol'); }
      fields.upstreamProtocol = protocol.value;
    } else if (tag.value === 10) { fields.antiDpi = bool(value); }
    else if (tag.value === 11) { fields.clientRandomPrefix = string(value); }
    else if (tag.value === 12) { fields.name = string(value); }
    else if (tag.value === 13) { fields.dnsUpstreams = strings(value); }
    else if (tag.value === 14) { subscription = true; string(value); }
    else if (tag.value === 15) { fields.clientRandomAuthKey = string(value); }
  }
  if (subscription) { throw new Error('TrustTunnel: ссылки с subscription_url (подписки) не поддерживаются'); }
  if (fields.version > 2) { throw new Error('TrustTunnel: версия ссылки выше поддерживаемой 2'); }
  if (!fields.hostname || !fields.username || !fields.password || !fields.addresses.length || !fields.addresses[0]) {
    throw new Error('TrustTunnel: обязательные hostname, address, username и password должны быть непустыми');
  }
  if (fields.addresses.length !== 1) { throw new Error('TrustTunnel: поддерживается ровно один адрес сервера, не несколько'); }
  if (fields.certificate.length) { throw new Error('TrustTunnel: встроенный сертификат пока не поддерживается импортом'); }
  if (fields.antiDpi) { throw new Error('TrustTunnel: anti-DPI=true пока не поддерживается импортом'); }
  if (fields.clientRandomPrefix) { throw new Error('TrustTunnel: client_random_prefix пока не поддерживается импортом'); }
  if (fields.clientRandomAuthKey) { throw new Error('TrustTunnel: client_random_auth_key пока не поддерживается импортом'); }
  if (fields.dnsUpstreams.length) { throw new Error('TrustTunnel: непустой список DNS-upstreams пока не поддерживается импортом'); }
  if (!fields.hasIpv6) { throw new Error('TrustTunnel: has_ipv6=false пока не поддерживается импортом'); }
  if (fields.upstreamProtocol !== 1 && fields.upstreamProtocol !== 2) {
    throw new Error('TrustTunnel: неподдерживаемый upstream_protocol, нужен HTTP/2 или HTTP/3');
  }
  var address = fields.addresses[0];
  var parsed = /^\[([A-Za-z0-9._:-]+)\]:(\d+)$/.exec(address) || /^([A-Za-z0-9._-]+):(\d+)$/.exec(address);
  if (!parsed) { throw new Error('TrustTunnel: адрес должен содержать хост и порт; IPv6 записывается в квадратных скобках'); }
  var port = Number(parsed[2]);
  if (!(port >= 1 && port <= 65535)) { throw new Error('TrustTunnel: порт вне диапазона 1-65535'); }
  noCtl(fields.hostname, 'hostname'); noCtl(fields.username, 'username'); noCtl(fields.password, 'password');
  var sni = fields.customSni || fields.hostname, name = fields.name || fields.hostname;
  noCtl(sni, 'SNI'); noCtl(name, 'имя');
  return {
    name: name, server: parsed[1], port: port, username: fields.username,
    password: fields.password, sni: sni, quic: fields.upstreamProtocol === 2,
    skipCertVerify: fields.skipVerification
  };
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

// Ссылка (hy2/hysteria2/vless/trojan/ss/vmess/tt) -> {name, server, yaml}.
export function linkToProxy(link) {
  if (/^tt:/i.test(String(link || ''))) {
    var tt = parseTrustTunnelLink(link), ttOut = [
      '    type: trusttunnel', '    server: ' + yq(tt.server), '    port: ' + tt.port,
      '    username: ' + yq(tt.username), '    password: ' + yq(tt.password),
      '    sni: ' + yq(tt.sni), '    quic: ' + tt.quic
    ];
    if (tt.skipCertVerify) { ttOut.push('    skip-cert-verify: true'); }
    return { name: tt.name, server: tt.server, yaml: '  - name: ' + yq(tt.name) + '\n' + ttOut.join('\n') + '\n' };
  }
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
    throw new Error('Схема ' + t + '://  не поддерживается: hy2, vless, trojan, ss, vmess, tt - или вставьте YAML ноды');
  }
  if (!name) { name = (a ? a.host + ':' + a.port : 'node'); }
  noCtl(name, 'имя');
  return { name: name, server: a ? a.host : (j && j.add ? String(j.add) : ''), yaml: '  - name: ' + yq(name) + '\n' + out.join('\n') + '\n' };
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
  // Своего фильтра в конструкторе ещё нет, а BLOCK спидтеста (прежний
  // фильтр из настроек) отличается от слов шаблона - исходный фильтр он.
  var fromBlock = false;
  if (!words && data.block) {
    var bw = parseWords(String(data.block).replace(/\|/g, '\n'));
    function keyOf(list) { return list.map(function (w) { return w.toLowerCase(); }).sort().join('\n'); }
    if (bw.length && keyOf(bw) !== keyOf(defWords)) { words = bw; fromBlock = true; }
  }
  var filterErr = '';
  var present = { subs: data.subscriptions != null, proxies: data.proxies != null };

  // Убранная подписка, как и нода, остаётся в списке (красной) до применения:
  // в конфиг не идёт, но имя за ней держится, чтобы её можно было вернуть.
  function activeSubs() { return subs.filter(function (s) { return !s.removed; }); }
  function subNames() { return activeSubs().map(function (s) { return s.name; }); }
  function reservedSubNames() { return subs.map(function (s) { return s.name; }); }
  function activeProxies() { return proxies.filter(function (p) { return !p.removed; }); }
  function proxyNames() { return activeProxies().map(function (p) { return p.name; }); }
  function reservedProxyNames() { return proxies.map(function (p) { return p.name; }); }
  function editableProxy(name) {
    var found = proxies.filter(function (p) { return p.name === name; });
    if (found.length > 1) { throw new Error('Несколько нод с именем ' + name + ': нужна уникальная запись'); }
    if (!found.length || found[0].removed) { throw new Error('Нет ноды ' + name); }
    return found[0];
  }
  function updateProxy(p, patch) {
    if (!patch || typeof patch !== 'object') { throw new Error('Некорректные изменения ноды'); }
    var options = proxyOptionsOf(p), next = p.lines.slice();
    var allowed = p.type === 'wireguard' ? { mtu: true, 'persistent-keepalive': true }
      : p.type === 'trusttunnel' ? { quic: true, 'client-fingerprint': true } : {};
    var keys = Object.keys(patch);
    keys.forEach(function (key) {
      if (!allowed[key]) { throw new Error('Поле ' + key + ' не поддерживается обычной формой'); }
    });
    function option(key) {
      return key === 'persistent-keepalive' ? options.keepalive
        : key === 'client-fingerprint' ? options.fingerprint : options[key];
    }
    function remove(key) {
      var found = fieldEntries({ lines: next }, key);
      if (found.length) { next.splice(found[0].index, 1); }
    }
    function write(key, value) {
      var temp = { lines: next }, found = fieldEntries(temp, key), line = '    ' + key + ': ' + value;
      if (found.length) {
        next[found[0].index] = found[0].prefix + key + ': ' + value;
      } else {
        var at = next.length;
        while (at > 0 && !next[at - 1].trim()) { at--; }
        next.splice(at, 0, line);
      }
    }
    keys.forEach(function (key) {
      var value = patch[key], opt = option(key);
      if (!opt.supported) { throw new Error((key === 'mtu' ? 'MTU' : 'Поле ' + key) + ': неподдерживаемая структура'); }
      if (value === null) {
        if (opt.present) { remove(key); }
        return;
      }
      if (key === 'mtu' || key === 'persistent-keepalive') {
        var label = key === 'mtu' ? 'MTU' : 'persistent-keepalive';
        if (typeof value !== 'number' || !isFinite(value) || Math.floor(value) !== value) { throw new Error(label + ': нужно целое число'); }
        var min = key === 'mtu' ? (options.ipv6 ? 1280 : 576) : 1;
        if (value < min || value > 65535) { throw new Error(label + ': допустимый диапазон ' + min + '-65535'); }
        if (opt.present && Number(opt.value) === value) { return; }
        write(key, String(value));
      } else if (key === 'quic') {
        if (typeof value !== 'boolean') { throw new Error('QUIC: нужно значение true или false'); }
        if (opt.present && opt.value === value) { return; }
        var protocol = value ? 'h3' : 'h2';
        if (options.alpn.present && (!options.alpn.supported || options.alpn.values.indexOf(protocol) < 0)) {
          throw new Error('ALPN не содержит ' + protocol + ': измените ALPN отдельно перед сменой транспорта');
        }
        write(key, String(value));
      } else if (key === 'client-fingerprint') {
        if (opt.present && opt.value === value) { return; }
        if (['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random', 'randomized'].indexOf(value) < 0) {
          throw new Error('client-fingerprint: выберите одну из предустановок формы');
        }
        write(key, value);
      }
    });
    p.lines = next;
  }

  var model = {
    available: function () { return present; },
    // Исходный фильтр взят из BLOCK спидтеста, а не из конструктора/шаблона.
    fromBlock: function () { return fromBlock; },
    // ----- подписки -----
    subs: function () { return activeSubs().map(function (s) { return { url: s.url, ua: s.ua, name: s.name, hwid: !!s.hwid }; }); },
    subRows: function () { return subs.map(function (s) { return { url: s.url, ua: s.ua, name: s.name, hwid: !!s.hwid, removed: !!s.removed }; }); },
    addSub: function (url, ua, name, hwid) {
      url = String(url || '').trim(); ua = String(ua || '').trim();
      checkSubUrl(url); checkUa(ua);
      name = String(name || '').trim() || suggestSubName(url, reservedSubNames());
      checkSubName(name, reservedSubNames());
      subs.push({ url: url, ua: ua, name: name, hwid: !!hwid });
      return name;
    },
    editSub: function (name, patch) {
      var s = activeSubs().filter(function (x) { return x.name === name; })[0];
      if (!s) { throw new Error('Нет подписки ' + name); }
      var n = Object.assign({}, s, patch);
      n.url = String(n.url).trim(); n.ua = String(n.ua || '').trim(); n.name = String(n.name).trim();
      checkSubUrl(n.url); checkUa(n.ua);
      if (n.name !== name) { checkSubName(n.name, reservedSubNames()); }
      s.url = n.url; s.ua = n.ua; s.name = n.name; s.hwid = !!n.hwid;
    },
    removeSub: function (name) {
      var s = subs.filter(function (x) { return x.name === name; })[0];
      if (s) { s.removed = true; }
    },
    restoreSub: function (name) {
      var s = subs.filter(function (x) { return x.name === name; })[0];
      if (s) { s.removed = false; }
    },
    // ----- свои прокси -----
    proxies: function () {
      return activeProxies().map(function (p) { return { name: p.name, type: p.type, server: p.server, port: p.port }; });
    },
    proxyRows: function () {
      return proxies.map(function (p) { return { name: p.name, type: p.type, server: p.server, port: p.port, removed: !!p.removed }; });
    },
    getProxyYaml: function (name) { return editableProxy(name).lines.join('\n') + '\n'; },
    proxyOptions: function (name) { return proxyOptionsOf(editableProxy(name)); },
    updateProxyOptions: function (name, patch) { updateProxy(editableProxy(name), patch); },
    replaceProxyYaml: function (name, text, options) {
      if (!options || options.advanced !== true) { throw new Error('Замена YAML доступна только в расширенном редакторе'); }
      var p = editableProxy(name);
      if (String(text == null ? '' : text) === p.lines.join('\n') + '\n') { return; }
      var next = advancedProxyFromYaml(text, p.name, p.type);
      p.lines = next;
      p.server = fieldOf(p, 'server');
      p.port = fieldOf(p, 'port');
    },
    // Ссылка -> нода; возвращает итоговое имя (при занятом оно получает адрес
    // сервера или номер, см. uniqueProxyName).
    addProxyLink: function (link) {
      var r = linkToProxy(link), taken = reservedProxyNames();
      var name = uniqueProxyName(r.name, r.server, taken);
      checkProxyName(name, taken);
      var p = parseProxies(r.yaml)[0];
      if (name !== r.name) { p.lines[0] = '  - name: ' + yq(name); p.name = name; }
      proxies.push(p);
      return name;
    },
    // YAML нод -> имена добавленных (повтор имени переименовывается так же).
    // strict - повтор имени отклоняется ("уже есть"), без переименования: так
    // добавляется импорт WireGuard-файлов, чтобы повторный импорт не плодил дубли.
    addProxyYaml: function (text, strict) {
      var list = proxiesFromYaml(text), taken = reservedProxyNames();
      list.forEach(function (p) {
        var name = strict ? p.name : uniqueProxyName(p.name, fieldOf(p, 'server'), taken);
        checkProxyName(name, taken);
        if (name !== p.name) {
          if (!/^  - name:/.test(p.lines[0])) { throw new Error('Первым ключом ноды должен идти name'); }
          p.lines[0] = '  - name: ' + yq(name); p.name = name;
        }
        taken.push(name);
      });
      list.forEach(function (p) { proxies.push(p); });
      return list.map(function (p) { return p.name; });
    },
    removeProxy: function (name) {
      var p = proxies.filter(function (x) { return x.name === name; })[0];
      if (p) { p.removed = true; }
    },
    restoreProxy: function (name) {
      var p = proxies.filter(function (x) { return x.name === name; })[0];
      if (p) { p.removed = false; }
    },
    renameProxy: function (name, to) {
      var p = activeProxies().filter(function (x) { return x.name === name; })[0];
      if (!p) { throw new Error('Нет ноды ' + name); }
      to = String(to || '').trim();
      if (to === name) { return; }
      checkProxyName(to, reservedProxyNames());
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
    // Ошибка, которую панель фильтра нашла сама (пустой фильтр, апостроф).
    setFilterError: function (msg) { filterErr = msg || ''; },
    isDefaultWords: function () {
      if (!words) { return true; }
      function key(list) { return list.map(function (w) { return w.toLowerCase(); }).sort().join('\n'); }
      return key(words) === key(defWords);
    },
    // Что не даст применить: нет ни подписок, ни своих нод.
    problems: function () {
      var out = [];
      if (present.subs && present.proxies && !activeSubs().length && !activeProxies().length) {
        out.push('Нужна хотя бы одна подписка или своя нода');
      }
      if (filterErr) { out.push('Исключения нод: ' + filterErr); }
      return out;
    },
    serialize: function () {
      return {
        subscriptions: present.subs ? serializeSubs(activeSubs()) : null,
        proxies: present.proxies ? serializeProxies(activeProxies()) : null,
        geofilter: words && !model.isDefaultWords() ? words.join('\n') + '\n' : ''
      };
    },
    // Какие блоки изменены относительно initial: subs, proxies, filter.
    changes: function (initial) {
      var cur = model.serialize();
      return {
        subs: cur.subscriptions !== null && cur.subscriptions !== (initial.subscriptions || ''),
        proxies: cur.proxies !== null && cur.proxies !== (initial.proxies || ''),
        filter: (initial.geofilter || '') !== cur.geofilter
      };
    },
    // Сводка относительно исходного состояния - только имена, без адресов
    // подписок и паролей.
    summary: function (initial) {
      var res = [];
      var s0 = parseSubs(initial.subscriptions), p0 = parseProxies(initial.proxies);
      var n0 = s0.map(function (s) { return s.name; });
      activeSubs().forEach(function (s) {
        var old = s0.filter(function (x) { return x.name === s.name; })[0];
        if (!old) { res.push('+ подписка ' + s.name); }
        else if (old.url !== s.url) { res.push('Подписка ' + s.name + ': новый адрес'); }
        else if (old.ua !== s.ua) { res.push('Подписка ' + s.name + ': другой User-Agent'); }
        else if (!!old.hwid !== !!s.hwid) { res.push('Подписка ' + s.name + (s.hwid ? ': включён HWID устройства' : ': выключен HWID устройства')); }
      });
      n0.forEach(function (n) { if (subNames().indexOf(n) < 0) { res.push('Убрать подписку ' + n); } });
      var pn0 = p0.map(function (p) { return p.name; });
      activeProxies().forEach(function (p) {
        if (pn0.indexOf(p.name) < 0) { res.push('+ нода ' + p.name); }
        else {
          var old = p0.filter(function (x) { return x.name === p.name; })[0];
          if (old.lines.join('\n') !== p.lines.join('\n')) {
            var fields = changedProxyFields(old, p);
            res.push('Нода ' + p.name + (fields.length ? ': изменены ' + fields.join(', ') : ': изменён YAML'));
          }
        }
      });
      pn0.forEach(function (n) { if (proxyNames().indexOf(n) < 0) { res.push('Убрать ноду ' + n); } });
      if ((initial.geofilter || '') !== model.serialize().geofilter) { res.push('Исключения нод изменены'); }
      return res;
    }
  };
  return model;
}
