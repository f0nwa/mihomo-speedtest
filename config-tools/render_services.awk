# render_services.awk - собирает участки шаблона config.example.yaml со
# сервисами (группы, их rule-providers и rules) из таблицы встроенных
# сервисов services.default.tsv и, если заданы, пользовательских
# отличий, фильтра нод и своих правил. См. docs/superpowers/specs/
# 2026-10-05-config-constructor-design.md, п. 1.
#
# Использование:
#   awk -v services_file=PATH [-v overlay_file=PATH] [-v geofilter_file=PATH] \
#       [-v user_rules_file=PATH] -f render_services.awk TEMPLATE > OUT
#
# В шаблоне три пары маркеров (строки-комментарии, отступ любой):
#   # --- SERVICE_GROUPS:BEGIN ---    / # --- SERVICE_GROUPS:END ---
#   # --- SERVICE_PROVIDERS:BEGIN --- / # --- SERVICE_PROVIDERS:END ---
#   # --- SERVICE_RULES:BEGIN ---     / # --- SERVICE_RULES:END ---
# Строки маркеров выводятся как есть, всё между ними заменяется собранным
# текстом. Повторная сборка уже собранного шаблона не меняет его.
#
# services_file (встроенные сервисы): поля через одну табуляцию, пустые
# строки и строки с # в начале пропускаются, порядок строк значим:
#   section<TAB>sid<TAB>Заголовок        раздел групп ("# --- Заголовок ---")
#   svc<TAB>id<TAB>Имя<TAB>sid           группа "<<: *select-default"
#   icon<TAB>id<TAB>url                  icon: группы
#   gkey<TAB>id<TAB>ключ: значение       доп. ключ группы как есть
#   prov<TAB>id|-<TAB>строка provider    строка rule-providers как есть
#   rule<TAB>id|-<TAB>текст правила      "- текст" в rules
# id в icon/gkey/prov/rule должен быть объявлен строкой svc выше; "-" -
# provider или правило без сервиса.
#
# overlay_file (отличия пользователя, $DIR/config-state/services.tsv):
#   del<TAB>id                           убрать встроенный сервис (группу,
#                                        его правила и providers)
#   unrule<TAB>id<TAB>текст              убрать встроенное правило сервиса
#   svc<TAB>id<TAB>Имя<TAB>sid           свой сервис; с id или именем
#                                        встроенного - заменяет встроенный
#   icon<TAB>id<TAB>url                  иконка своего сервиса
#   gkey<TAB>id<TAB>ключ: значение       доп. ключ своей группы
#   src<TAB>id<TAB>имя<TAB>kind<TAB>url  набор правил: provider
#                                        имя@kind (kind domain|ipcidr|
#                                        classical) и RULE-SET на группу
#   dom<TAB>id<TAB>тип<TAB>домен         свой домен (тип suffix|full|keyword)
#   prov<TAB>-<TAB>строка provider       provider для своих правил
# del/unrule того, чего во встроенных нет, и icon/gkey/src/dom на сервис,
# которого больше нет (убрали в новом шаблоне), молча пропускаются - иначе
# обновление шаблона ломало бы сборку.
#
# geofilter_file: слова фильтра нод по одному в строке -> значение якоря
# exclude-filter: &geofilter '(?i)слово1|слово2' (пробелы по краям
# обрезаются, спецсимволы регулярки экранируются - слово ищется как есть).
# user_rules_file: свои правила по одному в строке (без "- ").
#
# Порядок блока правил: свои правила, свои домены, наборы своих сервисов,
# встроенные. Перед серией правил одного сервиса - "# --- Имя ---"; перед
# серией правил без сервиса после правил сервиса - "# --- Особые правила ---".
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
function at() { return cur ", строка " ln ": " }
function need(n, want, kind) {
  if (n > want) err(at() "лишняя табуляция в строке " kind " (табуляция внутри значения недопустима в YAML)")
  if (n < want) err(at() "в строке " kind " не хватает полей (нужно " want ")")
}
function known(id, kind) {
  if (id == "-" && (kind == "prov" || kind == "rule")) return
  if (!(id in svc_name) || (id in deleted)) err(at() kind " ссылается на сервис " id ", который не объявлен строкой svc выше (или убран del)")
}
function yname(s, t) {
  # Простое слово - без кавычек, кроме слов, которые YAML читает как
  # bool/null (true, no, null...): их - в кавычки, иначе это не строка.
  if (s ~ /^[A-Za-z][A-Za-z0-9_.-]*$/ && tolower(s) !~ /^(true|false|null|yes|no|on|off|y|n)$/) return s
  t = s
  gsub(/'/, "''", t)
  return "'" t "'"
}
# Ссылка из отличий на сервис: свой (ключ "u.id") важнее встроенного.
function ref(id) {
  if (("u." id) in svc_name) return "u." id
  return id
}
# Есть ли живой сервис с таким ключом.
function alive(k) { return (k in svc_name) && !(k in deleted) }
# Имя своей группы: идёт и в правила (RULE-SET,x,Имя), поэтому без , # : и
# кавычек, без пробелов по краям.
function check_name(nm) {
  if (nm == "" || nm ~ /[,#:'"]/ || nm ~ /^[ ]/ || nm ~ /[ ]$/) err(at() "имя группы \"" nm "\": нельзя , # : кавычки и пробелы по краям")
}
function check_url(u, what) {
  if (u !~ /^https?:\/\/[^ "'#]+$/) err(at() what " должен начинаться с http(s):// и не содержать пробелов, кавычек и #")
}
# Экранирование спецсимволов регулярки в слове фильтра.
function rx_escape(w,  out, i, c) {
  out = ""
  for (i = 1; i <= length(w); i++) {
    c = substr(w, i, 1)
    if (index("\\.^$*+?()[]{}", c)) out = out "\\"
    out = out c
  }
  return out
}
function provname(text, t) {
  t = text
  sub(/:.*/, "", t)
  return t
}
function add_svc(id, name, sid, user) {
  if ((id in svc_name) || (id in deleted)) err(at() "сервис " id " повторяется")
  if (!(sid in sec_title)) err(at() "сервис " id " ссылается на раздел " sid ", который не объявлен строкой section выше")
  svc_id[++nsvc] = id; svc_name[id] = name; svc_sec[id] = sid; svc_user[id] = user
  svc_gkeys[id] = ""
}
function read_defaults(  rc, n, f, kind, id) {
  cur = services_file; ln = 0
  while ((rc = (getline line < services_file)) > 0) {
    ln++
    sub(/\r$/, "", line)
    if (line == "" || line ~ /^#/) continue
    n = split(line, f, "\t")
    kind = f[1]; id = f[2]
    if (kind == "section") {
      need(n, 3, kind)
      if (id in sec_title) err(at() "раздел " id " повторяется")
      sec_id[++nsec] = id; sec_title[id] = f[3]
    } else if (kind == "svc") {
      need(n, 4, kind)
      add_svc(id, f[3], f[4], 0)
    } else if (kind == "icon") {
      need(n, 3, kind); known(id, kind)
      if (id in svc_icon) err(at() "у сервиса " id " иконка задана повторно")
      svc_icon[id] = f[3]
    } else if (kind == "gkey") {
      need(n, 3, kind); known(id, kind)
      svc_gkeys[id] = svc_gkeys[id] "    " f[3] "\n"
    } else if (kind == "prov") {
      need(n, 3, kind); known(id, kind)
      nprov++; prov_owner[nprov] = id; prov_text[nprov] = f[3]
      default_prov[provname(f[3])] = id
    } else if (kind == "rule") {
      need(n, 3, kind); known(id, kind)
      nrule++; rule_owner[nrule] = id; rule_text[nrule] = f[3]
      default_rule[id SUBSEP f[3]] = 1
    } else {
      err(at() "неизвестный вид строки " kind " (ожидается section, svc, icon, gkey, prov или rule)")
    }
  }
  if (rc < 0) err("не удалось прочитать " services_file)
  close(services_file)
}
function read_overlay(  rc, n, f, kind, id, pn, typ) {
  cur = overlay_file; ln = 0
  while ((rc = (getline line < overlay_file)) > 0) {
    ln++
    sub(/\r$/, "", line)
    if (line == "" || line ~ /^#/) continue
    n = split(line, f, "\t")
    kind = f[1]; id = f[2]
    if (kind == "del") {
      need(n, 2, kind)
      if ((id in svc_name) && !svc_user[id]) deleted[id] = 1
    } else if (kind == "unrule") {
      need(n, 3, kind)
      if ((id SUBSEP f[3]) in default_rule) unruled[id SUBSEP f[3]] = 1
    } else if (kind == "svc") {
      need(n, 4, kind)
      if (id !~ /^[a-z0-9][a-z0-9_-]*$/) err(at() "id своего сервиса " id ": только строчная латиница, цифры, - и _")
      check_name(f[3])
      if (("u." id) in svc_name) err(at() "сервис " id " повторяется")
      for (j = 1; j <= nsvc; j++) if (svc_user[svc_id[j]] && svc_name[svc_id[j]] == f[3]) err(at() "группа " f[3] " уже есть среди своих сервисов")
      # Свой сервис с id или именем встроенного заменяет встроенный (так
      # после обновления шаблона своя группа не сталкивается с новой).
      if (alive(id)) deleted[id] = 1
      for (j = 1; j <= nsvc; j++) if (!svc_user[svc_id[j]] && svc_name[svc_id[j]] == f[3]) deleted[svc_id[j]] = 1
      add_svc("u." id, f[3], f[4], 1)
    } else if (kind == "icon" || kind == "gkey" || kind == "src" || kind == "dom") {
      # Ссылка на сервис, которого больше нет (убран из шаблона или del), -
      # пропуск: устаревшее состояние не должно ломать сборку.
      id = ref(id)
      if (!alive(id)) continue
    }
    if (kind == "svc" || kind == "del" || kind == "unrule") {
    } else if (kind == "icon") {
      need(n, 3, kind)
      if (!svc_user[id]) err(at() "иконку можно задать только своему сервису, " f[2] " - встроенный")
      if (id in svc_icon) err(at() "у сервиса " f[2] " иконка задана повторно")
      check_url(f[3], "адрес иконки")
      svc_icon[id] = f[3]
    } else if (kind == "gkey") {
      need(n, 3, kind)
      if (!svc_user[id]) err(at() "доп. ключи можно задать только своему сервису, " f[2] " - встроенный")
      if (f[3] !~ /^[A-Za-z][A-Za-z0-9_-]*: [^ ]/ || f[3] ~ /^(name|<<):/) err(at() "доп. ключ группы пишется как \"ключ: значение\" (кроме name)")
      svc_gkeys[id] = svc_gkeys[id] "    " f[3] "\n"
    } else if (kind == "src") {
      need(n, 5, kind)
      if (f[3] !~ /^[A-Za-z0-9][A-Za-z0-9._!-]*$/) err(at() "имя набора правил " f[3] ": только латиница, цифры и . _ ! -")
      if (f[4] != "domain" && f[4] != "ipcidr" && f[4] != "classical") err(at() "вид набора " f[4] ": ожидается domain, ipcidr или classical")
      check_url(f[5], "адрес набора правил")
      pn = f[3] "@" f[4]
      if (!(pn in default_prov) || (default_prov[pn] in deleted)) {
        if (!(pn in user_prov_seen)) {
          user_prov_seen[pn] = 1
          nuprov++; uprov_text[nuprov] = pn ": { <<: *" f[4] ", url: \"" f[5] "\" }"
        }
      }
      nsrc++; src_owner[nsrc] = id
      src_text[nsrc] = "RULE-SET," pn "," svc_name[id]
      if (f[4] == "ipcidr") src_text[nsrc] = src_text[nsrc] ",no-resolve"
    } else if (kind == "dom") {
      need(n, 4, kind)
      if (f[3] == "suffix") typ = "DOMAIN-SUFFIX"
      else if (f[3] == "full") typ = "DOMAIN"
      else if (f[3] == "keyword") typ = "DOMAIN-KEYWORD"
      else err(at() "тип домена " f[3] ": ожидается suffix, full или keyword")
      if (f[4] !~ /^[A-Za-z0-9*._-]+$/) err(at() "домен " f[4] ": только латиница, цифры и . - _ *")
      ndom++; dom_text[ndom] = typ "," f[4] "," svc_name[id]
    } else if (kind == "prov") {
      need(n, 3, kind)
      if (id != "-") err(at() "в отличиях prov бывает только с владельцем -")
      nuprov++; uprov_text[nuprov] = f[3]
    } else {
      err(at() "неизвестный вид строки " kind " (ожидается del, unrule, svc, icon, src, dom или prov)")
    }
  }
  if (rc < 0) err("не удалось прочитать " overlay_file)
  close(overlay_file)
}
function read_geofilter(  rc, w) {
  cur = geofilter_file; ln = 0; geoval = ""
  while ((rc = (getline line < geofilter_file)) > 0) {
    ln++
    sub(/\r$/, "", line)
    sub(/^[ ]+/, "", line); sub(/[ ]+$/, "", line)
    if (line == "") continue
    if (line ~ /['|\t]/) err(at() "слово фильтра не может содержать ' | или табуляцию")
    if (geoval != "") geoval = geoval "|"
    geoval = geoval rx_escape(line)
  }
  if (rc < 0) err("не удалось прочитать " geofilter_file)
  close(geofilter_file)
  if (geoval == "") err(geofilter_file ": фильтр нод пуст - пустой фильтр исключил бы все ноды; удалите файл, чтобы вернуть фильтр шаблона")
  geoval = "(?i)" geoval
}
function read_user_rules(  rc) {
  cur = user_rules_file; ln = 0
  while ((rc = (getline line < user_rules_file)) > 0) {
    ln++
    sub(/\r$/, "", line)
    sub(/^[ ]+/, "", line); sub(/[ ]+$/, "", line)
    if (line == "") continue
    if (line ~ /\t/) err(at() "табуляция в правиле недопустима")
    if (line ~ /^-/) err(at() "правило пишется без ведущего \"- \"")
    nuser++; user_rule[nuser] = line
  }
  if (rc < 0) err("не удалось прочитать " user_rules_file)
  close(user_rules_file)
}
function gen_groups(  out, i, j, sid, id, cnt) {
  out = ""
  for (i = 1; i <= nsec; i++) {
    sid = sec_id[i]
    cnt = 0
    for (j = 1; j <= nsvc; j++) if (svc_sec[svc_id[j]] == sid && !(svc_id[j] in deleted)) cnt++
    if (!cnt) continue
    out = out "  # --- " sec_title[sid] " ---\n"
    for (j = 1; j <= nsvc; j++) {
      id = svc_id[j]
      if (svc_sec[id] != sid || (id in deleted)) continue
      out = out "  - name: " yname(svc_name[id]) "\n    <<: *select-default\n"
      if (id in svc_icon) out = out "    icon: " svc_icon[id] "\n"
      out = out svc_gkeys[id] "\n"
    }
  }
  return out
}
function gen_providers(  out, i) {
  out = ""
  for (i = 1; i <= nprov; i++) if (!(prov_owner[i] in deleted)) out = out "  " prov_text[i] "\n"
  for (i = 1; i <= nuprov; i++) out = out "  " uprov_text[i] "\n"
  return out
}
function gen_rules(  out, i, prev) {
  out = ""; prev = ""
  if (nuser) {
    out = out "\n  # --- Свои правила ---\n"
    for (i = 1; i <= nuser; i++) out = out "  - " user_rule[i] "\n"
    prev = "#user"
  }
  if (ndom) {
    out = out "\n  # --- Свои домены ---\n"
    for (i = 1; i <= ndom; i++) out = out "  - " dom_text[i] "\n"
    prev = "#dom"
  }
  for (i = 1; i <= nsrc; i++) {
    if (src_owner[i] != prev) out = out "\n  # --- " svc_name[src_owner[i]] " ---\n"
    out = out "  - " src_text[i] "\n"
    prev = src_owner[i]
  }
  for (i = 1; i <= nrule; i++) {
    if ((rule_owner[i] in deleted) || ((rule_owner[i] SUBSEP rule_text[i]) in unruled)) continue
    if (rule_owner[i] != "-" && rule_owner[i] != prev) out = out "\n  # --- " svc_name[rule_owner[i]] " ---\n"
    else if (rule_owner[i] == "-" && prev != "" && prev != "-") out = out "\n  # --- Особые правила ---\n"
    out = out "  - " rule_text[i] "\n"
    prev = rule_owner[i]
  }
  return out
}
BEGIN {
  failed = 0; nsec = 0; nsvc = 0; nprov = 0; nrule = 0; nuprov = 0; nsrc = 0; ndom = 0; nuser = 0; geoval = ""
  if (services_file == "") err("не задан -v services_file")
  read_defaults()
  if (overlay_file != "") read_overlay()
  if (geofilter_file != "") read_geofilter()
  if (user_rules_file != "") read_user_rules()
  mk[1] = "SERVICE_GROUPS"; mk[2] = "SERVICE_PROVIDERS"; mk[3] = "SERVICE_RULES"
  body[1] = gen_groups(); body[2] = gen_providers(); body[3] = gen_rules()
  inside = 0; out = ""; geohits = 0
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
  if (inside) next
  line = $0
  if (geoval != "" && match(line, /exclude-filter: &geofilter '[^']*'/)) {
    line = substr(line, 1, RSTART - 1) "exclude-filter: &geofilter '" geoval "'" substr(line, RSTART + RLENGTH)
    geohits++
  }
  out = out line "\n"
}
END {
  if (failed) exit 2
  for (i = 1; i <= 3; i++) {
    if (nbeg[i] != 1 || nend[i] != 1) err("в шаблоне должно быть ровно по одному маркеру " mk[i] ":BEGIN и " mk[i] ":END")
  }
  if (inside) err("в шаблоне не закрыт блок маркеров " mk[inside])
  if (geoval != "" && !geohits) err("в шаблоне нет exclude-filter: &geofilter - некуда подставить фильтр нод")
  printf "%s", out
}
