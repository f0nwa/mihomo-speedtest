# Разбирает vless-подписку (base64-список "vless://...#remark", по одной
# ссылке на строку) в обычный clash-yaml блок proxies:, понятный prep.awk.
# Вход - уже раскодированный base64 текст (одна vless-ссылка на строку),
# подаётся через stdin/файл-аргумент. На выходе - proxies: и по одному
# блоку на каждую успешно разобранную ссылку. Строки, которые не удалось
# разобрать (не vless, битый uuid/host/port, reality без pbk и т.п.),
# пропускаются с предупреждением в stderr, весь остальной вход при этом
# разбирается как обычно - одна кривая ссылка не должна ронять остальные.
# Запускать строго под LC_ALL=C (или LANG=C) - иначе байтовая арифметика
# urldecode() может быть переинтерпретирована локалью и испортить
# многобайтовые UTF-8 remark'и (эмодзи, кириллица).

function hexval(c,    p) {
  p = index("0123456789abcdef", tolower(c))
  if (p == 0) return -1
  return p - 1
}

# %XX -> байт, "+" -> пробел, остальное без изменений. Безопасно
# вызывать и на уже "сыром" UTF-8 без единого "%" - тогда это no-op.
function urldecode(s,    out, i, n, c, h1, h2, v) {
  out = ""
  i = 1
  n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "%" && i + 2 <= n) {
      h1 = hexval(substr(s, i + 1, 1))
      h2 = hexval(substr(s, i + 2, 1))
      if (h1 < 0 || h2 < 0) { out = out c; i += 1 }
      else { v = h1 * 16 + h2; out = out sprintf("%c", v); i += 3 }
    } else if (c == "+") {
      out = out " "; i += 1
    } else {
      out = out c; i += 1
    }
  }
  return out
}

# экранирование значения для двойных кавычек YAML: сам символ " и обратный слэш
function yq(s,    r) {
  r = s
  gsub(/\\/, "\\\\", r)
  gsub(/"/, "\\\"", r)
  return "\"" r "\""
}

function warn(msg) {
  print "sub_convert.awk: " msg > "/dev/stderr"
  skipped++
}

function split_query(qs, q,    i, n, pairs, key, val, eq) {
  delete q
  if (qs == "") return
  n = split(qs, pairs, "&")
  for (i = 1; i <= n; i++) {
    if (pairs[i] == "") continue
    eq = index(pairs[i], "=")
    if (eq == 0) { key = pairs[i]; val = "" }
    else { key = substr(pairs[i], 1, eq - 1); val = substr(pairs[i], eq + 1) }
    q[urldecode(key)] = urldecode(val)
  }
}

# поля подтверждены по официальной документации mihomo
# (wiki.metacubex.one/en/config/proxies/vless/): server/port/uuid/network/
# tls/servername/flow/client-fingerprint/reality-opts{public-key,short-id}/
# ws-opts{path,headers.Host}/xhttp-opts{path,host}. Нестандартные
# параметры конкретной панели (mode=, concurrency=, x-durev-* и т.п.)
# сознательно отбрасываются - в схему mihomo не входят.
function emit_vless(name, userinfo, server, port, q,    net, sec) {
  sec = q["security"]
  if (sec == "reality" && q["pbk"] == "") {
    warn("vless: security=reality без pbk, строка пропущена (" name ")")
    return 0
  }
  print "  - name: " yq(name)
  print "    type: vless"
  print "    server: " yq(server)
  print "    port: " port
  print "    udp: true"
  print "    uuid: " yq(userinfo)
  net = (q["type"] != "" ? q["type"] : "tcp")
  print "    network: " net
  if (sec == "reality" || sec == "tls") print "    tls: true"
  if (q["sni"] != "") print "    servername: " yq(q["sni"])
  if (q["flow"] != "") print "    flow: " yq(q["flow"])
  if (q["fp"] != "") print "    client-fingerprint: " yq(q["fp"])
  if (sec == "reality") {
    print "    reality-opts:"
    print "      public-key: " yq(q["pbk"])
    if (q["sid"] != "") print "      short-id: " yq(q["sid"])
  }
  if (net == "ws") {
    print "    ws-opts:"
    print "      path: " yq((q["path"] != "" ? q["path"] : "/"))
    if (q["host"] != "") {
      print "      headers:"
      print "        Host: " yq(q["host"])
    }
  } else if (net == "xhttp") {
    print "    xhttp-opts:"
    print "      path: " yq((q["path"] != "" ? q["path"] : "/"))
    if (q["host"] != "") print "      host: " yq(q["host"])
  }
  return 1
}

function process_line(raw,    line, rest, hashpos, frag, qpos, qs, atpos, userinfo, hostport, cpos, host, port, name, ok) {
  line = raw
  gsub(/^[ \t\r]+|[ \t\r]+$/, "", line)
  if (line == "" || line ~ /^#/) return

  if (line !~ /^vless:\/\//) {
    warn("не vless-ссылка (или неизвестный протокол), строка пропущена")
    return
  }
  rest = substr(line, 9)

  hashpos = index(rest, "#")
  if (hashpos > 0) { frag = substr(rest, hashpos + 1); rest = substr(rest, 1, hashpos - 1) }
  else frag = ""

  qpos = index(rest, "?")
  if (qpos > 0) { qs = substr(rest, qpos + 1); rest = substr(rest, 1, qpos - 1) }
  else qs = ""

  atpos = index(rest, "@")
  if (atpos == 0) { warn("vless: нет userinfo (нет '@'), строка пропущена"); return }
  userinfo = substr(rest, 1, atpos - 1)
  hostport = substr(rest, atpos + 1)

  cpos = index(hostport, ":")
  if (cpos == 0) { warn("vless: нет порта у " hostport ", строка пропущена"); return }
  host = substr(hostport, 1, cpos - 1)
  port = substr(hostport, cpos + 1)
  if (host == "" || port !~ /^[0-9]+$/) { warn("vless: некорректный host/port (" hostport "), строка пропущена"); return }

  split_query(qs, q)
  name = (frag != "") ? urldecode(frag) : ("vless-" host "-" port)

  if (userinfo == "") { warn("vless: пустой uuid, строка пропущена (" name ")"); return }
  ok = emit_vless(name, userinfo, host, port, q)
  if (ok) converted++
}

BEGIN { converted = 0; skipped = 0; print "proxies:" }
{ process_line($0) }
END { print "sub_convert.awk: converted=" converted " skipped=" skipped > "/dev/stderr" }
