# Готовит ноды для замера скорости.
# Читает clash-yaml, нормализует отступы и заменяет имена техническими nNNNN.
# Inline-map намеренно не разбирается: при нём скрипт завершается с кодом 2.
BEGIN {
  cnt = 0; inp = 0; ind = -1; in_node = 0; parse_error = 0
  nb = split(BLOCK, bl, "|")
  for (i = 1; i <= nb; i++) bl[i] = tolower(bl[i])
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
}

function flush(   i, j, sh, line, pfx, idx, f, pad, lname) {
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
    if (i == nameline) {
      pfx = line
      sub(/name:.*/, "name: " idx, pfx)
      print pfx
    } else print line
  }
  close(f)
  print idx "\t" bname > MAPFILE
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
    for (t = 1; t <= nt; t++) if (tv == tp[t]) bad = 1
  }

  buf[n++] = $0
}

END {
  if (inp) flush()
  print cnt > CNTFILE
  if (parse_error) exit 2
}
