# diag.awk - логика вкладки «Диагностика» без сети (см.
# docs/superpowers/specs/2026-10-14-service-diagnostics-design.md).
# Вызывается из stats_diag.sh; запускать с LC_ALL=C (побайтовый режим,
# \uXXXX раскрывается в UTF-8 вручную). Совместим с busybox awk.
#
# mode=resolve - разбор ответа GET /proxies основного ядра:
#   awk -v mode=resolve -v groups_file=PATH -f diag.awk proxies.json
#   groups_file - имена групп сервисов, по одному в строке. На выходе по
#   строке на группу (в порядке groups_file), поля через TAB:
#     name  chain  end  endkind  candidates
#   chain - путь по выбранным (now) от группы до конца, элементы через \037;
#   end - чем кончается цепочка; endkind - node|direct|reject|lb|missing|loop
#   (lb - на пути load-balance или relay: одной ноды нет); candidates - все
#   конечные ноды, достижимые из all группы с раскрытием вложенных групп,
#   без DIRECT/REJECT и повторов, в порядке обхода, через \037.
#
# mode=targets - адреса проверки сервисов:
#   awk -v mode=targets -v overlay_file=PATH|"" -f diag.awk services.default.tsv
#   На выходе по строке на сервис (встроенные в порядке таблицы, затем свои
#   из overlay): имя группы<TAB>адреса через пробел (первый - основной) или
#   "-", если адреса нет. Источники по старшинству: check из overlay; check
#   из таблицы; первый DOMAIN/DOMAIN-SUFFIX из rule сервиса; первый dom
#   full|suffix из overlay. del убирает сервис; svc из overlay с id или
#   именем встроенного заменяет его имя (как в render_services.awk).
#
# mode=now - выбор (now) одной группы из ответа GET /proxies/<имя>:
#   awk -v mode=now -f diag.awk group.json  -> строка с выбором (пусто - нет)
#
# mode=order - порядок проверки кандидатов при поиске замены:
#   DIAG_EXCLUDE=NODE awk -v mode=order -v min_uptime=N -v min_runs=N \
#       -v stab_file=node_stability.tsv -f diag.awk candidates.txt
#   candidates.txt - имена по одному в строке. На выходе: сначала ноды с
#   накопленной статистикой (runs_seen >= min_runs) и uptime >= min_uptime -
#   по убыванию uptime; затем ноды без достаточной статистики; затем со
#   слабым uptime - по убыванию. При равенстве - исходный порядок. Мёртвые
#   по статистике (runs_seen >= min_runs, runs_alive = 0) и DIAG_EXCLUDE
#   (или -v exclude, если имя без \) пропускаются. Поля node_stability.tsv - в шапке node_stats_update.awk.
#
# mode=render - JSON состояния для вкладки (GET /api/diag):
#   awk -v mode=render -v meta=PATH -f diag.awk services.tsv
#   meta - строки ключ<TAB>значение: id running(0|1) stage error started
#   finished current total done. services.tsv - по строке на сервис, поля
#   через TAB: name chain node verdict url detail ms control_ms alt_state
#   alt_checked alt_limit alt_found (chain и alt_found - через \037).

function hexval(h,   i, v, c) {
  v = 0; h = tolower(h)
  for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)); if (!c) return -1; v = v * 16 + c - 1 }
  return v
}
function u8(n) {
  if (n < 128) return sprintf("%c", n)
  if (n < 2048) return sprintf("%c%c", 192 + int(n / 64), 128 + n % 64)
  if (n < 65536) return sprintf("%c%c%c", 224 + int(n / 4096), 128 + int(n / 64) % 64, 128 + n % 64)
  return sprintf("%c%c%c%c", 240 + int(n / 262144), 128 + int(n / 4096) % 64, 128 + int(n / 64) % 64, 128 + n % 64)
}
# Раскрыть экранирование внутри строки JSON (без кавычек).
function unesc(s,   out, i, c, n, lo, L) {
  if (index(s, "\\") == 0) return s
  out = ""; L = length(s); i = 1
  while (i <= L) {
    c = substr(s, i, 1)
    if (c != "\\") { out = out c; i++; continue }
    c = substr(s, i + 1, 1); i += 2
    if (c == "u") {
      n = hexval(substr(s, i, 4)); i += 4
      if (n >= 55296 && n < 56320 && substr(s, i, 2) == "\\u") {
        lo = hexval(substr(s, i + 2, 4))
        if (lo >= 56320 && lo < 57344) { n = 65536 + (n - 55296) * 1024 + (lo - 56320); i += 6 }
      }
      if (n >= 0) out = out u8(n)
    } else if (c == "n") out = out "\n"
    else if (c == "t") out = out "\t"
    else if (c == "r") out = out "\r"
    else if (c != "b" && c != "f") out = out c
  }
  return out
}
# Строковый токен: ключ, значение после ":" или элемент массива.
function on_str(raw,   name) {
  if (D == 2 && TY[2] == "{" && !AFTER_COLON && KEY[1] == "proxies") {
    KEY[2] = unesc(raw); KNOWN[KEY[2]] = 1; return
  }
  if (TY[D] == "{" && !AFTER_COLON) { KEY[D] = raw; return }
  if (KEY[1] != "proxies") return
  name = KEY[2]
  if (D == 3 && AFTER_COLON) {
    if (KEY[3] == "type") TYPE[name] = unesc(raw)
    else if (KEY[3] == "now") NOW[name] = unesc(raw)
  } else if (D == 4 && TY[4] == "[" && KEY[3] == "all") {
    if (ALL[name] != "") ALL[name] = ALL[name] US
    ALL[name] = ALL[name] unesc(raw)
  }
}
# Структурные символы между строками; числа и true/false пропускаются.
function on_plain(t,   i, L, c) {
  L = length(t)
  for (i = 1; i <= L; i++) {
    c = substr(t, i, 1)
    if (c == "{" || c == "[") { D++; TY[D] = c; KEY[D] = ""; AFTER_COLON = 0 }
    else if (c == "}" || c == "]") { D--; AFTER_COLON = 0 }
    else if (c == ":") AFTER_COLON = 1
    else if (c == ",") AFTER_COLON = 0
  }
}
# Разбор всего ответа за один проход: split по кавычке, нечётные куски -
# вне строк, чётные - содержимое строк (кавычка после нечётного числа
# обратных слэшей - экранированная, кусок склеивается со следующим).
function parse_top(   n, k, piece, bs, j) {
  n = split(S, A, "\"")
  D = 0; AFTER_COLON = 0
  k = 1
  while (k <= n) {
    on_plain(A[k]); k++
    if (k > n) break
    piece = A[k]
    while (1) {
      bs = 0; j = length(piece)
      while (j > 0 && substr(piece, j, 1) == "\\") { bs++; j-- }
      if (bs % 2 == 0 || k >= n) break
      k++; piece = piece "\"" A[k]
    }
    on_str(piece); AFTER_COLON = 0; k++
  }
  split("", A)
}
function follows(t) { return t == "Selector" || t == "URLTest" || t == "Fallback" }
function multi(t) { return t == "LoadBalance" || t == "Relay" }
function isgroup(t) { return follows(t) || multi(t) }
function isdirect(t) { return t == "Direct" || t == "Pass" }
function isreject(t) { return t == "Reject" || t == "RejectDrop" }

# Кандидаты: обход all с раскрытием вложенных групп.
function collect(g,   n, i, m, arr, t) {
  SEEN_G[g] = 1
  n = split(ALL[g], arr, US)
  for (i = 1; i <= n; i++) {
    m = arr[i]; t = TYPE[m]
    if (!(m in KNOWN)) continue
    if (isgroup(t)) { if (!(m in SEEN_G)) collect(m); continue }
    if (isdirect(t) || isreject(t)) continue
    if (m in SEEN_N) continue
    SEEN_N[m] = 1
    if (CANDS != "") CANDS = CANDS US
    CANDS = CANDS m
  }
}
function resolve(g,   chain, cur, kind, t, nxt, depth, vis) {
  chain = g; cur = g; kind = ""
  split("", vis); vis[g] = 1
  for (depth = 0; depth < 16; depth++) {
    if (!(cur in KNOWN)) { kind = "missing"; break }
    t = TYPE[cur]
    if (follows(t)) {
      nxt = NOW[cur]
      if (nxt == "") { kind = "missing"; break }
      if (nxt in vis) { kind = "loop"; break }
      vis[nxt] = 1; chain = chain US nxt; cur = nxt; continue
    }
    if (multi(t)) kind = "lb"
    else if (isdirect(t)) kind = "direct"
    else if (isreject(t)) kind = "reject"
    else kind = "node"
    break
  }
  if (kind == "") kind = "loop"
  END_ = (kind == "missing" && !(cur in KNOWN)) ? "" : cur
  if (kind == "loop") END_ = ""
  CANDS = ""; split("", SEEN_G); split("", SEEN_N)
  if (g in KNOWN) collect(g)
  printf "%s\t%s\t%s\t%s\t%s\n", g, chain, END_, kind, CANDS
}

# --- targets ---
function rule_domain(text,   f, n) {
  n = split(text, f, ",")
  if (n >= 2 && (f[1] == "DOMAIN" || f[1] == "DOMAIN-SUFFIX") && f[2] != "") return f[2]
  return ""
}
function t_add(id, name) {
  if (id in T_NAME) return
  T_ORDER[++T_N] = id; T_NAME[id] = name
}
function t_default(line,   f, n, d) {
  sub(/\r$/, "", line)
  if (line == "" || line ~ /^#/) return
  n = split(line, f, "\t")
  if (f[1] == "svc" && n >= 3) t_add(f[2], f[3])
  else if (f[1] == "check" && n >= 3 && (f[2] in T_NAME)) { if (T_CHECK[f[2]] != "") T_CHECK[f[2]] = T_CHECK[f[2]] " "; T_CHECK[f[2]] = T_CHECK[f[2]] f[3] }
  else if (f[1] == "rule" && n >= 3 && (f[2] in T_NAME) && T_DOM[f[2]] == "") {
    d = rule_domain(f[3]); if (d != "") T_DOM[f[2]] = d
  }
}
function t_overlay(line,   f, n, id, j) {
  sub(/\r$/, "", line)
  if (line == "" || line ~ /^#/) return
  n = split(line, f, "\t"); id = f[2]
  if (f[1] == "del") { T_DEL[id] = 1; return }
  if (f[1] == "svc" && n >= 3) {
    if ((id in T_NAME) && !T_USER[id]) { T_NAME[id] = f[3]; T_DEL[id] = 0; return }
    for (j = 1; j <= T_N; j++) if (!T_USER[T_ORDER[j]] && T_NAME[T_ORDER[j]] == f[3]) { T_ALIAS[id] = T_ORDER[j]; T_DEL[T_ORDER[j]] = 0; return }
    t_add(id, f[3]); T_USER[id] = 1; return
  }
  if (id in T_ALIAS) id = T_ALIAS[id]
  if (!(id in T_NAME)) return
  if (f[1] == "check" && n >= 3 && f[3] != "") T_OWNCHECK[id] = f[3]
  else if (f[1] == "dom" && n >= 4 && (f[3] == "full" || f[3] == "suffix") && T_OVDOM[id] == "") T_OVDOM[id] = f[4]
}
function t_print(   j, id, u) {
  for (j = 1; j <= T_N; j++) {
    id = T_ORDER[j]
    if (T_DEL[id]) continue
    if (T_OWNCHECK[id] != "") u = T_OWNCHECK[id]
    else if (T_CHECK[id] != "") u = T_CHECK[id]
    else if (T_DOM[id] != "") u = "https://" T_DOM[id]
    else if (T_OVDOM[id] != "") u = "https://" T_OVDOM[id]
    else u = "-"
    printf "%s\t%s\n", T_NAME[id], u
  }
}

# --- order ---
function order_print(   line, f, i, j, n, up, grp, key, tmp, k) {
  if (stab_file != "") {
    while ((getline line < stab_file) > 0) {
      n = split(line, f, "\t")
      if (n >= 6) { O_RS[f[1]] = f[5] + 0; O_RA[f[1]] = f[6] + 0 }
    }
    close(stab_file)
  }
  k = 0
  for (i = 1; i <= O_N; i++) {
    n = O_NAME[i]
    if ((n in O_RS) && O_RS[n] >= min_runs + 0 && O_RS[n] > 0) {
      if (O_RA[n] == 0) continue
      up = O_RA[n] * 100 / O_RS[n]
      grp = (up >= min_uptime + 0) ? 1 : 3
    } else { grp = 2; up = 0 }
    # ключ сортировки: группа, затем uptime по убыванию, затем исходный порядок
    k++; L_NAME[k] = n; L_G[k] = grp; L_U[k] = up; L_I[k] = i
  }
  for (i = 2; i <= k; i++) {
    j = i
    while (j > 1 && (L_G[j - 1] > L_G[j] || (L_G[j - 1] == L_G[j] && (L_U[j - 1] < L_U[j] || (L_U[j - 1] == L_U[j] && L_I[j - 1] > L_I[j]))))) {
      tmp = L_NAME[j]; L_NAME[j] = L_NAME[j - 1]; L_NAME[j - 1] = tmp
      tmp = L_G[j]; L_G[j] = L_G[j - 1]; L_G[j - 1] = tmp
      tmp = L_U[j]; L_U[j] = L_U[j - 1]; L_U[j - 1] = tmp
      tmp = L_I[j]; L_I[j] = L_I[j - 1]; L_I[j - 1] = tmp
      j--
    }
  }
  for (i = 1; i <= k; i++) print L_NAME[i]
}

# --- render ---
function jq(v,   i, c, out, L) {
  out = ""; L = length(v)
  for (i = 1; i <= L; i++) {
    c = substr(v, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else if (c < " " && c != "") out = out " "
    else out = out c
  }
  return "\"" out "\""
}
function jnum(v) { return (v ~ /^-?[0-9]+$/) ? v + 0 : "null" }
function jint(v) { return (v ~ /^[0-9]+$/) ? v + 0 : 0 }
function jarr(v,   n, a, i, out) {
  if (v == "") return "[]"
  n = split(v, a, US); out = ""
  for (i = 1; i <= n; i++) { if (i > 1) out = out ","; out = out jq(a[i]) }
  return "[" out "]"
}
function render_row(   f, n, sep) {
  n = split($0, f, "\t")
  if (f[1] == "") return
  sep = R_N ? "," : ""; R_N++
  printf "%s{\"name\":%s,\"chain\":%s,\"node\":%s,\"verdict\":%s,\"url\":%s,\"detail\":%s,\"ms\":%s,\"control_ms\":%s,\"alt\":{\"state\":%s,\"checked\":%s,\"limit\":%s,\"found\":%s}}", \
    sep, jq(f[1]), jarr(f[2]), jq(f[3]), jq(f[4]), jq(f[5]), jq(f[6]), jnum(f[7]), jnum(f[8]), \
    jq(f[9] == "" ? "none" : f[9]), jint(f[10]), jint(f[11]), jarr(f[12])
}
function render_head(   line, k, v, M) {
  while ((getline line < meta) > 0) {
    k = line; sub(/\t.*/, "", k); v = substr(line, length(k) + 2)
    M[k] = v
  }
  close(meta)
  printf "{\"id\":%s,\"running\":%s,\"stage\":%s,\"error\":%s,\"started\":%s,\"finished\":%s,\"current\":%s,\"total\":%s,\"done\":%s,\"services\":[", \
    jq(M["id"]), (M["running"] == 1 ? "true" : "false"), jq(M["stage"] == "" ? "none" : M["stage"]), jq(M["error"]), \
    jint(M["started"]), jint(M["finished"]), jq(M["current"]), jint(M["total"]), jint(M["done"])
}

BEGIN {
  US = "\037"
  if (mode == "resolve" || mode == "now") RS = "\001"
  if (mode == "render") render_head()
  # имя текущей ноды - через окружение: -v раскрывает \ в имени
  EXCL = ("DIAG_EXCLUDE" in ENVIRON) ? ENVIRON["DIAG_EXCLUDE"] : exclude
}

mode == "resolve" || mode == "now" { S = S $0 }
mode == "render" { render_row() }
mode == "order" { sub(/\r$/, ""); if ($0 != "" && $0 != EXCL && !($0 in O_SEEN)) { O_SEEN[$0] = 1; O_NAME[++O_N] = $0 } }
mode == "targets" { t_default($0) }

END {
  if (mode == "resolve") {
    parse_top()
    RS = "\n"
    while ((getline line < groups_file) > 0) { sub(/\r$/, "", line); if (line != "") resolve(line) }
    close(groups_file)
  } else if (mode == "now") {
    S = "{\"proxies\":{\"\001\":" S "}}"
    parse_top()
    if (NOW["\001"] != "") print NOW["\001"]
  } else if (mode == "render") {
    print "]}"
  } else if (mode == "order") {
    order_print()
  } else if (mode == "targets") {
    if (overlay_file != "") {
      while ((getline line < overlay_file) > 0) t_overlay(line)
      close(overlay_file)
    }
    t_print()
  }
}
