# existing_config.awk — извлекает из старого config.yaml список URL
# подписок (вместе с уже настроенным header: User-Agent:, если он был, и
# именем провайдера), (опционально) готовый блок proxies: и (опционально)
# верхнеуровневый блок dns: для переноса в новую установку setup.sh. Не
# выполняется на роутере как самостоятельный шаг — только как часть
# setup.sh.
#
# Строки в urls_out - всегда "URL<TAB>UA<TAB>NAME": поле UA пустое, если
# у провайдера не было своего header: {User-Agent: [...]} (setup.sh
# переносит уже известный UA как есть, не гоняя detect_ua заново); поле
# NAME - ключ провайдера в старом proxy-providers: (setup.sh по
# умолчанию предлагает сохранить это имя при переносе подписки).
#
# Использование:
#   awk -v urls_out=PATH [-v proxies_out=PATH] [-v dns_out=PATH] -f existing_config.awk config.yaml
#
# dns_out: если задан и в исходном config.yaml есть верхнеуровневый блок
# dns: (свои настройки DNS), в этот файл записывается его содержимое
# целиком (включая саму строку "dns:") как есть, без разбора вложенных
# ключей — setup.sh просто переносит его в новый config.yaml, если он
# найден.
BEGIN {
  in_pp = 0; prov_indent = -1; attr_indent = -1
  cur_has_url = 0; cur_is_file = 0; cur_url = ""; cur_ua = ""; cur_name = ""
  in_header = 0; header_indent = -1; ua_key_indent = -1
  in_proxies = 0; proxies_text = ""; proxies_placeholder = 0
  in_dns = 0; dns_text = ""
}

function flush_provider() {
  if (cur_has_url && !cur_is_file && cur_url != "") {
    print cur_url "\t" cur_ua "\t" cur_name >> urls_out
  }
  cur_has_url = 0; cur_is_file = 0; cur_url = ""; attr_indent = -1
  cur_ua = ""; cur_name = ""; in_header = 0; header_indent = -1; ua_key_indent = -1
}

/^proxy-providers:[ \t]*$/ { in_proxies = 0; in_pp = 1; next }
in_pp && /^[^ \t#]/ { flush_provider(); in_pp = 0 }
in_pp && $0 ~ /^[ \t]+[A-Za-z0-9_-]+:[ \t]*$/ {
  match($0, /[^ \t]/); ind = RSTART - 1
  if (prov_indent < 0) prov_indent = ind
  if (ind == prov_indent) {
    flush_provider()
    name = $0
    sub(/^[ \t]+/, "", name)
    sub(/:.*/, "", name)
    cur_name = name
    next
  }
}
in_pp {
  # attr_indent фиксирует отступ СОБСТВЕННЫХ ключей провайдера (url, path,
  # type, header, health-check) по первой встреченной такой строке - все,
  # что глубже (например url: внутри вложенного health-check:), это уже
  # не атрибут провайдера, а поле другого блока, и не должно
  # перезаписывать cur_url.
  match($0, /[^ \t]/); ind = RSTART - 1
  if (ind > prov_indent && attr_indent < 0) attr_indent = ind
  if (ind == attr_indent && match($0, /url:[ \t]*"?[^"\r\n]*/)) {
    v = $0
    sub(/^[ \t]*url:[ \t]*/, "", v)
    gsub(/^"|"[ \t]*$/, "", v)
    cur_url = v; cur_has_url = 1
  }
  if (ind == attr_indent && $0 ~ /^[ \t]*type:[ \t]*file[ \t]*$/) cur_is_file = 1

  # header: {User-Agent: [...]} - переносим уже настроенный UA как есть,
  # не запуская для этой подписки detect_ua заново (см. AGENTS.md/TODO).
  if (ind == attr_indent && $0 ~ /^[ \t]*header:[ \t]*$/) {
    in_header = 1; header_indent = ind
  } else if (in_header && ind <= header_indent) {
    in_header = 0
  } else if (in_header && ua_key_indent < 0 && $0 ~ /^[ \t]*User-Agent:[ \t]*$/) {
    ua_key_indent = ind
  } else if (in_header && ua_key_indent >= 0 && ind > ua_key_indent && cur_ua == "" && match($0, /^[ \t]*-[ \t]*"?[^"\r\n]*/)) {
    v = $0
    sub(/^[ \t]*-[ \t]*/, "", v)
    gsub(/^"|"[ \t]*$/, "", v)
    cur_ua = v
  }
}

/^proxies:[ \t]*$/ { flush_provider(); in_pp = 0; in_dns = 0; in_proxies = 1; next }
in_proxies && /^[^ \t#]/ { in_proxies = 0 }
in_proxies {
  proxies_text = proxies_text $0 "\n"
  if ($0 ~ /CHANGE_ME/ || $0 ~ /example\.com/) proxies_placeholder = 1
}

/^dns:[ \t]*$/ { flush_provider(); in_pp = 0; in_proxies = 0; in_dns = 1; dns_text = $0 "\n"; next }
in_dns && /^[^ \t#]/ { in_dns = 0 }
in_dns { dns_text = dns_text $0 "\n" }

END {
  flush_provider()
  if (proxies_out != "" && proxies_text != "" && !proxies_placeholder) {
    printf "%s", proxies_text > proxies_out
  }
  if (dns_out != "" && dns_text != "") {
    printf "%s", dns_text > dns_out
  }
}
