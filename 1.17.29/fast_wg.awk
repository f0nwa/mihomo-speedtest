# Прямые ссылки на WG-победителей в быстром пуле.
# WINNERS - файл имён по одному на строку; без него сохраняем текущий состав.
# TESTED - имена замеренных нод; остальные сохраняют прежнее участие.
# KEEP - прежний конфиг: ссылки из его блока FAST_WG_REF учитываются как
# текущий состав (сборка конструктора/миграция начинает с пустого блока).
# Старые группы FAST-WG между маркерами удаляются, новые не создаются.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function unquote(v) {
  v = trim(v)
  if (v ~ /^'/) {
    v = substr(v, 2); sub(/'[ \t]*(#.*)?$/, "", v); gsub(/''/, "'", v)
  } else if (v ~ /^"/) {
    v = substr(v, 2); sub(/"[ \t]*(#.*)?$/, "", v); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v)
  } else sub(/[ \t]+#.*$/, "", v)
  return v
}
function squote(v) { gsub(/'/, "''", v); return "'" v "'" }
function marker(s, name) { return s ~ ("^[ ]*# --- " name ":(BEGIN|END) ---($|[ ])") }
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
function flush_node() {
  if (node_name != "" && node_type == "wireguard") wg[++nwg] = node_name
  node_name = ""; node_type = ""
}
{
  line[++n] = $0
  if ($0 ~ /^[A-Za-z0-9_-]+:/) { if (in_proxies) flush_node(); in_proxies = ($0 ~ /^proxies:/) }
  else if (in_proxies) {
    if ($0 ~ /^  - /) flush_node()
    if ($0 ~ /^(  - |    )name:/) { v = $0; sub(/^[ -]*name:/, "", v); node_name = unquote(v) }
    if ($0 ~ /^(  - |    )type:/) { v = $0; sub(/^[ -]*type:/, "", v); node_type = unquote(v) }
  }
  if (marker($0, "FAST_WG") || marker($0, "FAST_WG_REF")) {
    if ($0 ~ /:BEGIN/) { if (open != "") bad = 1; open = ($0 ~ /FAST_WG_REF/ ? "R" : "G") }
    else { if (open != ($0 ~ /FAST_WG_REF/ ? "R" : "G")) bad = 1; open = "" }
  }
}
END {
  if (in_proxies) flush_node()
  if (bad || open != "") { print "fast_wg.awk: непарные маркеры FAST_WG в конфиге" > "/dev/stderr"; exit 2 }
  if (WINNERS != "") {
    while ((rc = (getline name < WINNERS)) > 0) wanted[name] = 1
    close(WINNERS)
    if (rc < 0) exit 2
  }
  if (TESTED != "") {
    while ((rc = (getline name < TESTED)) > 0) tested[name] = 1
    close(TESTED)
    if (rc < 0) exit 2
  }
  if (KEEP != "") {
    kin = 0
    while ((rc = (getline kl < KEEP)) > 0) {
      if (marker(kl, "FAST_WG_REF")) { kin = kl ~ /:BEGIN/; continue }
      if (kin) keep[++nkeep] = kl
    }
    close(KEEP)
    if (rc < 0) exit 2
    for (i = 1; i <= nkeep; i++) for (k = 1; k <= nwg; k++)
      if (in_flow(keep[i], wg[k])) wanted[wg[k]] = 1
  }
  if (WINNERS == "" || TESTED != "") {
    inside = 0
    for (i = 1; i <= n; i++) {
      if (marker(line[i], "FAST_WG_REF")) { inside = line[i] ~ /:BEGIN/; continue }
      if (inside) for (k = 1; k <= nwg; k++)
        if ((WINNERS == "" || !tested[wg[k]]) && in_flow(line[i], wg[k])) wanted[wg[k]] = 1
    }
  }
  for (i = 1; i <= n; i++) {
    s = line[i]
    if (skip && !(marker(s, "FAST_WG") || marker(s, "FAST_WG_REF"))) continue
    print s
    if (marker(s, "FAST_WG") && s ~ /:BEGIN/) {
      skip = 1
    } else if (marker(s, "FAST_WG_REF") && s ~ /:BEGIN/) {
      skip = 1
      if (nwg) {
        ind = s; sub(/#.*/, "", ind); ref = ""; sep = ""
        for (k = 1; k <= nwg; k++) if (wanted[wg[k]]) { ref = ref sep squote(wg[k]); sep = ", " }
        if (ref != "") print ind "proxies: [" ref "]"
      }
    } else if (s ~ /:END ---/ && (marker(s, "FAST_WG") || marker(s, "FAST_WG_REF"))) skip = 0
  }
}
