# render_services.awk - собирает участки шаблона config.example.yaml со
# встроенными сервисами (группы, их rule-providers и rules) из таблицы
# services.default.tsv. См. docs/superpowers/specs/
# 2026-10-05-config-constructor-design.md, п. 1.1.
#
# Использование:
#   awk -v services_file=PATH -f render_services.awk TEMPLATE > OUT
#
# В шаблоне три пары маркеров (строки-комментарии, отступ любой):
#   # --- SERVICE_GROUPS:BEGIN ---    / # --- SERVICE_GROUPS:END ---
#   # --- SERVICE_PROVIDERS:BEGIN --- / # --- SERVICE_PROVIDERS:END ---
#   # --- SERVICE_RULES:BEGIN ---     / # --- SERVICE_RULES:END ---
# Строки маркеров выводятся как есть, всё между ними заменяется собранным
# текстом. Повторная сборка уже собранного шаблона не меняет его.
#
# services_file: поля через одну табуляцию, пустые строки и строки с # в
# начале пропускаются, порядок строк значим:
#   section<TAB>sid<TAB>Заголовок        раздел групп ("# --- Заголовок ---")
#   svc<TAB>id<TAB>Имя<TAB>sid           группа "<<: *select-default"
#   icon<TAB>id<TAB>url                  icon: группы
#   gkey<TAB>id<TAB>ключ: значение       доп. ключ группы как есть
#   prov<TAB>id|-<TAB>строка provider    строка rule-providers как есть
#   rule<TAB>id|-<TAB>текст правила      "- текст" в rules
# id в icon/gkey/prov/rule должен быть объявлен строкой svc выше; "-" -
# provider или правило без сервиса. Перед каждой серией правил одного
# сервиса выводится пустая строка и "# --- Имя ---"; перед серией правил
# без сервиса ("-"), идущей после правил сервиса, - "# --- Особые правила ---".
#
# Ошибка - сообщение в stderr, код 2, stdout пуст (вывод копится и
# печатается только в конце при успехе).
#
# busybox awk (роутер): функции объявлены до первого вызова, вызовы без
# пробела перед скобкой.
function err(msg) {
  if (!failed) printf "render_services.awk: %s\n", msg > "/dev/stderr"
  failed = 1
  exit 2
}
function need(n, want, kind) {
  if (n > want) err(services_file ", строка " ln ": лишняя табуляция в строке " kind " (табуляция внутри значения недопустима в YAML)")
  if (n < want) err(services_file ", строка " ln ": в строке " kind " не хватает полей (нужно " want ")")
}
function known(id, kind) {
  if (id == "-" && (kind == "prov" || kind == "rule")) return
  if (!(id in svc_name)) err(services_file ", строка " ln ": " kind " ссылается на сервис " id ", который не объявлен строкой svc выше")
}
function yname(s, t) {
  # Простое слово - без кавычек, кроме слов, которые YAML читает как
  # bool/null (true, no, null...): их - в кавычки, иначе это не строка.
  if (s ~ /^[A-Za-z][A-Za-z0-9_.-]*$/ && tolower(s) !~ /^(true|false|null|yes|no|on|off|y|n)$/) return s
  t = s
  gsub(/'/, "''", t)
  return "'" t "'"
}
function gen_groups(  out, i, j, sid) {
  out = ""
  for (i = 1; i <= nsec; i++) {
    sid = sec_id[i]
    if (!sec_count[sid]) continue
    out = out "  # --- " sec_title[sid] " ---\n"
    for (j = 1; j <= nsvc; j++) {
      if (svc_sec[svc_id[j]] != sid) continue
      out = out "  - name: " yname(svc_name[svc_id[j]]) "\n    <<: *select-default\n"
      if (svc_id[j] in svc_icon) out = out "    icon: " svc_icon[svc_id[j]] "\n"
      out = out svc_gkeys[svc_id[j]] "\n"
    }
  }
  return out
}
function gen_providers(  out, i) {
  out = ""
  for (i = 1; i <= nprov; i++) out = out "  " prov_text[i] "\n"
  return out
}
function gen_rules(  out, i, prev) {
  out = ""; prev = ""
  for (i = 1; i <= nrule; i++) {
    if (rule_owner[i] != "-" && rule_owner[i] != prev) out = out "\n  # --- " svc_name[rule_owner[i]] " ---\n"
    else if (rule_owner[i] == "-" && prev != "" && prev != "-") out = out "\n  # --- Особые правила ---\n"
    out = out "  - " rule_text[i] "\n"
    prev = rule_owner[i]
  }
  return out
}
BEGIN {
  failed = 0; nsec = 0; nsvc = 0; nprov = 0; nrule = 0; ln = 0
  if (services_file == "") err("не задан -v services_file")
  while ((rc = (getline line < services_file)) > 0) {
    ln++
    sub(/\r$/, "", line)
    if (line == "" || line ~ /^#/) continue
    n = split(line, f, "\t")
    kind = f[1]; id = f[2]
    if (kind == "section") {
      need(n, 3, kind)
      if (id in sec_title) err(services_file ", строка " ln ": раздел " id " повторяется")
      sec_id[++nsec] = id; sec_title[id] = f[3]
    } else if (kind == "svc") {
      need(n, 4, kind)
      if (id in svc_name) err(services_file ", строка " ln ": сервис " id " повторяется")
      if (!(f[4] in sec_title)) err(services_file ", строка " ln ": сервис " id " ссылается на раздел " f[4] ", который не объявлен строкой section выше")
      svc_id[++nsvc] = id; svc_name[id] = f[3]; svc_sec[id] = f[4]; sec_count[f[4]]++
      svc_gkeys[id] = ""
    } else if (kind == "icon") {
      need(n, 3, kind); known(id, kind)
      svc_icon[id] = f[3]
    } else if (kind == "gkey") {
      need(n, 3, kind); known(id, kind)
      svc_gkeys[id] = svc_gkeys[id] "    " f[3] "\n"
    } else if (kind == "prov") {
      need(n, 3, kind); known(id, kind)
      prov_text[++nprov] = f[3]
    } else if (kind == "rule") {
      need(n, 3, kind); known(id, kind)
      nrule++; rule_owner[nrule] = id; rule_text[nrule] = f[3]
    } else {
      err(services_file ", строка " ln ": неизвестный вид строки " kind " (ожидается section, svc, icon, gkey, prov или rule)")
    }
  }
  if (rc < 0) err("не удалось прочитать " services_file)
  close(services_file)
  mk[1] = "SERVICE_GROUPS"; mk[2] = "SERVICE_PROVIDERS"; mk[3] = "SERVICE_RULES"
  body[1] = gen_groups(); body[2] = gen_providers(); body[3] = gen_rules()
  inside = 0; out = ""
}
{
  for (i = 1; i <= 3; i++) {
    if (index($0, "# --- " mk[i] ":BEGIN ---")) {
      nbeg[i]++
      if (inside) err("шаблон, строка " FNR ": маркер " mk[i] ":BEGIN внутри другого блока маркеров")
      if (nend[i]) err("шаблон, строка " FNR ": маркер " mk[i] ":END раньше BEGIN")
      out = out $0 "\n" body[i]
      inside = i
      next
    }
    if (index($0, "# --- " mk[i] ":END ---")) {
      nend[i]++
      if (inside != i) err("шаблон, строка " FNR ": маркер " mk[i] ":END без BEGIN")
      inside = 0
      out = out $0 "\n"
      next
    }
  }
  if (!inside) out = out $0 "\n"
}
END {
  if (failed) exit 2
  for (i = 1; i <= 3; i++) {
    if (nbeg[i] != 1 || nend[i] != 1) err("в шаблоне должно быть ровно по одному маркеру " mk[i] ":BEGIN и " mk[i] ":END")
  }
  if (inside) err("в шаблоне не закрыт блок маркеров " mk[inside])
  printf "%s", out
}
