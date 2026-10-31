# wg_import.awk - импорт WireGuard/AmneziaWG .conf (формат wg-quick) в
# config.yaml mihomo. Используется stats_config.sh (действие import-wg
# вкладки «Конфиг»); на диск ничего не пишет.
#
# Использование:
#   awk -v LIST=<список> -v REPORT=<отчёт> -f wg_import.awk CONFIG > NEW_CONFIG
#   LIST   - строки "путь_к_.conf<TAB>имя ноды" (имя уже проверено вызывающим).
#   REPORT - строки отчёта:
#     ERROR|имя|причина         файл не импортирован
#     SKIPPED_KEY|имя|Ключ      ключ .conf пропущен (Linux-ключи, неизвестные)
#     ADDED|имя / REPLACED|имя  нода добавлена / заменена целиком на месте
#     GROUP|группа              имя дописано в proxies: [...] группы
#     GROUP_MISSING|группа      группы нет или её proxies: не однострочный
#   -v MODE=nodes - только напечатать блоки нод (для тестов перевода).
# Значения из .conf пишутся только в одинарных кавычках ('' внутри), числа
# проверяются - содержимое файла не может изменить структуру YAML.
# busybox awk (роутер): функции объявлены до вызова, без gensub; вызовы
# функций пишутся без пробела перед "(".
function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function squote(v) { gsub(/'/, "''", v); return "'" v "'" }
function is_num(v) { return v ~ /^[0-9]+$/ }
function err(name, why) { printf "ERROR|%s|%s\n", name, why >> REPORT; return "" }
function rep(line) { printf "%s\n", line >> REPORT }
# "a, b ,c" -> ['a', 'b', 'c']; пустые элементы отбрасываются.
function qlist(v, a, n, i, s, out, c) {
  n = split(v, a, ","); out = ""; c = 0
  for (i = 1; i <= n; i++) {
    s = trim(a[i]); if (s == "") continue
    if (c++) out = out ", "
    out = out squote(s)
  }
  return "[" out "]"
}
function unquote(v) {
  v = trim(v)
  if (v ~ /^'/) { v = substr(v, 2); sub(/'[ \t]*(#.*)?$/, "", v); gsub(/''/, "'", v) }
  else if (v ~ /^"/) { v = substr(v, 2); sub(/"[ \t]*(#.*)?$/, "", v); gsub(/\\"/, "\"", v) }
  else sub(/[ \t]+#.*$/, "", v)
  return v
}
function top(s) { return s ~ /^[A-Za-z0-9_-]+:/ }
function blank(s) { return s ~ /^[ \t\r]*$/ || s ~ /^[ \t]*#/ }
# Имя записи "  - name: X" / "  - {...}" не разбирается; name - в первой
# строке записи или строкой "    name:" ниже.
function entry_name(i, j, s) {
  for (j = i; j <= n && (j == i || L[j] !~ /^  - /) && !top(L[j]); j++) {
    s = L[j]
    if (s ~ /^(  - |    )name:/) { sub(/^[ -]*name:/, "", s); return unquote(s) }
  }
  return ""
}
# Есть ли имя в однострочном списке proxies: [...] (элементы - в кавычках
# '...'/"..." или без; запятые внутри кавычек - часть имени).
function in_flow(s, name,   body, j, ch, q, tok) {
  body = s; sub(/^[^\[]*\[/, "", body); sub(/\][ \t]*$/, "", body)
  q = ""; tok = ""
  for (j = 1; j <= length(body); j++) {
    ch = substr(body, j, 1)
    if (q != "") {
      tok = tok ch
      if (ch == q) {
        if (q == "'" && substr(body, j + 1, 1) == "'") { tok = tok "'"; j++ }
        else q = ""
      }
    } else if (ch == "'" || ch == "\"") { q = ch; tok = tok ch }
    else if (ch == ",") { if (unquote(tok) == name) return 1; tok = "" }
    else tok = tok ch
  }
  return unquote(tok) == name
}
function addcsv(old, v) { v = trim(v); return (old == "" ? v : (v == "" ? old : old ", " v)) }
# Перевод одного .conf в блок ноды. Ошибка - "" и строка ERROR в отчёте.
function convert(path, name,   line, first, sect, k, v, key, nif, npeer, f, a, n, i, s, host, port, ip4, ip6, dns, out, awg, AW, nAW) {
  delete f; first = 1; sect = ""; nif = 0; npeer = 0
  while ((getline line < path) > 0) {
    if (first) { sub(/^\357\273\277/, "", line); first = 0 }
    sub(/#.*$/, "", line)   # как wg-quick: всё после # - комментарий
    line = trim(line)
    if (line == "" || line ~ /^;/) continue
    if (line ~ /^\[[A-Za-z]+\]$/) {
      sect = tolower(line)
      if (sect == "[interface]") nif++
      else if (sect == "[peer]") npeer++
      continue
    }
    if (index(line, "=") == 0) continue
    k = trim(substr(line, 1, index(line, "=") - 1)); v = trim(substr(line, index(line, "=") + 1))
    key = tolower(k)
    if (sect == "[interface]" && key in IFKEY) {
      if (key == "address" || key == "dns") f[key] = addcsv(f[key], v); else f[key] = v
    } else if (sect == "[peer]" && npeer == 1 && key in PEERKEY) {
      if (key == "allowedips") f[key] = addcsv(f[key], v); else f[key] = v
    } else if (sect == "[interface]" || sect == "[peer]") {
      if (!((name SUBSEP k) in skipped)) { skipped[name, k] = 1; rep("SKIPPED_KEY|" name "|" k) }
    }
  }
  close(path)
  if (!nif || f["privatekey"] == "") return err(name, "нет PrivateKey в [Interface]")
  if (!npeer) return err(name, "нет [Peer]")
  if (npeer > 1) return err(name, "несколько [Peer] - поддерживается один")
  if (f["publickey"] == "") return err(name, "нет PublicKey в [Peer]")
  if (f["endpoint"] == "") return err(name, "нет Endpoint в [Peer]")
  s = f["endpoint"]
  if (s ~ /^\[/) {
    if (index(s, "]:") == 0) return err(name, "неверный Endpoint")
    host = substr(s, 2, index(s, "]:") - 2); port = substr(s, index(s, "]:") + 2)
  } else {
    if (s !~ /:[^:]*$/) return err(name, "неверный Endpoint")
    host = s; sub(/:[^:]*$/, "", host); port = s; sub(/^.*:/, "", port)
  }
  if (host == "") return err(name, "неверный Endpoint")
  if (!is_num(port) || port + 0 < 1 || port + 0 > 65535) return err(name, "неверное число: Port")
  if (f["mtu"] != "" && !is_num(f["mtu"])) return err(name, "неверное число: MTU")
  if (f["persistentkeepalive"] != "" && !is_num(f["persistentkeepalive"])) return err(name, "неверное число: PersistentKeepalive")
  nAW = split("jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime", AW, " ")
  awg = ""
  for (i = 1; i <= nAW; i++) {
    k = AW[i]
    if (!(k in f)) continue
    if (k ~ /^[ij][0-9]$/) { awg = awg "      " k ": " squote(f[k]) "\n"; continue }
    if (!(is_num(f[k]) || (k ~ /^h/ && f[k] ~ /^[0-9]+-[0-9]+$/))) return err(name, "неверное число: " IFKEY[k])
    awg = awg "      " k ": " f[k] "\n"
  }
  ip4 = ""; ip6 = ""
  n = split(f["address"], a, ",")
  for (i = 1; i <= n; i++) {
    s = trim(a[i]); sub(/\/.*$/, "", s)
    if (s == "") continue
    if (index(s, ":")) { if (ip6 == "") ip6 = s } else if (ip4 == "") ip4 = s
  }
  dns = ""
  n = split(f["dns"], a, ",")
  for (i = 1; i <= n; i++) { s = trim(a[i]); if (s ~ /^[0-9.]+$/ || index(s, ":")) dns = addcsv(dns, s) }
  out = "  - name: " squote(name) "\n    type: wireguard\n    server: " squote(host) "\n    port: " port "\n"
  if (ip4 != "") out = out "    ip: " squote(ip4) "\n"
  if (ip6 != "") out = out "    ipv6: " squote(ip6) "\n"
  out = out "    private-key: " squote(f["privatekey"]) "\n    public-key: " squote(f["publickey"]) "\n"
  if (f["presharedkey"] != "") out = out "    pre-shared-key: " squote(f["presharedkey"]) "\n"
  if (f["allowedips"] != "") out = out "    allowed-ips: " qlist(f["allowedips"]) "\n"
  if (dns != "") out = out "    dns: " qlist(dns) "\n"
  if (f["mtu"] != "") out = out "    mtu: " f["mtu"] "\n"
  if (f["persistentkeepalive"] != "") out = out "    persistent-keepalive: " f["persistentkeepalive"] "\n"
  if (awg != "") out = out "    amnezia-wg-option:\n" awg
  return out "    udp: true\n"
}
BEGIN {
  # Ключи [Interface]/[Peer], которые переводятся; значение - имя для
  # сообщений об ошибке. Остальные ключи - SKIPPED_KEY.
  n = split("privatekey=PrivateKey address=Address dns=DNS mtu=MTU jc=Jc jmin=Jmin jmax=Jmax s1=S1 s2=S2 s3=S3 s4=S4 h1=H1 h2=H2 h3=H3 h4=H4 i1=I1 i2=I2 i3=I3 i4=I4 i5=I5 j1=J1 j2=J2 j3=J3 itime=Itime", t, " ")
  for (i = 1; i <= n; i++) { split(t[i], kv, "="); IFKEY[kv[1]] = kv[2] }
  n = split("publickey presharedkey endpoint allowedips persistentkeepalive", t, " ")
  for (i = 1; i <= n; i++) PEERKEY[t[i]] = 1
  if (REPORT == "") REPORT = "/dev/stderr"
  n = 0   # дальше n - число строк конфига (L[1..n])
  nlist = 0
  while ((getline line < LIST) > 0) {
    tab = index(line, "\t"); if (!tab) continue
    nlist++; lpath[nlist] = substr(line, 1, tab - 1); lname[nlist] = substr(line, tab + 1)
  }
  close(LIST)
  if (MODE == "nodes") {
    for (i = 1; i <= nlist; i++) printf "%s", convert(lpath[i], lname[i])
    exit 0
  }
}
{ sub(/\r$/, ""); L[++n] = $0 }
END {
  if (MODE == "nodes") exit 0
  # 1. Перевод файлов. Повтор имени в одном импорте - ошибка второго.
  nb = 0
  for (i = 1; i <= nlist; i++) {
    if (lname[i] in seen) { err(lname[i], "имя ноды повторяется в импорте"); continue }
    seen[lname[i]] = 1
    b = convert(lpath[i], lname[i])
    if (b != "") { nb++; bname[nb] = lname[i]; bblock[nb] = b }
  }
  # 2. Секции proxies: и proxy-groups:.
  ps = 0; pe = n + 1; gs = 0; ge = n + 1
  for (i = 1; i <= n; i++) {
    if (!top(L[i])) continue
    if (ps && pe == n + 1 && i > ps) pe = i
    if (gs && ge == n + 1 && i > gs) ge = i
    if (L[i] ~ /^proxies:/) ps = i
    if (L[i] ~ /^proxy-groups:/) gs = i
  }
  if (ps && pe < ps) pe = n + 1
  # Записи proxies: начало/конец (без хвостовых пустых строк и комментариев).
  ins = 0
  if (ps) {
    last = ps
    for (i = ps + 1; i < pe; i++) {
      if (L[i] ~ /^  # --- STATIC_PROXIES:END ---/) { ins = i; continue }
      if (L[i] ~ /^  - /) {
        en = entry_name(i)
        for (j = i + 1; j < pe && L[j] !~ /^  - / && L[j] !~ /^  # --- /; j++) ;
        for (j = j - 1; j > i && blank(L[j]); j--) ;
        if (en != "" && !(en in estart)) { estart[en] = i; eend[en] = j }
        i = j
      }
      if (!blank(L[i]) && !ins) last = i
    }
  }
  for (k = 1; k <= nb; k++) {
    if (bname[k] in estart) { repl[estart[bname[k]]] = k; rep("REPLACED|" bname[k]) }
    else { newblk = newblk bblock[k]; rep("ADDED|" bname[k]) }
  }
  # 3. Группы: дописать имена в однострочный proxies: [...].
  ng = split("🚀 Авто по пингу|🛡️Fallback-Stable|⚙️Manual", G, "|")
  for (g = 1; g <= ng && nb; g++) {
    gl = 0
    if (gs) for (i = gs + 1; i < ge; i++) {
      if (L[i] !~ /^  - name:/) continue
      s = L[i]; sub(/^  - name:/, "", s)
      if (unquote(s) != G[g]) continue
      for (j = i + 1; j < ge && L[j] !~ /^  - /; j++) if (L[j] ~ /^    proxies:[ \t]*\[.*\][ \t]*$/) { gl = j; break }
      break
    }
    if (!gl) { rep("GROUP_MISSING|" G[g]); continue }
    added = 0
    for (k = 1; k <= nb; k++) {
      if (in_flow(L[gl], bname[k])) continue
      s = L[gl]; sub(/\][ \t]*$/, "", s)
      sep = ", "; if (s ~ /\[[ \t]*$/) sep = ""
      L[gl] = s sep squote(bname[k]) "]"
      added = 1
    }
    if (added) rep("GROUP|" G[g])
  }
  # 4. Вывод.
  if (!ps) {
    at = 0
    for (i = 1; i <= n; i++) if (L[i] ~ /^proxy-providers:/) { at = i; break }
    if (!at) for (i = 1; i <= n; i++) if (L[i] ~ /^proxy-groups:/) { at = i; break }
  }
  for (i = 1; i <= n; i++) {
    if (!ps && i == at && newblk != "") { printf "proxies:\n%s\n", newblk; newblk = "" }
    if (i == ps && L[i] ~ /^proxies:[ \t]*\[[ \t]*\][ \t]*$/) { print "proxies:"; printf "%s", newblk; newblk = ""; continue }
    if (i in repl) {
      printf "%s", bblock[repl[i]]
      en = bname[repl[i]]
      # заменена последняя запись секции - новые ноды встают сразу за ней
      if (ps && !ins && last >= i && last <= eend[en]) { printf "%s", newblk; newblk = "" }
      i = eend[en]; continue
    }
    if (ps && ins && i == ins) { printf "%s", newblk; newblk = "" }
    print L[i]
    if (ps && !ins && i == last) { printf "%s", newblk; newblk = "" }
  }
  if (newblk != "") printf "proxies:\n%s", newblk
}
