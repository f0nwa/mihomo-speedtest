# fast_wg.awk - служебная группа FAST-WG по WireGuard/AmneziaWG-нодам из
# proxies: конфига. Используется setup.sh (после render_config.awk) и
# migrate_config.sh (после migrate_config.awk); на вход - готовый конфиг,
# на выход - он же с перегенерированными блоками между маркерами:
#   # --- FAST_WG:BEGIN/END ---      сама группа FAST-WG (proxy-groups:)
#   # --- FAST_WG_REF:BEGIN/END ---  строка "proxies: [FAST-WG]" в '⚡ Быстрый пул'
# Есть ноды "type: wireguard" (AmneziaWG - тот же тип) - группа содержит
# [REJECT, <эти ноды>] (REJECT - "победителя нет", выбирает спидтест);
# нет - оба блока пустые. Маркеры остаются, повторный прогон ничего не
# меняет. Ноды из подписок не учитываются: их состав на момент сборки
# конфига неизвестен. Конфиг без маркеров выводится как есть; непарные
# маркеры - отказ (код 2, без вывода).
# Использование: awk -f fast_wg.awk CONFIG > NEW_CONFIG
# busybox awk (роутер): функции объявлены до вызова, без gensub.
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
function flush_node() {
  if (node_name != "" && node_type == "wireguard") wg = wg ", " squote(node_name)
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
  for (i = 1; i <= n; i++) {
    s = line[i]
    if (skip && !(marker(s, "FAST_WG") || marker(s, "FAST_WG_REF"))) continue
    print s
    if (marker(s, "FAST_WG") && s ~ /:BEGIN/) {
      skip = 1
      if (wg != "") {
        ind = s; sub(/#.*/, "", ind)
        print ind "- name: FAST-WG"
        print ind "  type: select"
        print ind "  proxies: [REJECT" wg "]"
        print ind "  hidden: true"
      }
    } else if (marker(s, "FAST_WG_REF") && s ~ /:BEGIN/) {
      skip = 1
      if (wg != "") { ind = s; sub(/#.*/, "", ind); print ind "proxies: [FAST-WG]" }
    } else if (s ~ /:END ---/ && (marker(s, "FAST_WG") || marker(s, "FAST_WG_REF"))) skip = 0
  }
}
