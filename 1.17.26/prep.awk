# Готовит ноды для замера скорости.
# Читает clash-yaml, нормализует отступы и заменяет имена техническими nNNNN.
# Inline-map намеренно не разбирается: при нём скрипт завершается с кодом 2.
# WGFILE (необязательно): WireGuard/AmneziaWG-ноды (type: wireguard) не
# печатаются в пул второго ядра (stdout), а перечисляются в WGFILE строками
# "idx<TAB>исходное имя" - их проверяют на уже работающем экземпляре в
# основном ядре (один ключ - один клиент). В MAPFILE и NODEDIR они остаются.
BEGIN {
  cnt = 0; inp = 0; ind = -1; in_node = 0; parse_error = 0
  nb = split(BLOCK, bl, "|")
  # "(?i)" в начале куска - след копирования exclude-filter из config.yaml:
  # здесь это не regex, регистр и так не учитывается, поэтому префикс
  # отбрасывается (иначе кусок искался бы буквально как "(?i)russia").
  for (i = 1; i <= nb; i++) { bl[i] = tolower(bl[i]); sub(/^[(][?]i[)]/, "", bl[i]) }
  if (EXTYPE == "") EXTYPE = "trojan"
  nt = split(EXTYPE, tp, "|")
  reset_node()
}

function reset_node() {
  n = 0
  bad = 0
  bname = ""
  nameline = -1
  gotname = 0
  gottype = 0
  in_node = 0
  ntype = ""
}

function flush(   i, j, sh, line, pfx, idx, f, pad, lname, is_wg) {
  if (!in_node || n == 0) { reset_node(); return }
  if (!gotname || !gottype) {
    print "prep.awk: proxy node is missing name or type" > "/dev/stderr"
    parse_error = 1
    reset_node()
    return
  }
  if (bad) { reset_node(); return }

  lname = tolower(bname)
  for (i = 1; i <= nb; i++) {
    if (bl[i] != "" && index(lname, bl[i]) > 0) { reset_node(); return }
  }

  cnt++
  idx = sprintf("n%04d", cnt)
  is_wg = (WGFILE != "" && ntype == "wireguard")
  f = NODEDIR "/" idx ".yaml"
  sh = ind - 2
  for (i = 0; i < n; i++) {
    line = buf[i]
    if (sh > 0) line = substr(line, sh + 1)
    else if (sh < 0) {
      pad = ""
      for (j = 0; j < -sh; j++) pad = pad " "
      line = pad line
    }
    print line > f
    if (is_wg) continue
    if (i == nameline) {
      pfx = line
      sub(/name:.*/, "name: " idx, pfx)
      print pfx
    } else print line
  }
  close(f)
  print idx "\t" bname > MAPFILE
  if (is_wg) print idx "\t" bname > WGFILE
  reset_node()
}

/^[^ \t#-]/ {
  if (inp) { flush(); inp = 0; ind = -1 }
}

/^proxies:[ \t]*$/ {
  inp = 1
  ind = -1
  next
}

/^#/ {
  if (inp) flush()
  next
}

{
  if (!inp) next

  if ($0 ~ /^[ \t]*-[ \t]*\{/) {
    flush()
    print "prep.awk: inline proxy maps are not supported" > "/dev/stderr"
    parse_error = 1
    next
  }

  is_item = ($0 ~ /^[ \t]*-[ \t]*$/ || $0 ~ /^[ \t]*-[ \t]+[^\{]/)
  if (is_item) {
    cur = index($0, "-") - 1
    if (ind < 0) ind = cur
    if (cur == ind) {
      flush()
      in_node = 1
    }
  }

  if (!in_node) next

  if ($0 ~ /^[ \t]*-?[ \t]*name:/) {
    nameline = n
    bname = $0
    sub(/^[ \t]*-?[ \t]*name:[ \t]*/, "", bname)
    gsub(/^["']|["'][ \t]*$/, "", bname)
    gotname = 1
  }

  if ($0 ~ /^[ \t]*type:/) {
    tv = $0
    sub(/^[ \t]*type:[ \t]*/, "", tv)
    gsub(/[ \t]+$/, "", tv)
    gottype = 1
    if (ntype == "") ntype = tv
    for (t = 1; t <= nt; t++) if (tv == tp[t]) bad = 1
  }

  buf[n++] = $0
}

END {
  if (inp) flush()
  print cnt > CNTFILE
  if (parse_error) exit 2
}
