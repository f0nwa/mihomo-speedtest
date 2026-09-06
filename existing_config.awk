# existing_config.awk — извлекает из старого config.yaml список URL
# подписок и (опционально) готовый блок proxies: для переноса в новую
# установку setup.sh. Не выполняется на роутере как самостоятельный шаг —
# только как часть setup.sh.
#
# Использование:
#   awk -v urls_out=PATH [-v proxies_out=PATH] -f existing_config.awk config.yaml
BEGIN {
  in_pp = 0; prov_indent = -1
  cur_has_url = 0; cur_is_file = 0; cur_url = ""
  in_proxies = 0; proxies_text = ""; proxies_placeholder = 0
}

function flush_provider() {
  if (cur_has_url && !cur_is_file && cur_url != "") {
    print cur_url >> urls_out
  }
  cur_has_url = 0; cur_is_file = 0; cur_url = ""
}

/^proxy-providers:[ \t]*$/ { in_pp = 1; next }
in_pp && /^[^ \t#]/ { flush_provider(); in_pp = 0 }
in_pp && $0 ~ /^[ \t]+[A-Za-z0-9_-]+:[ \t]*$/ {
  match($0, /[^ \t]/); ind = RSTART - 1
  if (prov_indent < 0) prov_indent = ind
  if (ind == prov_indent) { flush_provider(); next }
}
in_pp {
  if (match($0, /url:[ \t]*"?[^"\r\n]*/)) {
    v = $0
    sub(/^[ \t]*url:[ \t]*/, "", v)
    gsub(/^"|"[ \t]*$/, "", v)
    cur_url = v; cur_has_url = 1
  }
  if ($0 ~ /^[ \t]*type:[ \t]*file[ \t]*$/) cur_is_file = 1
}

/^proxies:[ \t]*$/ { in_proxies = 1; next }
in_proxies && /^[^ \t#]/ { in_proxies = 0 }
in_proxies {
  proxies_text = proxies_text $0 "\n"
  if ($0 ~ /CHANGE_ME/ || $0 ~ /example\.com/) proxies_placeholder = 1
}

END {
  flush_provider()
  if (proxies_out != "" && proxies_text != "" && !proxies_placeholder) {
    printf "%s", proxies_text > proxies_out
  }
}
