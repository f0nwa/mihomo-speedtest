# update_plan.awk - разбор manifest.txt и построение плана обновления.
# Вход:
#   MANIFEST   - путь к manifest.txt (обязателен)
#   LOCALSTATE - путь к файлу "путь\tsha256" для файлов, реально присутствующих
#                на диске (необязателен, отсутствующие пути = файл отсутствует)
#   INSTALLED  - путь к ранее установленному манифесту в том же формате
#                FILE|... (необязателен - до первой реализации apply такого
#                файла на роутере ещё нет)
#   SELECTED   - список id компонентов через запятую, выбранных пользователем
#   FORMAT     - "text" (по умолчанию) или "json"
# Ничего не пишет на диск - только печатает план в stdout. Код возврата 1
# при любой ошибке разбора/валидации манифеста (сообщение - в stderr).

function fail(msg) {
  print "ERROR: " msg > "/dev/stderr"
  exit_code = 1
  exit 1
}

function json_escape(s,    r) {
  r = s
  gsub(/\\/, "\\\\", r)
  gsub(/"/, "\\\"", r)
  gsub(/\t/, "\\t", r)
  gsub(/\r/, "\\r", r)
  gsub(/\n/, "\\n", r)
  return r
}

BEGIN {
  FS = "|"
  if (MANIFEST == "") fail("не задан MANIFEST")
  if (FORMAT == "") FORMAT = "text"
  if (FORMAT != "text" && FORMAT != "json") fail("неизвестный FORMAT: " FORMAT)

  n = split(SELECTED, sel_arr, ",")
  for (i = 1; i <= n; i++) {
    s = sel_arr[i]
    gsub(/^ +| +$/, "", s)
    if (s != "") selected[s] = 1
  }

  known_action["restart-web"] = 1
  known_action["migrate-config"] = 1
  known_action["restart-mihomo"] = 1

  known_check["sh"] = 1
  known_check["awk"] = 1
  known_check["py"] = 1
  known_check["none"] = 1

  allowed_prefix[1] = "/opt/etc/mihomo/"
  allowed_prefix[2] = "/opt/etc/init.d/"

  # Служебные пути вне /opt/etc/mihomo/ разрешены только явным перечислением
  # (см. спецификацию: "известные целевые каталоги ... и явно перечисленные
  # служебные пути") - открытый префикс /opt/etc/init.d/ сам по себе не
  # достаточен, разрешён только конкретный, уже используемый проектом путь.
  allowed_full["/opt/etc/init.d/S80speedtest-stats"] = 1

  # --- разбор manifest.txt ---
  while ((getline line < MANIFEST) > 0) {
    if (line == "") continue
    if (line ~ /^FORMAT_VERSION=/) { split(line, a, "="); format_version = a[2]; continue }
    if (line ~ /^RELEASE_VERSION=/) { split(line, a, "="); release_version = a[2]; continue }
    if (line ~ /^MIN_UPDATER_VERSION=/) { split(line, a, "="); min_updater = a[2]; continue }
    if (line ~ /^CONFIG_SCHEMA_VERSION=/) { split(line, a, "="); config_schema = a[2]; continue }

    nf = split(line, f, "|")
    if (f[1] == "COMPONENT") {
      if (nf != 3) fail("COMPONENT: ожидалось 3 поля: " line)
      cid = f[2]
      if (cid in comp_title) fail("повторное объявление компонента: " cid)
      comp_title[cid] = f[3]
      comp_order[++comp_count] = cid
      continue
    }
    if (f[1] == "DEPENDS") {
      if (nf != 3) fail("DEPENDS: ожидалось 3 поля: " line)
      dep_from = f[2]; dep_to = f[3]
      depends_raw[++dep_count] = dep_from SUBSEP dep_to
      continue
    }
    if (f[1] == "FILE") {
      if (nf != 8) fail("FILE: ожидалось 8 полей: " line)
      cid = f[2]; src = f[3]; dest = f[4]; size = f[5]; sha = f[6]; mode = f[7]; check = f[8]
      if (!(cid in comp_title)) fail("FILE ссылается на неизвестный компонент: " cid)

      if (src == "") fail("FILE: пустой исходный путь для " dest)
      if (src ~ /^\//) fail("FILE: исходный путь должен быть относительным: " src)
      if (src ~ /(^|\/)\.\.(\/|$)/) fail("FILE: '..' в исходном пути запрещён: " src)

      if (dest !~ /^\//) fail("FILE: целевой путь должен быть абсолютным: " dest)
      if (dest ~ /(^|\/)\.\.(\/|$)/) fail("FILE: '..' в целевом пути запрещён: " dest)
      if (dest ~ /\/\//) fail("FILE: пустой сегмент пути в назначении: " dest)
      if (dest ~ /(^|\/)\.(\/|$)/) fail("FILE: сегмент '.' в назначении запрещён: " dest)
      if (dest ~ /\/$/) fail("FILE: назначение не может быть каталогом: " dest)

      okpref = 0
      for (p = 1; p <= 2; p++) {
        if (index(dest, allowed_prefix[p]) == 1 && length(dest) > length(allowed_prefix[p])) okpref = 1
      }
      if (!okpref) fail("FILE: запрещённый целевой каталог: " dest)

      if (index(dest, "/opt/etc/init.d/") == 1 && !(dest in allowed_full)) {
        fail("FILE: служебный путь не входит в явный список разрешённых: " dest)
      }
      if (dest == "/opt/etc/mihomo/config.yaml") {
        fail("FILE: config.yaml не может быть файлом релиза: " dest)
      }
      if (index(dest, "/opt/etc/mihomo/.update/") == 1) {
        fail("FILE: запрещённый целевой каталог (служебное состояние обновлятора): " dest)
      }

      if (dest in dest_seen) fail("FILE: дублирующееся назначение: " dest)
      dest_seen[dest] = 1
      if (size !~ /^[0-9]+$/) fail("FILE: неверный размер для " dest)
      if (sha !~ /^[0-9a-f]{64}$/) fail("FILE: неверный SHA-256 для " dest)
      if (mode !~ /^[0-7]{3,4}$/) fail("FILE: неверный режим для " dest)
      if (!(check in known_check)) fail("FILE: неизвестный тип проверки '" check "' для " dest)
      file_count++
      file_comp[file_count] = cid
      file_src[file_count] = src
      file_dest[file_count] = dest
      file_size[file_count] = size
      file_sha[file_count] = sha
      file_mode[file_count] = mode
      file_check[file_count] = check
      continue
    }
    if (f[1] == "ACTION") {
      if (nf != 3) fail("ACTION: ожидалось 3 поля: " line)
      cid = f[2]; act = f[3]
      if (!(cid in comp_title)) fail("ACTION ссылается на неизвестный компонент: " cid)
      if (!(act in known_action)) fail("ACTION: неизвестное действие: " act)
      action_raw[++action_count] = cid SUBSEP act
      continue
    }
    fail("нераспознанная строка манифеста: " line)
  }
  close(MANIFEST)

  if (format_version == "") fail("отсутствует FORMAT_VERSION")
  if (release_version == "") fail("отсутствует RELEASE_VERSION")
  if (min_updater == "") fail("отсутствует MIN_UPDATER_VERSION")
  if (config_schema == "") fail("отсутствует CONFIG_SCHEMA_VERSION")
  if (format_version !~ /^[0-9]+$/) fail("FORMAT_VERSION должен быть целым числом: " format_version)
  if (release_version !~ /^[0-9]+$/) fail("RELEASE_VERSION должен быть целым числом: " release_version)
  if (min_updater !~ /^[0-9]+$/) fail("MIN_UPDATER_VERSION должен быть целым числом: " min_updater)
  if (config_schema !~ /^[0-9]+$/) fail("CONFIG_SCHEMA_VERSION должен быть целым числом: " config_schema)

  for (i = 1; i <= dep_count; i++) {
    split(depends_raw[i], parts, SUBSEP)
    df = parts[1]; dt = parts[2]
    if (!(df in comp_title)) fail("DEPENDS: неизвестный компонент: " df)
    if (!(dt in comp_title)) fail("DEPENDS: неизвестный компонент: " dt)
    dep_list[df] = dep_list[df] (dep_list[df] == "" ? "" : ",") dt
  }

  # --- локальное состояние файлов (если задано) ---
  if (LOCALSTATE != "") {
    while ((getline line < LOCALSTATE) > 0) {
      if (line == "") continue
      split(line, lp, "\t")
      local_sha[lp[1]] = lp[2]
    }
    close(LOCALSTATE)
    have_localstate = 1
  }

  # --- ранее установленный манифест (если задан) ---
  if (INSTALLED != "") {
    while ((getline line < INSTALLED) > 0) {
      if (line == "") continue
      nf = split(line, f, "|")
      if (f[1] == "FILE" && nf == 8) {
        installed_sha[f[4]] = f[6]
        installed_comp[f[4]] = f[2]
      }
    }
    close(INSTALLED)
    have_installed = 1
  }

  # --- разрешение зависимостей выбранных компонентов ---
  for (cid in selected) resolve(cid)

  # --- состояние каждого управляемого файла выбранных (после разрешения) компонентов ---
  for (i = 1; i <= file_count; i++) {
    cid = file_comp[i]
    if (!(cid in resolved)) continue
    dest = file_dest[i]
    st = compute_state(dest, file_sha[i])
    plan_file_count++
    plan_dest[plan_file_count] = dest
    plan_comp[plan_file_count] = cid
    plan_file_state[plan_file_count] = st
  }

  # --- файлы, которыми управлял предыдущий установленный манифест, но
  #     которых больше нет ни в одном компоненте текущего манифеста ---
  if (have_installed) {
    for (dest in installed_sha) {
      if (dest in dest_seen) continue
      plan_file_count++
      plan_dest[plan_file_count] = dest
      plan_comp[plan_file_count] = (dest in installed_comp) ? installed_comp[dest] : ""
      plan_file_state[plan_file_count] = "removed"
    }
  }

  # --- итоговый список действий (без повторов, в порядке первого появления) ---
  for (i = 1; i <= action_count; i++) {
    split(action_raw[i], parts, SUBSEP)
    cid = parts[1]; act = parts[2]
    if (!(cid in resolved)) continue
    if (!(act in action_seen)) {
      action_seen[act] = 1
      plan_action[++plan_action_count] = act
    }
  }

  if (FORMAT == "json") print_json()
  else print_text()

  exit 0
}

function resolve(cid,   list, n, i, part) {
  if (cid in resolving) fail("цикл зависимостей на компоненте: " cid)
  if (cid in resolved) return
  if (!(cid in comp_title)) fail("выбран неизвестный компонент: " cid)
  resolving[cid] = 1
  list = dep_list[cid]
  if (list != "") {
    n = split(list, arr, ",")
    for (i = 1; i <= n; i++) {
      part = arr[i]
      if (!(part in resolved)) {
        if (!(part in selected)) auto_included[part] = 1
        resolve(part)
      }
    }
  }
  delete resolving[cid]
  resolved[cid] = 1
}

function compute_state(dest, release_sha,   cur, base) {
  cur = local_sha[dest]
  if (cur == "") return "missing"
  if (cur == release_sha) return "current"
  if (have_installed) {
    base = installed_sha[dest]
    if (base == "" ) return "new"
    if (base == cur) return "new"
    return "modified"
  }
  return "changed"
}

function state_label(st) {
  if (st == "current") return "актуален"
  if (st == "new") return "доступна новая версия"
  if (st == "missing") return "отсутствует"
  if (st == "modified") return "локально изменён"
  if (st == "changed") return "отличается (нет базового манифеста для точного диагноза)"
  if (st == "removed") return "больше не используется новым релизом (можно удалить)"
  return "неизвестно"
}

function print_text(   i, cid, comp_label) {
  print "Релиз " release_version " (формат манифеста " format_version ", минимальная версия update.sh " min_updater ")"
  print "Версия схемы config.yaml в релизе: " config_schema
  print ""
  print "Выбранные компоненты:"
  for (i = 1; i <= comp_count; i++) {
    cid = comp_order[i]
    if (!(cid in resolved)) continue
    if (cid in auto_included) print "  - " cid " (" comp_title[cid] ") - добавлен как обязательная зависимость"
    else print "  - " cid " (" comp_title[cid] ")"
  }
  print ""
  print "Файлы плана:"
  for (i = 1; i <= plan_file_count; i++) {
    comp_label = (plan_comp[i] == "") ? "?" : plan_comp[i]
    print "  " plan_dest[i] " [" comp_label "]: " state_label(plan_file_state[i])
  }
  print ""
  if (plan_action_count == 0) {
    print "Завершающие действия: не требуются"
  } else {
    printf "Завершающие действия:"
    for (i = 1; i <= plan_action_count; i++) printf " %s", plan_action[i]
    print ""
  }
}

function print_json(   i, cid, first) {
  printf "{\"release_version\":\"%s\",\"format_version\":\"%s\",\"min_updater_version\":\"%s\",\"config_schema_version\":\"%s\",", json_escape(release_version), json_escape(format_version), json_escape(min_updater), json_escape(config_schema)
  printf "\"components\":["
  first = 1
  for (i = 1; i <= comp_count; i++) {
    cid = comp_order[i]
    if (!(cid in resolved)) continue
    if (!first) printf ","
    first = 0
    printf "{\"id\":\"%s\",\"title\":\"%s\",\"auto_included\":%s}", json_escape(cid), json_escape(comp_title[cid]), (cid in auto_included) ? "true" : "false"
  }
  printf "],\"files\":["
  for (i = 1; i <= plan_file_count; i++) {
    if (i > 1) printf ","
    printf "{\"dest\":\"%s\",\"component\":\"%s\",\"state\":\"%s\"}", json_escape(plan_dest[i]), json_escape(plan_comp[i]), plan_file_state[i]
  }
  printf "],\"actions\":["
  for (i = 1; i <= plan_action_count; i++) {
    if (i > 1) printf ","
    printf "\"%s\"", plan_action[i]
  }
  print "]}"
}
