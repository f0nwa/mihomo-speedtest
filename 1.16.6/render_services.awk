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
#   fresh<TAB>id|-<TAB>текст правила     пометка: правило добавлено после
#                                        прошлого релиза (при сборке не нужна,
#                                        config_to_state.awk не считает его
#                                        убранным пользователем)
#   check<TAB>id<TAB>url                 адрес проверки сервиса для вкладки
#                                        «Диагностика» (stats_diag.sh,
#                                        web/diag.awk mode=targets); строк
#                                        может быть несколько, первая -
#                                        основная. В сборке не участвует
#   gone<TAB>id|-<TAB>текст правила      бывшее встроенное правило (заменено
#                                        или убрано): при сборке не нужно,
#                                        config_to_state.awk не переносит его
#                                        из старого конфига в свои правила
# id в icon/gkey/prov/rule должен быть объявлен строкой svc выше; "-" -
# provider или правило без сервиса.
#
# overlay_file (отличия пользователя, $DIR/config-state/services.tsv):
#   del<TAB>id                           убрать встроенный сервис (группу,
#                                        его правила и providers)
#   unrule<TAB>id<TAB>текст              убрать встроенное правило сервиса
#   svc<TAB>id<TAB>Имя<TAB>sid           свой сервис; с id или именем
#                                        встроенного - заменяет встроенный
#   icon<TAB>id<TAB>url                  иконка своего сервиса или замена
#                                        иконки встроенного сервиса
#   gkey<TAB>id<TAB>ключ: значение       доп. ключ своей группы
#   src<TAB>id<TAB>имя<TAB>kind<TAB>url  набор правил: provider
#                                        имя@kind (kind domain|ipcidr|
#                                        classical) и RULE-SET на группу
#   dom<TAB>id<TAB>тип<TAB>домен         свой домен (тип suffix|full|keyword)
#   check<TAB>id<TAB>url                 свой адрес проверки сервиса для
#                                        вкладки «Диагностика»; в сборке не
#                                        участвует
#   noquic<TAB>id                        блокировать QUIC (UDP/443) сервиса:
#                                        в блок «Блокировка QUIC» после своих
#                                        правил идёт AND,((NETWORK,UDP),
#                                        (DST-PORT,443),(OR,(...))),REJECT
#                                        # QUIC: Имя - по его доменам, наборам
#                                        и простым правилам (RULE-SET, DOMAIN*,
#                                        IP-CIDR*, IP-ASN, GEOIP); сервис без
#                                        таких правил - без строки
#   prov<TAB>-<TAB>строка provider       provider для своих правил
#   bset<TAB>группа<TAB>ключ<TAB>знач.   базовая группа шаблона: interval
#                                        (10..86400 с), tolerance (0..10000 мс),
#                                        type (select|url-test|fallback),
#                                        url (http(s)://...), lazy (true|false).
#                                        Смена type: у select убираются url,
#                                        interval, tolerance, lazy; у url-test/
#                                        fallback недостающие добавляются после
#                                        type: (url generate_204, interval 600,
#                                        tolerance 50 - только url-test, lazy
#                                        true), у fallback tolerance убирается.
#                                        У группы с use: [fast] (быстрый пул)
#                                        можно менять только interval,
#                                        tolerance и lazy
#   bmembers<TAB>группа<TAB>т1|т2|...    состав базовой группы: другие базовые
#                                        группы, DIRECT, REJECT по порядку
#                                        (пусто - групповых нет). Остальные
#                                        токены proxies: [...] (примерные
#                                        ноды, __OWN_NODES__) сохраняются
#                                        после них. Цикл групп и пустая группа
#                                        (нет use:, нет токенов) - ошибка
#   ownscope<TAB>all                     свои ноды (блок proxies:) попадают не
#                                        только в базовые группы, но и во все
#                                        сервисные: в список якоря select-default
#                                        (и в свой proxies: [...] сервиса, если
#                                        он перебивает якорь)
#                                        добавляется служебный токен __OWN_NODES__,
#                                        который migrate_config.awk заменяет
#                                        именами своих нод (или убирает, если
#                                        своих нод нет)
#   bfirst<TAB>группа|*<TAB>значение     поставить значение первым в
#                                        proxies: [...] базовой группы
#                                        (по умолчанию выбирается первое);
#                                        * - у всех сервисных групп
#                                        (якорь select-default)
# del/unrule того, чего во встроенных нет, icon/gkey/src/dom на сервис,
# которого больше нет (убрали в новом шаблоне), и bset/bfirst/bmembers
# (и токены bmembers) на группу,
# ключ или значение, которых в шаблоне нет, молча пропускаются - иначе
# обновление шаблона ломало бы сборку.
#
# geofilter_file: слова фильтра нод по одному в строке (повторы без учёта
# регистра отбрасываются) -> значение якоря
# exclude-filter: &geofilter '(?i)слово1|слово2' (пробелы по краям
# обрезаются, спецсимволы регулярки экранируются - слово ищется как есть).
# user_rules_file: свои правила по одному в строке (без "- ").
#
# Порядок блока правил: свои правила, блокировка QUIC, свои домены, наборы
# своих сервисов, встроенные. Перед серией правил одного сервиса - "# --- Имя ---"; перед
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
  if (id == "-" && (kind == "prov" || kind == "rule" || kind == "fresh" || kind == "gone")) return
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
function unq(v) {
  sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
  if (v ~ /^'.*'$/) { v = substr(v, 2, length(v) - 2); gsub(/''/, "'", v) }
  else if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
  return v
}
# В строке с "proxies: [...]" поставить значение val первым; пустая строка -
# в списке такого значения нет (строка остаётся как была).
function reorder(l, val,  st, j, ch, q, tok, n, i, pre, post, hit, res, tk, t) {
  st = index(l, "proxies: [")
  if (!st) return ""
  pre = substr(l, 1, st + 9)
  n = 0; tok = ""; q = ""
  for (j = st + 10; j <= length(l); j++) {
    ch = substr(l, j, 1)
    if (q != "") {
      tok = tok ch
      if (ch == q) { if (q == "'" && substr(l, j + 1, 1) == "'") { tok = tok "'"; j++ } else q = "" }
    } else if (ch == "'" || ch == "\"") { q = ch; tok = tok ch }
    else if (ch == "," || ch == "]") {
      t = tok; sub(/^[ ]+/, "", t); sub(/[ ]+$/, "", t)
      if (t != "") tk[++n] = t
      tok = ""
      if (ch == "]") break
    } else tok = tok ch
  }
  post = substr(l, j)
  hit = 0
  for (i = 1; i <= n; i++) if (unq(tk[i]) == val) { hit = i; break }
  if (!hit) return ""
  res = tk[hit]
  for (i = 1; i <= n; i++) if (i != hit) res = res ", " tk[i]
  return pre res post
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
    } else if (kind == "fresh" || kind == "gone" || kind == "check") {
      need(n, 3, kind); known(id, kind)
    } else {
      err(at() "неизвестный вид строки " kind " (ожидается section, svc, icon, gkey, prov, rule, check, fresh или gone)")
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
    } else if (kind == "icon" || kind == "gkey" || kind == "src" || kind == "dom" || kind == "noquic") {
      # Ссылка на сервис, которого больше нет (убран из шаблона или del), -
      # пропуск: устаревшее состояние не должно ломать сборку.
      id = ref(id)
      if (!alive(id)) continue
    }
    if (kind == "svc" || kind == "del" || kind == "unrule") {
    } else if (kind == "icon") {
      need(n, 3, kind)
      if (id in overlay_icon_seen) err(at() "у сервиса " f[2] " иконка задана повторно")
      check_url(f[3], "адрес иконки")
      overlay_icon_seen[id] = 1
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
      ndom++; dom_text[ndom] = typ "," f[4] "," svc_name[id]; dom_owner[ndom] = id
    } else if (kind == "noquic") {
      need(n, 2, kind)
      noquic[id] = 1
    } else if (kind == "prov") {
      need(n, 3, kind)
      if (id != "-") err(at() "в отличиях prov бывает только с владельцем -")
      nuprov++; uprov_text[nuprov] = f[3]
    } else if (kind == "bset") {
      need(n, 4, kind)
      if (f[3] !~ /^(interval|tolerance|type|url|lazy)$/) err(at() "у базовой группы можно менять interval, tolerance, type, url или lazy, не " f[3])
      if (f[3] == "interval" || f[3] == "tolerance") {
        if (f[4] !~ /^[0-9]+$/) err(at() f[3] " - целое число")
        if (f[3] == "interval" && (f[4] + 0 < 10 || f[4] + 0 > 86400)) err(at() "interval - от 10 до 86400 секунд")
        if (f[3] == "tolerance" && f[4] + 0 > 10000) err(at() "tolerance - от 0 до 10000 мс")
        f[4] = f[4] + 0
      } else if (f[3] == "type") {
        if (f[4] !~ /^(select|url-test|fallback)$/) err(at() "type - select, url-test или fallback")
      } else if (f[3] == "url") check_url(f[4], "url")
      else if (f[4] !~ /^(true|false)$/) err(at() "lazy - true или false")
      if ((id SUBSEP f[3]) in bset) err(at() f[3] " группы " id " задан повторно")
      bset[id SUBSEP f[3]] = f[4]
    } else if (kind == "bmembers") {
      need(n, 3, kind)
      if (id in bmem) err(at() "bmembers для " id " задан повторно")
      bm_n = (f[3] == "") ? 0 : split(f[3], BMT, "|")
      for (bm_i = 1; bm_i <= bm_n; bm_i++) {
        if (BMT[bm_i] == "" || BMT[bm_i] ~ /^ | $/) err(at() "bmembers " id ": пустое имя в составе")
        if (BMT[bm_i] == id) err(at() "группа " id " не может входить сама в себя")
        if ((id SUBSEP BMT[bm_i]) in bmem_has) err(at() "в составе группы " id " повторяется " BMT[bm_i])
        bmem_has[id SUBSEP BMT[bm_i]] = 1
      }
      bmem[id] = f[3]
    } else if (kind == "ownscope") {
      need(n, 2, kind)
      if (f[2] != "all") err(at() "ownscope: единственное значение - all")
      if (ownscope) err(at() "ownscope задан повторно")
      ownscope = 1
    } else if (kind == "bfirst") {
      need(n, 3, kind)
      if (f[3] == "" || f[3] ~ /[\r]/) err(at() "bfirst: пустое значение")
      if (id in bfirst) err(at() "bfirst для " id " задан повторно")
      bfirst[id] = f[3]
    } else if (kind == "check") {
      need(n, 3, kind)
    } else {
      err(at() "неизвестный вид строки " kind " (ожидается del, unrule, svc, icon, src, dom, check, noquic, prov, bset, bmembers, bfirst или ownscope)")
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
    if (tolower(line) in geo_seen) continue
    geo_seen[tolower(line)] = 1
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
# Доп. ключи сервиса. Свой "proxies: [...]" целиком
# перебивает список якоря select-default, поэтому то, что делается с якорем
# для всех сервисных групп (bfirst * и ownscope), повторяется и здесь -
# иначе такой сервис остаётся без своих нод и со старым порядком.
function svc_keys(id,  n, a, i, l, r, res) {
  if (!ownscope && !("*" in bfirst)) return svc_gkeys[id]
  n = split(svc_gkeys[id], a, "\n"); res = ""
  for (i = 1; i < n; i++) {
    l = a[i]
    if (l ~ /^    proxies: \[/) {
      if ("*" in bfirst) { r = reorder(l, bfirst["*"]); if (r != "") l = r }
      if (ownscope) l = add_own(l)
    }
    res = res l "\n"
  }
  return res
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
      out = out svc_keys(id) "\n"
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
# Условие правила для блокировки QUIC: "ТИП,значение" простого правила
# сервиса (без цели и параметров); логические правила, регулярки и прочее -
# пусто (не входят).
function quic_cond(t,  n, f) {
  sub(/[ \t]+#.*$/, "", t)
  if (t ~ /[()]/) return ""
  n = split(t, f, ",")
  if (n < 3 || f[2] == "") return ""
  if (f[1] !~ /^(RULE-SET|DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-WILDCARD|IP-CIDR|IP-CIDR6|IP-ASN|GEOIP)$/) return ""
  return f[1] "," f[2]
}
function quic_add(c) {
  if (c == "" || (c in QSEEN)) return
  QSEEN[c] = 1
  QCOND = QCOND (QCNT ? "," : "") "(" c ")"
  QCNT++
}
# Блок «Блокировка QUIC»: по строке на сервис с noquic, в порядке сервисов.
function gen_quic(  out, j, id, i, r) {
  out = ""
  for (j = 1; j <= nsvc; j++) {
    id = svc_id[j]
    if ((id in deleted) || !(id in noquic)) continue
    delete QSEEN; QCOND = ""; QCNT = 0
    for (i = 1; i <= ndom; i++) if (dom_owner[i] == id) quic_add(quic_cond(dom_text[i]))
    for (i = 1; i <= nsrc; i++) if (src_owner[i] == id) quic_add(quic_cond(src_text[i]))
    for (i = 1; i <= nrule; i++) {
      if (rule_owner[i] != id || ((id SUBSEP rule_text[i]) in unruled)) continue
      quic_add(quic_cond(rule_text[i]))
    }
    if (!QCNT) continue
    if (QCNT == 1) r = "AND,((NETWORK,UDP),(DST-PORT,443)," QCOND "),REJECT"
    else r = "AND,((NETWORK,UDP),(DST-PORT,443),(OR,(" QCOND "))),REJECT"
    out = out "  - " r " # QUIC: " svc_name[id] "\n"
  }
  return out
}
function gen_rules(  out, i, prev, q) {
  out = ""; prev = ""
  if (nuser) {
    out = out "\n  # --- Свои правила ---\n"
    for (i = 1; i <= nuser; i++) out = out "  - " user_rule[i] "\n"
    prev = "#user"
  }
  q = gen_quic()
  if (q != "") {
    out = out "\n  # --- Блокировка QUIC ---\n" q
    prev = "#quic"
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
# Список "proxies: [...]" в строке l с добавленным служебным токеном свои-ноды
# (см. ownscope в шапке); токен уже есть - строка как есть.
function add_own(l,  st, e, inner) {
  if (index(l, "__OWN_NODES__")) return l
  st = index(l, "proxies: [")
  if (!st) return l
  e = index(substr(l, st), "]")
  if (!e) return l
  e = st + e - 1
  inner = substr(l, st + 10, e - (st + 10))
  return substr(l, 1, e - 1) (inner ~ /[^ ]/ ? ", " : "") "__OWN_NODES__" substr(l, e)
}
# Токены "proxies: [...]" строки l -> PTR[1..n] как в тексте (с кавычками);
# возвращает n (-1 - в строке нет списка).
function ptoks(l,  st, j, ch, q, tok, n, t) {
  delete PTR
  st = index(l, "proxies: [")
  if (!st) return -1
  n = 0; tok = ""; q = ""
  for (j = st + 10; j <= length(l); j++) {
    ch = substr(l, j, 1)
    if (q != "") {
      tok = tok ch
      if (ch == q) { if (q == "'" && substr(l, j + 1, 1) == "'") { tok = tok "'"; j++ } else q = "" }
    } else if (ch == "'" || ch == "\"") { q = ch; tok = tok ch }
    else if (ch == "," || ch == "]") {
      t = tok; sub(/^[ ]+/, "", t); sub(/[ ]+$/, "", t)
      if (t != "") PTR[++n] = t
      tok = ""
      if (ch == "]") break
    } else tok = tok ch
  }
  return n
}
# Групповой токен состава: другая базовая группа, DIRECT или REJECT.
function grp_tok(t) { return t == "DIRECT" || t == "REJECT" || (t in BGI) }
function bval(nm, k, def) {
  if ((nm SUBSEP k) in bset) return bset[nm SUBSEP k]
  return def
}
function bline(k, v) { if (k == "url") v = "\"" v "\""; return "    " k ": " v }
# Базовые группы (proxy-groups до SERVICE_GROUPS:BEGIN) копятся в BL[] и
# обрабатываются здесь целиком: состав ссылается и на группы ниже по тексту.
function flush_base(  g, i, a, e, nm, ty, nty, chg, fast, haskey, k, n, lst, c, gt, pl, ins, live, changed, cnt, path, seen, x, y) {
  if (!nbl) return
  for (g = 1; g <= ngb; g++) BGI[GBN[g]] = g
  for (g = 1; g <= ngb; g++) GBE[g] = (g < ngb ? GBS[g + 1] - 1 : nbl)
  if (GBS[1] > 1) for (i = 1; i < GBS[1]; i++) out = out BL[i] "\n"
  for (g = 1; g <= ngb; g++) {
    nm = GBN[g]; ty = ""; fast = 0; pl = 0; has_use = 0
    delete haskey
    for (i = GBS[g] + 1; i <= GBE[g]; i++) {
      if (BL[i] ~ /^    type:/) { ty = BL[i]; sub(/^    type:[ ]*/, "", ty); sub(/[ ]+$/, "", ty) }
      else if (BL[i] ~ /^    use:[ ]*\[fast\]/) { fast = 1; has_use = 1 }
      else if (BL[i] ~ /^    (use|include-all):/) has_use = 1
      else if (BL[i] ~ /^    proxies: \[/) pl = i
      if (match(BL[i], /^    (url|interval|tolerance|lazy):/)) haskey[substr(BL[i], 5, RLENGTH - 5)] = 1
    }
    if (fast && (((nm SUBSEP "type") in bset) || ((nm SUBSEP "url") in bset) || (nm in bmem))) err("у группы " nm " можно менять только interval, tolerance и lazy")
    chg = ((nm SUBSEP "type") in bset)
    nty = chg ? bset[nm SUBSEP "type"] : ty
    # итоговый список proxies
    lst = ""; cnt = 0; delete gt
    if (pl) n = ptoks(BL[pl]); else n = 0
    if (nm in bmem) {
      c = (bmem[nm] == "") ? 0 : split(bmem[nm], a, "|")
      for (i = 1; i <= c; i++) if (grp_tok(a[i]) && a[i] != nm) { x = cnt++ ? ", " : ""; lst = lst x yname(a[i]) }
      for (i = 1; i <= n; i++) if (!grp_tok(unq(PTR[i]))) { x = cnt++ ? ", " : ""; lst = lst x PTR[i] }
      newpl = "    proxies: [" lst "]"
    } else newpl = pl ? BL[pl] : ""
    if ((nm in bfirst) && newpl != "") { e = reorder(newpl, bfirst[nm]); if (e != "") newpl = e }
    # рёбра для проверки циклов и пустоты
    c = (newpl != "") ? ptoks(newpl) : 0
    GBC[g] = ""
    for (i = 1; i <= c; i++) { x = unq(PTR[i]); if (x in BGI) GBC[g] = GBC[g] SUBSEP BGI[x] }
    if ((nm in bmem) && c <= 0 && !has_use) err("группа " nm " пустая: добавьте в неё группу или DIRECT")
    out = out BL[GBS[g]] "\n"
    for (i = GBS[g] + 1; i <= GBE[g]; i++) {
      if (BL[i] ~ /^    type:/) {
        x = chg ? "    type: " nty : BL[i]
        out = out x "\n"
        if (chg && nty != "select") {
          if (!("url" in haskey)) out = out bline("url", bval(nm, "url", "https://www.gstatic.com/generate_204")) "\n"
          if (!("interval" in haskey)) out = out bline("interval", bval(nm, "interval", 600)) "\n"
          if (nty == "url-test" && !("tolerance" in haskey)) out = out bline("tolerance", bval(nm, "tolerance", 50)) "\n"
          if (!("lazy" in haskey)) out = out bline("lazy", bval(nm, "lazy", "true")) "\n"
        }
        if (!pl && newpl != "") out = out newpl "\n"
        continue
      }
      if (match(BL[i], /^    (url|interval|tolerance|lazy):/)) {
        k = substr(BL[i], 5, RLENGTH - 5)
        if (chg && (nty == "select" || (nty == "fallback" && k == "tolerance"))) continue
        if ((nm SUBSEP k) in bset) { out = out bline(k, bset[nm SUBSEP k]) "\n"; continue }
      }
      if (i == pl) { out = out newpl "\n"; continue }
      out = out BL[i] "\n"
    }
  }
  # Циклы: снимаем группы без исходящих рёбер к живым; оставшиеся - в цикле.
  for (g = 1; g <= ngb; g++) live[g] = 1
  changed = 1
  while (changed) {
    changed = 0
    for (g = 1; g <= ngb; g++) {
      if (!live[g]) continue
      c = split(substr(GBC[g], 2), a, SUBSEP); cnt = 0
      for (i = 1; i <= c; i++) if (live[a[i]]) cnt++
      if (!cnt) { live[g] = 0; changed = 1 }
    }
  }
  for (g = 1; g <= ngb; g++) if (live[g]) {
    path = GBN[g]; seen[g] = 1; x = g
    while (1) {
      c = split(substr(GBC[x], 2), a, SUBSEP); y = 0
      for (i = 1; i <= c; i++) if (live[a[i]]) { y = a[i]; break }
      path = path " -> " GBN[y]
      if (y in seen) break
      seen[y] = 1; x = y
    }
    err("цикл групп: " path)
  }
  nbl = 0; ngb = 0
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
  inside = 0; out = ""; geohits = 0; sect = ""; curg = ""
}
{
  if (nbl && (index($0, "# --- SERVICE_GROUPS:BEGIN ---") || $0 ~ /^[A-Za-z0-9_-]+:/)) { buffering = 0; flush_base() }
  if (index($0, "# --- SERVICE_GROUPS:BEGIN ---")) base_done = 1
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
  if (line ~ /^[A-Za-z0-9_-]+:/) { sect = line; sub(/:.*/, "", sect); curg = "" }
  else if (sect == "proxy-groups" && line ~ /^  - name:/) { curg = line; sub(/^  - name:/, "", curg); curg = unq(curg) }
  if (sect == "proxy-groups" && !base_done) {
    BL[++nbl] = line
    if (line ~ /^  - name:/) { GBS[++ngb] = nbl; GBN[ngb] = curg }
    next
  }
  if (sect == "proxy-groups" && curg != "") {
    if (match(line, /^    (interval|tolerance):/)) {
      bkey = substr(line, 5, RLENGTH - 5)
      if ((curg SUBSEP bkey) in bset) line = "    " bkey ": " bset[curg SUBSEP bkey]
    }
    if ((curg in bfirst) && line ~ /^    proxies: \[/) { r = reorder(line, bfirst[curg]); if (r != "") line = r }
  } else if (sect == "anchors" && ("*" in bfirst) && line ~ /^  select-default: &select-default /) {
    r = reorder(line, bfirst["*"]); if (r != "") line = r
  }
  if (ownscope && sect == "anchors" && line ~ /^  select-default: &select-default /) line = add_own(line)
  if (geoval != "" && match(line, /exclude-filter: &geofilter '[^']*'/)) {
    line = substr(line, 1, RSTART - 1) "exclude-filter: &geofilter '" geoval "'" substr(line, RSTART + RLENGTH)
    geohits++
  }
  out = out line "\n"
}
END {
  if (failed) exit 2
  if (nbl) flush_base()
  if (failed) exit 2
  for (i = 1; i <= 3; i++) {
    if (nbeg[i] != 1 || nend[i] != 1) err("в шаблоне должно быть ровно по одному маркеру " mk[i] ":BEGIN и " mk[i] ":END")
  }
  if (inside) err("в шаблоне не закрыт блок маркеров " mk[inside])
  if (geoval != "" && !geohits) err("в шаблоне нет exclude-filter: &geofilter - некуда подставить фильтр нод")
  printf "%s", out
}
