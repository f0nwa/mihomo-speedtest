# render_config.awk — собирает config.yaml из config.example.yaml и списка
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
# static_file: необязательно — готовое содержимое блока `proxies:` (без
#   маркеров) для подстановки взамен блока шаблона. Не задан/пуст — блок
#   между маркерами STATIC_PROXIES остаётся как в шаблоне.
# dns_file: необязательно — готовое содержимое верхнеуровневого блока
#   dns: (включая саму строку "dns:", как отдаёт existing_config.awk
#   -v dns_out=...) для подстановки между маркерами STATIC_DNS. Не
#   задан/пуст — между маркерами ничего не добавляется, и никакого
#   dns: в итоговом config.yaml не будет (шаблон по умолчанию его не
#   содержит).
# mihomo_dir: необязательно — абсолютный каталог самой Mihomo (по
#   умолчанию /opt/etc/mihomo), подставляется в путь fast-провайдера
#   ("path: /opt/etc/mihomo/fast.yaml" вместо "path: ./fast.yaml" в
#   шаблоне) - см. docs/superpowers/specs/
#   2026-09-25-install-dir-separation-design.md.
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
  if (static_file != "") {
    while ((getline line < static_file) > 0) {
      static_content = static_content line "\n"
      have_static = 1
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
  if (have_static) {
    printf "%s", static_content
    in_static = 1
  }
  next
}
/^  # --- STATIC_PROXIES:END ---/ { in_static = 0; print; next }
in_static { next }

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

{ print }
