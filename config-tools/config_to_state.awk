# config_to_state.awk - состояние конструктора конфига из config.yaml:
# чем config.yaml отличается от встроенных сервисов (services.default.tsv)
# и шаблона. См. docs/superpowers/specs/2026-10-05-config-constructor-design.md,
# п. 1.2 и 5.
#
# Использование:
#   awk -v defaults=services.default.tsv -v template=config.example.yaml \
#       -v out_dir=DIR -v report=FILE -f config_to_state.awk config.yaml
#
# В out_dir пишутся:
#   services.tsv    - отличия (всегда, может быть пустым): del, unrule, svc,
#                     icon, src, dom, prov - формат в render_services.awk;
#   geofilter.txt   - слова фильтра нод, если exclude-filter: &geofilter
#                     отличается от шаблона;
#   user-rules.txt  - правила, которые не укладываются в сервисы, в
#                     исходном порядке (если есть).
# report: строки "IMPORTED|вид|имя" и "REVIEW|вид|имя" - без значений
# (ссылок, паролей), как отчёт migrate_config.awk.
#
# Разбор строчный, как у migrate_config.awk: группы - "  - name:" в
# proxy-groups, providers - "  имя:" в rule-providers (однострочные
# переносятся как есть), правила - "  - ..." в rules.
#
# Ошибка (нечитаемый вход) - stderr, код 2.
# busybox awk: функции до первого вызова, вызовы без пробела перед скобкой.
function err(msg) {
  if (!failed) printf "config_to_state.awk: %s\n", msg > "/dev/stderr"
  failed = 1
  exit 2
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function body(s) { sub(/[ \t]+#.*$/, "", s); return trim(s) }
function unq(s) {
  s = trim(s)
  if (s ~ /^'.*'$/) { s = substr(s, 2, length(s) - 2); gsub(/''/, "'", s) }
  else if (s ~ /^".*"$/) s = substr(s, 2, length(s) - 2)
  return s
}
# Цель правила: последнее поле, "no-resolve" в конце пропускается.
function target(b,  n, f) {
  n = split(b, f, ",")
  if (f[n] == "no-resolve" && n > 1) return f[n - 1]
  return f[n]
}
function geo_value(line) {
  if (match(line, /exclude-filter: &geofilter '[^']*'/)) {
    line = substr(line, RSTART, RLENGTH)
    sub(/^exclude-filter: &geofilter '/, "", line)
    sub(/'$/, "", line)
    return line
  }
  return ""
}
# Слово фильтра без экранирования ("C\+\+" -> "C++"); слово с настоящей
# регуляркой (неэкранированный спецсимвол) -> "\001": словами его не
# передать, фильтр остаётся в отчёте и берётся из шаблона.
function unescape(w,  out, i, c) {
  out = ""
  for (i = 1; i <= length(w); i++) {
    c = substr(w, i, 1)
    if (c == "\\" && i < length(w)) { i++; out = out substr(w, i, 1); continue }
    if (index("\\.^$*+?()[]{}", c)) return "\001"
    out = out c
  }
  return out
}
function rep(kind, name) { printf "%s|%s\n", kind, name > report }
function out_line(s) { svc_out = svc_out s "\n" }
function read_defaults(  rc, line, n, f) {
  while ((rc = (getline line < defaults)) > 0) {
    sub(/\r$/, "", line)
    if (line == "" || line ~ /^#/) continue
    n = split(line, f, "\t")
    if (f[1] == "svc") { nds++; ds_id[nds] = f[2]; ds_name[f[2]] = f[3]; name_to_id[f[3]] = f[2]; is_default_id[f[2]] = 1 }
    else if (f[1] == "prov") { p = f[3]; sub(/:.*/, "", p); default_prov[p] = f[2] }
    else if (f[1] == "rule") { ndr++; dr_owner[ndr] = f[2]; dr_text[ndr] = f[3]; dr_index[body(f[3])] = ndr }
  }
  if (rc < 0) err("не удалось прочитать " defaults)
  close(defaults)
}
function read_template(  rc, line, sect, inside, v, nm) {
  sect = ""; inside = 0
  while ((rc = (getline line < template)) > 0) {
    sub(/\r$/, "", line)
    if (index(line, "# --- SERVICE_") && index(line, ":BEGIN ---")) { inside = 1; continue }
    if (index(line, "# --- SERVICE_") && index(line, ":END ---")) { inside = 0; continue }
    if (inside) continue
    v = geo_value(line); if (v != "") tmpl_geo = v
    if (line ~ /^[A-Za-z0-9_-]+:/) { sect = line; sub(/:.*/, "", sect); continue }
    if (sect == "proxy-groups" && line ~ /^  - name:/) { nm = line; sub(/^  - name:/, "", nm); base_group[unq(nm)] = 1 }
    else if (sect == "rule-providers" && line ~ /^  [^ #-][^:]*:/) { nm = line; sub(/^  /, "", nm); sub(/:.*/, "", nm); tmpl_prov[nm] = 1 }
    else if (sect == "rules" && line ~ /^  - /) { nm = line; sub(/^  - /, "", nm); tmpl_rule[body(nm)] = 1 }
  }
  if (rc < 0) err("не удалось прочитать " template)
  close(template)
}
function new_id(name,  id, k) {
  id = tolower(name)
  gsub(/[^a-z0-9_-]/, "", id)
  if (id !~ /^[a-z0-9]/ || (id in is_default_id) || (id in used_id)) {
    k = 1
    while (("svc" k) in used_id || ("svc" k) in is_default_id) k++
    id = "svc" k
  }
  used_id[id] = 1
  return id
}
# provider-ссылки RULE-SET,имя внутри правила (и внутри OR/AND).
function carry_provs(b,  s, nm) {
  s = b
  while (match(s, /RULE-SET,[^,)]+/)) {
    nm = substr(s, RSTART + 9, RLENGTH - 9)
    s = substr(s, RSTART + RLENGTH)
    # provider встроенного сервиса пропускается, только пока сервис жив
    if (((nm in default_prov) && !(default_prov[nm] in deleted)) || (nm in tmpl_prov) || (nm in prov_done)) continue
    prov_done[nm] = 1
    if (nm in cfg_prov_line) { prov_out = prov_out "prov\t-\t" cfg_prov_line[nm] "\n"; rep("IMPORTED", "provider|" nm) }
    else rep("REVIEW", "provider-not-carried|" nm)
  }
}
BEGIN {
  failed = 0; nds = 0; ndr = 0; ngr = 0; nrules = 0; sect = ""; tmpl_geo = ""; cfg_geo = ""; inside = 0
  if (defaults == "" || template == "" || out_dir == "" || report == "") err("нужны -v defaults, template, out_dir, report")
  read_defaults()
  read_template()
  printf "" > report
}
{
  line = $0; sub(/\r$/, "", line)
  if (index(line, "# --- SERVICE_") && index(line, ":BEGIN ---")) next
  if (index(line, "# --- SERVICE_") && index(line, ":END ---")) next
  v = geo_value(line); if (v != "") cfg_geo = v
  if (line ~ /^[A-Za-z0-9_-]+:/) { sect = line; sub(/:.*/, "", sect); cur_group = ""; next }
  if (sect == "proxy-groups") {
    if (line ~ /^  - name:/) {
      nm = line; sub(/^  - name:/, "", nm); nm = unq(nm)
      ngr++; gr_name[ngr] = nm; cfg_group[nm] = ngr; cur_group = ngr
    } else if (cur_group != "" && line ~ /^    <<: \*select-default[ ]*$/) gr_select[cur_group] = 1
    else if (cur_group != "" && line ~ /^    icon:/) { v = line; sub(/^    icon:[ ]*/, "", v); gr_icon[cur_group] = trim(v) }
    else if (cur_group != "" && line ~ /^    [A-Za-z0-9_-]+:/) {
      # прочие ключи группы: однострочные -> gkey, вложенные - в отчёт
      v = line; sub(/^    [A-Za-z0-9_-]+:/, "", v)
      if (trim(v) == "" || trim(v) ~ /^[|>]/) gr_nested[cur_group] = 1
      else gr_keys[cur_group] = gr_keys[cur_group] substr(trim(line), 1) "\n"
    }
  } else if (sect == "rule-providers" && line ~ /^  [^ #-][^:]*:/) {
    nm = line; sub(/^  /, "", nm); sub(/:.*/, "", nm)
    v = line; sub(/^  [^:]*:/, "", v)
    if (trim(v) != "") cfg_prov_line[nm] = substr(line, 3)
    else if (!(nm in tmpl_prov)) rep("REVIEW", "multiline-provider|" nm)
  } else if (sect == "rules" && line ~ /^  - /) {
    v = line; sub(/^  - /, "", v)
    nrules++; cfg_rule[nrules] = body(v)
  }
}
END {
  if (failed) exit 2
  svc_out = ""; src_out = ""; dom_out = ""; prov_out = ""; user_out = ""
  # Встроенные сервисы, которых нет в config.yaml -> del.
  for (i = 1; i <= nds; i++) {
    if (!(ds_name[ds_id[i]] in cfg_group)) { out_line("del\t" ds_id[i]); deleted[ds_id[i]] = 1; rep("IMPORTED", "del|" ds_id[i]) }
  }
  # Свои группы.
  for (i = 1; i <= ngr; i++) {
    nm = gr_name[i]
    if ((nm in name_to_id) || (nm in base_group)) continue
    # Группы FAST-WG <нода> (и прежняя MST-FAST-WG) ведёт fast_wg.awk.
    if (nm ~ /^(MST-)?FAST-WG( |$)/) continue
    if (!gr_select[i]) { rep("REVIEW", "custom-group|" nm); continue }
    # имя идёт и в правила: , # : кавычки и пробелы по краям недопустимы
    if (nm == "" || nm ~ /[,#:'"]/ || nm ~ /^ / || nm ~ / $/) { rep("REVIEW", "custom-group-name|" i); continue }
    id = new_id(nm)
    custom_id[nm] = id
    cust_out = cust_out "svc\t" id "\t" nm "\tother\n"
    if ((i in gr_icon) && gr_icon[i] ~ /^https?:\/\/[^ "'#]+$/) cust_out = cust_out "icon\t" id "\t" gr_icon[i] "\n"
    else if (i in gr_icon) rep("REVIEW", "custom-group-icon|" nm)
    n = split(gr_keys[i], f, "\n")
    for (j = 1; j < n; j++) cust_out = cust_out "gkey\t" id "\t" f[j] "\n"
    if (i in gr_nested) rep("REVIEW", "custom-group-keys|" nm)
    rep("IMPORTED", "svc|" id)
  }
  # Правила.
  for (i = 1; i <= nrules; i++) {
    b = cfg_rule[i]
    if (b in tmpl_rule) continue
    if (b in dr_index) { seen_rule[dr_index[b]] = 1; continue }
    tg = target(b)
    id = ""
    if (tg in custom_id) id = custom_id[tg]
    else if ((tg in name_to_id) && !(name_to_id[tg] in deleted)) id = name_to_id[tg]
    n = split(b, f, ",")
    if (id != "" && n == 3 && f[1] ~ /^DOMAIN(-SUFFIX|-KEYWORD)?$/ && f[2] ~ /^[A-Za-z0-9*._-]+$/) {
      typ = (f[1] == "DOMAIN-SUFFIX" ? "suffix" : (f[1] == "DOMAIN" ? "full" : "keyword"))
      dom_out = dom_out "dom\t" id "\t" typ "\t" f[2] "\n"
      continue
    }
    if ((tg in custom_id) && f[1] == "RULE-SET" && (n == 3 || (n == 4 && f[4] == "no-resolve")) && (f[2] in cfg_prov_line) &&
        f[2] ~ /^[A-Za-z0-9][A-Za-z0-9._!-]*@(domain|ipcidr|classical)$/ && match(cfg_prov_line[f[2]], /url: "https?:\/\/[^ "]+"/)) {
      url = substr(cfg_prov_line[f[2]], RSTART + 6, RLENGTH - 7)
      pn = f[2]; kind = pn; sub(/.*@/, "", kind); sub(/@[^@]*$/, "", pn)
      src_out = src_out "src\t" id "\t" pn "\t" kind "\t" url "\n"
      prov_done[f[2]] = 1
      continue
    }
    user_out = user_out b "\n"
    carry_provs(b)
    rep("IMPORTED", "user-rule|" i)
  }
  # Встроенные правила, которых нет -> unrule (у удалённых сервисов - нет;
  # правила без сервиса "-" - тоже unrule, render_services.awk их понимает).
  for (i = 1; i <= ndr; i++) {
    if ((i in seen_rule) || (dr_owner[i] in deleted)) continue
    out_line("unrule\t" dr_owner[i] "\t" dr_text[i])
    rep("IMPORTED", "unrule|" dr_owner[i])
  }
  printf "%s%s%s%s%s", svc_out, cust_out, src_out, dom_out, prov_out > (out_dir "/services.tsv")
  close(out_dir "/services.tsv")
  if (user_out != "") { printf "%s", user_out > (out_dir "/user-rules.txt"); close(out_dir "/user-rules.txt") }
  if (cfg_geo != "" && cfg_geo != tmpl_geo) {
    g = cfg_geo; sub(/^\(\?i\)/, "", g)
    n = split(g, f, "|"); gout = ""; regex = 0
    for (i = 1; i <= n && !regex; i++) {
      w = unescape(trim(f[i]))
      if (w == "\001") regex = 1
      else if (w != "") gout = gout w "\n"
    }
    if (regex) rep("REVIEW", "geofilter-regex|-")
    else if (gout != "") { printf "%s", gout > (out_dir "/geofilter.txt"); close(out_dir "/geofilter.txt"); rep("IMPORTED", "geofilter|-") }
  }
  close(report)
}
