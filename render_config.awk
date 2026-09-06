# render_config.awk — собирает config.yaml из config.example.yaml и списка
# подписок. Используется setup.sh, не выполняется на роутере напрямую.
#
# Использование:
#   awk -v providers_file=PATH [-v static_file=PATH] -f render_config.awk TEMPLATE
#
# providers_file: строки "url<TAB>ua", по одной на подписку; итоговые имена
#   провайдеров всегда provider-1..N по порядку строк в файле.
# static_file: необязательно — готовое содержимое блока `proxies:` (без
#   маркеров) для подстановки взамен блока шаблона. Не задан/пуст — блок
#   между маркерами STATIC_PROXIES остаётся как в шаблоне.
BEGIN {
  nprov = 0
  if (providers_file != "") {
    while ((getline line < providers_file) > 0) {
      split(line, f, "\t")
      prov_url[nprov] = f[1]
      prov_ua[nprov] = f[2]
      nprov++
    }
    close(providers_file)
  }

  names = ""
  for (i = 0; i < nprov; i++) {
    if (i > 0) names = names ", "
    names = names "provider-" (i + 1)
  }

  have_static = 0
  static_content = ""
  if (static_file != "") {
    while ((getline line < static_file) > 0) {
      static_content = static_content line "\n"
      have_static = 1
    }
    close(static_file)
  }

  in_sub = 0
  in_static = 0
}

/^  # --- SUBSCRIPTIONS:BEGIN ---/ {
  print
  for (i = 0; i < nprov; i++) {
    n = i + 1
    printf "  provider-%d:\n", n
    print "    <<: *http-provider"
    printf "    url: \"%s\"\n", prov_url[i]
    printf "    path: ./proxy-providers/provider-%d.yaml\n", n
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
  if (have_static) {
    printf "%s", static_content
    in_static = 1
  }
  next
}
/^  # --- STATIC_PROXIES:END ---/ { in_static = 0; print; next }
in_static { next }

{ print }
