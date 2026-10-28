# render_config.awk - собирает config.yaml из config.example.yaml и списка
# подписок. Используется setup.sh, не выполняется на роутере напрямую.
#
# Использование:
#   awk -v providers_file=PATH [-v static_file=PATH] [-v dns_file=PATH] \
#       -f render_config.awk TEMPLATE
#
# providers_file: строки "url<TAB>ua<TAB>name", по одной на подписку; name -
#   итоговое имя провайдера (ключ в proxy-providers:, часть пути к файлу
#   кэша и элемент группы sub-names). Подбирается заранее в setup.sh
#   (assign_provider_names): либо перенесённое из старого config.yaml,
#   либо предложенное по домену подписки - в обоих случаях уже
#   подтверждённое или переписанное пользователем и уникальное в
#   пределах запуска.
# static_file: необязательно - готовое содержимое блока `proxies:` (без
#   маркеров) для подстановки взамен блока шаблона. Не задан/пуст - блок
#   между маркерами STATIC_PROXIES пустой: примерные ноды шаблона (CHANGE_ME)
#   в конфиг не попадают. Их имена в списках `proxies: [...]` групп заменяются
#   именами своих нод (или убираются, если своих нет) - иначе остались бы
#   висячие ссылки.
# dns_file: необязательно - готовое содержимое верхнеуровневого блока
#   dns: (включая саму строку "dns:", как отдаёт existing_config.awk
#   -v dns_out=...) для подстановки между маркерами STATIC_DNS. Не
#   задан/пуст - между маркерами ничего не добавляется, и никакого
#   dns: в итоговом config.yaml не будет (шаблон по умолчанию его не
#   содержит).
# listeners_file: необязательно - свои входы пользователя (записи
#   "  - ..." без маркеров, как отдаёт existing_config.awk -v listeners_out=)
#   для подстановки между маркерами STATIC_LISTENERS. Служебный вход
#   mst-speedtest (замер WireGuard/AmneziaWG через основное ядро) всегда из
#   шаблона; свой вход на его порту 7896 - отказ с кодом 3.
# mihomo_dir: необязательно - абсолютный каталог самой Mihomo (по
#   умолчанию /opt/etc/mihomo), подставляется в путь fast-провайдера
#   ("path: /opt/etc/mihomo/fast.yaml" вместо "path: ./fast.yaml" в
#   шаблоне) - см. docs/superpowers/specs/
#   2026-09-25-install-dir-separation-design.md.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
# Разделитель списка: "" перед первым элементом, ", " перед остальными (не
# "x (n++ ? ...)": busybox awk читает "имя (" как вызов функции).
function sep_next(n) { return (n ? ", " : "") }
# Однострочный список "proxies: [a, 'b']": имена примерных нод шаблона
# (template_names) заменяются списком своих нод static_list - один раз, на
# месте первого такого имени; остальные элементы остаются. Строка без имён
# примерных нод и строка, которую не удалось разобрать, возвращаются как есть.
function remap_refs(s,  hit, name, start, end, j, ch, quote, escape, token, count, result, inserted) {
  if (s !~ /proxies:[ ]*\[/) return s
  hit = 0
  for (name in template_names) if (index(s, name)) hit = 1
  if (!hit) return s
  start = index(s, "["); end = 0; quote = ""; escape = 0; token = ""; count = 0
  for (j = start + 1; j <= length(s); j++) {
    ch = substr(s, j, 1)
    if (quote != "") {
      token = token ch
      if (escape) escape = 0
      else if (quote == "\"" && ch == "\\") escape = 1
      else if (ch == quote) {
        if (quote == "\047" && substr(s, j + 1, 1) == "\047") { token = token "\047"; j++ }
        else quote = ""
      }
    } else if (ch == "\047" || ch == "\"") { quote = ch; token = token ch }
    else if (ch == "," || ch == "]") {
      token = trim(token)
      if (token in template_names) {
        if (!inserted) { if (static_list != "") result = result sep_next(count++) static_list; inserted = 1 }
      } else if (token != "") result = result sep_next(count++) token
      token = ""
      if (ch == "]") { end = j; break }
    } else token = token ch
  }
  if (!end || quote != "") return s
  return substr(s, 1, start) result substr(s, end)
}
BEGIN {
  nprov = 0
  if (providers_file != "") {
    while ((getline line < providers_file) > 0) {
      split(line, f, "\t")
      prov_url[nprov] = f[1]
      prov_ua[nprov] = f[2]
      prov_name[nprov] = f[3]
      nprov++
    }
    close(providers_file)
  }

  names = ""
  for (i = 0; i < nprov; i++) {
    if (i > 0) names = names ", "
    names = names prov_name[i]
  }

  have_static = 0
  static_content = ""
  static_list = ""
  nstatic = 0
  if (static_file != "") {
    while ((getline line < static_file) > 0) {
      static_content = static_content line "\n"
      have_static = 1
      if (line ~ /^  - name:/) {
        v = line; sub(/^  - name:[ \t]*/, "", v); v = trim(v)
        static_list = static_list sep_next(nstatic++) v
      }
    }
    close(static_file)
  }

  have_dns = 0
  dns_content = ""
  if (dns_file != "") {
    while ((getline line < dns_file) > 0) {
      dns_content = dns_content line "\n"
      have_dns = 1
    }
    close(dns_file)
  }

  have_listeners = 0
  listeners_content = ""
  if (listeners_file != "") {
    while ((getline line < listeners_file) > 0) {
      if (line ~ /^(  - |    )port:[ \t]*["\047]?7896["\047]?[ \t]*$/) {
        print "render_config.awk: Свой вход в listeners занимает порт 7896 служебного входа mst-speedtest" > "/dev/stderr"
        exit 3
      }
      listeners_content = listeners_content line "\n"
      have_listeners = 1
    }
    close(listeners_file)
  }

  in_sub = 0
  in_static = 0
  in_dns_static = 0
  mihomo_dir_out = (mihomo_dir != "" ? mihomo_dir : "/opt/etc/mihomo")
}

/^    path: \.\/fast\.yaml$/ {
  printf "    path: %s/fast.yaml\n", mihomo_dir_out
  next
}

/^  # --- SUBSCRIPTIONS:BEGIN ---/ {
  print
  for (i = 0; i < nprov; i++) {
    printf "  %s:\n", prov_name[i]
    print "    <<: *http-provider"
    printf "    url: \"%s\"\n", prov_url[i]
    printf "    path: ./proxy-providers/%s.yaml\n", prov_name[i]
    print "    header:"
    print "      User-Agent:"
    printf "        - \"%s\"\n", prov_ua[i]
    print "    health-check: *gstatic-health-check"
  }
  in_sub = 1
  next
}
/^  # --- SUBSCRIPTIONS:END ---/ { in_sub = 0; print; next }
in_sub { next }

/^  sub-names: &sub-names / {
  printf "  sub-names: &sub-names [%s]\n", names
  next
}

/^  # --- STATIC_PROXIES:BEGIN ---/ {
  print
  if (have_static) printf "%s", static_content
  in_static = 1
  next
}
/^  # --- STATIC_PROXIES:END ---/ { in_static = 0; print; next }
in_static {
  # Примерные ноды шаблона в результат не идут; их имена нужны, чтобы
  # заменить ссылки на них в группах ниже.
  if ($0 ~ /^  - name:/) { v = $0; sub(/^  - name:[ \t]*/, "", v); template_names[trim(v)] = 1 }
  next
}

/^  # --- STATIC_LISTENERS:BEGIN ---/ {
  print
  if (have_listeners) {
    printf "%s", listeners_content
    in_listeners_static = 1
  }
  next
}
/^  # --- STATIC_LISTENERS:END ---/ { in_listeners_static = 0; print; next }
in_listeners_static { next }

/^# --- STATIC_DNS:BEGIN ---/ {
  print
  if (have_dns) {
    printf "%s", dns_content
    in_dns_static = 1
  }
  next
}
/^# --- STATIC_DNS:END ---/ { in_dns_static = 0; print; next }
in_dns_static { next }

{ print remap_refs($0) }
