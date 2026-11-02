#!/bin/sh
# Подбор рабочего User-Agent для подписки в proxy-providers.
#
# Некоторые панели подписок отдают разный формат ответа в зависимости от
# User-Agent запроса: JSON для v2rayNG/xray, полный clash YAML для
# clash.meta/mihomo/clash-verge, укороченный YAML для старых ClashX/CFW,
# base64-список нод для Shadowrocket/Quantumult X/Surge и т.п. mihomo как
# proxy-providers понимает только clash YAML, поэтому перед добавлением
# новой подписки в config.yaml (по образцу config.example.yaml) стоит
# проверить, под каким User-Agent сервер отдаёт нужный формат.
#
# Инструмент не устанавливается на роутер и не входит в состав install.sh -
# это разовая помощь при сборке конфига на рабочей машине, где есть curl.
#
# Использование:
#   sh detect_ua.sh <URL подписки> [доп. User-Agent ...]
#
# Пример:
#   sh detect_ua.sh "https://connect.wpn.me/XXXXXXXXXXXXXXXX"
#
# DETECT_UA_HWID=1 - запросы с данными устройства роутера (x-hwid и т.п.,
# см. sub_device_load ниже): для панелей с лимитом устройств, которые без
# HWID отдают заглушку.
#
# Для юнит-тестов classify_body() без обращения к сети:
#   DETECT_UA_LIB_ONLY=1 . ./detect_ua.sh

set -eu

# Список часто встречающихся клиентских User-Agent, по которым панели
# подписок различают формат ответа. При необходимости дополните список
# аргументами командной строки - они проверяются вместе со стандартными.
# Порядок - приоритет: первыми идут распространённые клиенты (Happ, затем
# FlClashX на ядре mihomo), чтобы в карточке устройства панели роутер
# выглядел обычным клиентом. Happ часто получает xray JSON или
# зашифрованный happ://crypt - тогда перебор идёт дальше.
UA_LIST='
Happ/4.11.0
FlClashX/0.3.2
v2rayNG/1.8.0
v2rayNG/1.10.10
ClashforWindows/0.20.39
clash-verge/v2.0.5
clash.meta
clash
mihomo/1.18.0
ClashX/1.95.1
ClashX Pro/1.95.1
Shadowrocket/1897
Quantumult%20X/1.0.30
Surge/1651
Stash/2.5.4
V2rayU/3.6
sing-box
FlClash/0.8.0
Netch/1.4.0.0
'

# --- Устройство для панелей подписок с лимитом устройств (HWID) ---
# Панели вроде Remnawave при включённом лимите устройств отдают подписку
# только клиенту, приславшему заголовок x-hwid: без него - 404 или
# подписка-заглушка с нодами-подсказками и x-hwid-not-supported: true в
# ответе. Роутер для панели - одно устройство: HWID генерируется один раз
# (случайный, свой у каждого роутера), когда он впервые понадобился, и
# хранится в SUB_DEVICE_FILE; ОС/версия/модель - как у обычного телефона.
# Заголовки получают только подписки, которым они нужны (признак - x-hwid
# в header: провайдера), остальные панели их не видят. HWID проверяется
# как в Remnawave (^[A-Za-z0-9=-]{10,64}$), прочие значения - без кавычек,
# обратной косой черты и управляющих символов, до 64 символов.
SUB_DEVICE_FILE=${SUB_DEVICE_FILE:-${DIR:-/opt/etc/mihomo-speedtest}/sub-device.env}
SUB_DEVICE_OS_DEFAULT=Android
SUB_OS_VER_DEFAULT=15
SUB_DEVICE_MODEL_DEFAULT=SM-A556B

sub_device_hwid_ok() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9=-]{10,64}$'
}

sub_device_text_ok() {
  [ -n "$1" ] && [ "${#1}" -le 64 ] || return 1
  ! printf '%s' "$1" | grep -q '["\\[:cntrl:]]'
}

sub_device_read() {
  sed -n "s/^$1=//p" "$SUB_DEVICE_FILE" 2>/dev/null | tail -n 1
}

# 16 случайных символов [A-Za-z0-9]; запасной источник - UUID ядра.
sub_device_new_hwid() {
  sdn=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16) || sdn=""
  if ! sub_device_hwid_ok "$sdn"; then
    sdn=$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null | head -c 16) || sdn=""
  fi
  sub_device_hwid_ok "$sdn" || return 1
  printf '%s\n' "$sdn"
}

# Записывает текущие SUB_* в SUB_DEVICE_FILE: временный файл рядом и mv.
sub_device_save() {
  sds_dir=$(dirname "$SUB_DEVICE_FILE")
  mkdir -p "$sds_dir" 2>/dev/null || true
  sds_tmp=$sds_dir/.sub-device.env.$$
  {
    {
      echo "# Устройство роутера для панелей подписок с лимитом устройств (HWID)."
      echo "# Не меняйте SUB_HWID: панель увидит новое устройство и займёт ещё один слот."
      printf 'SUB_HWID=%s\n' "$SUB_HWID"
      printf 'SUB_DEVICE_OS=%s\n' "$SUB_DEVICE_OS"
      printf 'SUB_OS_VER=%s\n' "$SUB_OS_VER"
      printf 'SUB_DEVICE_MODEL=%s\n' "$SUB_DEVICE_MODEL"
    } > "$sds_tmp" && mv -f "$sds_tmp" "$SUB_DEVICE_FILE"
  } 2>/dev/null || { rm -f "$sds_tmp"; return 1; }
}

# Читает SUB_HWID, SUB_DEVICE_OS, SUB_OS_VER, SUB_DEVICE_MODEL из
# SUB_DEVICE_FILE без записи: негодные значения - по умолчанию, негодный
# или отсутствующий HWID - пустой.
sub_device_peek() {
  SUB_HWID=$(sub_device_read SUB_HWID)
  SUB_DEVICE_OS=$(sub_device_read SUB_DEVICE_OS)
  SUB_OS_VER=$(sub_device_read SUB_OS_VER)
  SUB_DEVICE_MODEL=$(sub_device_read SUB_DEVICE_MODEL)
  sub_device_hwid_ok "$SUB_HWID" || SUB_HWID=""
  sub_device_text_ok "$SUB_DEVICE_OS" || SUB_DEVICE_OS=$SUB_DEVICE_OS_DEFAULT
  sub_device_text_ok "$SUB_OS_VER" || SUB_OS_VER=$SUB_OS_VER_DEFAULT
  sub_device_text_ok "$SUB_DEVICE_MODEL" || SUB_DEVICE_MODEL=$SUB_DEVICE_MODEL_DEFAULT
  return 0
}

# Загружает SUB_HWID, SUB_DEVICE_OS, SUB_OS_VER, SUB_DEVICE_MODEL. Нет
# файла или HWID в нём негодный - генерирует новый и сохраняет файл.
# Код 1 и текст в SUB_DEVICE_ERR, если сохранить не удалось.
sub_device_load() {
  SUB_DEVICE_ERR=""
  sub_device_peek
  [ -z "$SUB_HWID" ] || return 0
  SUB_HWID=$(sub_device_new_hwid) || SUB_HWID=""
  if [ -z "$SUB_HWID" ]; then
    SUB_DEVICE_ERR="не удалось сгенерировать HWID устройства"
    return 1
  fi
  if ! sub_device_save; then
    SUB_DEVICE_ERR="не удалось сохранить $SUB_DEVICE_FILE"
    SUB_HWID=""
    return 1
  fi
}

# Имена подписок config.yaml ($1), которым уходит HWID (x-hwid в header:).
sub_device_subs() {
  awk '
    /^[A-Za-z0-9_-]+:/ { pp = ($0 ~ /^proxy-providers:/); next }
    pp && /^  [A-Za-z0-9_-]+:[ \t]*$/ { n = $0; sub(/^  /, "", n); sub(/:.*/, "", n); next }
    pp && /^[ ]+x-hwid:/ && n != "" && !(n in seen) { seen[n] = 1; print n }
  ' "$1"
}

# config.yaml $1 -> $2 с текущими SUB_* в x-hwid, x-device-os, x-ver-os и
# x-device-model подписок (значение - строка "- ..." под ключом, как пишут
# render_config.awk и migrate_config.awk). Остальное - без изменений.
sub_device_rewrite() {
  awk -v h="$SUB_HWID" -v o="$SUB_DEVICE_OS" -v v="$SUB_OS_VER" -v m="$SUB_DEVICE_MODEL" '
    /^[A-Za-z0-9_-]+:/ { pp = ($0 ~ /^proxy-providers:/); key = ""; print; next }
    pp && /^[ ]+x-(hwid|device-os|ver-os|device-model):[ \t]*$/ {
      key = $0; sub(/^[ ]+x-/, "", key); sub(/:.*/, "", key); print; next
    }
    pp && key != "" && /^[ ]+- / {
      ind = $0; sub(/-.*/, "", ind)
      if (key == "hwid") val = h
      else if (key == "device-os") val = o
      else if (key == "ver-os") val = v
      else val = m
      print ind "- \"" val "\""; key = ""; next
    }
    { key = ""; print }
  ' "$1" > "$2"
}

# Вид ответа с учётом заголовков панели: заглушка без HWID и исчерпанный
# лимит устройств - раньше тела (заглушка - валидный clash YAML).
# Аргументы: файл заголовков ответа (может отсутствовать), файл тела.
probe_kind() {
  if [ -f "$1" ] && grep -qi '^x-hwid-not-supported:[[:space:]]*true' "$1"; then
    echo "заглушка: панель требует HWID устройства (НЕ подходит без него)"
    return
  fi
  if [ -f "$1" ] && grep -qi '^x-hwid-max-devices-reached:[[:space:]]*true' "$1"; then
    echo "лимит устройств подписки исчерпан (освободите слот в панели провайдера)"
    return
  fi
  classify_body "$2"
}

# Классифицирует тело ответа подписки по характерным маркерам.
# Аргумент: путь к файлу с телом ответа. Печатает одну строку в stdout.
classify_body() {
  file=$1
  [ -s "$file" ] || { echo "пусто"; return; }

  if grep -q '^happ://' "$file" 2>/dev/null; then
    echo "зашифровано для Happ, happ://crypt (НЕ подходит для mihomo proxy-providers)"
    return
  fi

  head_bytes=$(head -c 2 "$file" 2>/dev/null || true)
  case "$head_bytes" in
    '[{'|'{"')
      echo "v2ray/xray JSON (НЕ подходит для mihomo proxy-providers)"
      return
      ;;
  esac

  if grep -q 'proxy-groups:' "$file" 2>/dev/null && grep -q 'mixed-port:' "$file" 2>/dev/null; then
    echo "clash YAML, полный (подходит для mihomo proxy-providers)"
    return
  fi

  if grep -q 'proxies:' "$file" 2>/dev/null; then
    echo "clash YAML, укороченный (частично подходит, сверьте набор нод)"
    return
  fi

  # Похоже на base64: во всём файле нет символов вне base64-алфавита.
  # mihomo/Clash.Meta понимает такой контент как v2ray-подписку (список
  # ссылок vless/vmess/trojan/ss и т.п. одной base64-строкой) напрямую в
  # proxy-providers type: http, без конвертации в clash YAML - см.
  # https://wiki.metacubex.one/en/config/proxy-providers/content/
  if ! grep -q '[^A-Za-z0-9+/=_[:space:]-]' "$file" 2>/dev/null; then
    echo "v2ray-подписка, base64-список ссылок (подходит для mihomo proxy-providers напрямую)"
    return
  fi

  echo "неизвестный формат, смотрите тело ответа глазами"
}

# Делает один запрос с заданным User-Agent. Аргументы: User-Agent, URL,
# путь к файлу для тела ответа. Печатает в stdout одну строку
# "HTTP-код<TAB>размер<TAB>вид ответа" (вид - из classify_body). Общая часть
# CLI (try_one) и веб-интерфейса конструктора (stats_constructor.sh).
# Только http(s): редирект на file:// и прочие схемы curl не пойдёт.
probe_ua() {
  pu_ua=$1
  pu_target=$2
  pu_out=$3
  pu_hdr=$pu_out.hdr
  rm -f "$pu_hdr"
  # PROBE_HWID=1 - с данными устройства (SUB_*, см. sub_device_load).
  if [ "${PROBE_HWID:-0}" = 1 ]; then
    pu_code=$(curl -sL --compressed --proto '=http,https' --proto-redir '=http,https' \
      -D "$pu_hdr" -o "$pu_out" -w '%{http_code}' -m 10 -A "$pu_ua" \
      -H "x-hwid: $SUB_HWID" -H "x-device-os: $SUB_DEVICE_OS" -H "x-ver-os: $SUB_OS_VER" \
      -H "x-device-model: $SUB_DEVICE_MODEL" "$pu_target" 2>/dev/null) || pu_code=000
  else
    pu_code=$(curl -sL --compressed --proto '=http,https' --proto-redir '=http,https' \
      -D "$pu_hdr" -o "$pu_out" -w '%{http_code}' -m 10 -A "$pu_ua" "$pu_target" 2>/dev/null) || pu_code=000
  fi
  # При полном сбое соединения curl иногда не создаёт файл -o вовсе -
  # подстрахуемся, чтобы classify_body()/wc не спотыкались об его отсутствие.
  [ -f "$pu_out" ] || : > "$pu_out"
  pu_size=$(wc -c < "$pu_out" 2>/dev/null | tr -d ' ')
  pu_kind=$(probe_kind "$pu_hdr" "$pu_out")
  rm -f "$pu_hdr"
  printf '%s\t%s\t%s\n' "$pu_code" "${pu_size:-0}" "$pu_kind"
}

# Перебор UA_LIST (порядок - приоритет), общий для setup.sh и конструктора
# (stats_constructor.sh). Полный clash YAML или base64-список - сразу
# выбор; укороченный YAML - запасной вариант. Ответ-заглушка панели с
# лимитом устройств - повтор того же UA с данными устройства, и дальше
# все запросы идут с ними. Первый ответ без соединения (код 000) - сеть
# или хост недоступны, остальные запросы не нужны.
# Аргументы: URL, файл для тела ответа, (необязательно) файл, куда
# дописываются строки "ua<TAB>http<TAB>bytes<TAB>kind<TAB>hwid" по каждому
# запросу. Результат - в переменных: UA_PICK_UA (пусто - не подобран),
# UA_PICK_QUALITY (full|short), UA_PICK_KIND, UA_PICK_HWID (1 - подписке
# нужен HWID), UA_PICK_DEAD (1 - нет соединения), UA_PICK_ERR (ошибка
# загрузки данных устройства).
ua_pick() {
  up_url=$1 up_tmp=$2 up_rows=${3:-}
  UA_PICK_UA="" UA_PICK_QUALITY="" UA_PICK_KIND="" UA_PICK_HWID=0 UA_PICK_DEAD=0 UA_PICK_ERR=""
  up_fb="" up_fb_kind="" up_n=0 up_tab=$(printf '\t')
  while IFS= read -r up_ua; do
    [ -n "$up_ua" ] || continue
    up_try=1
    while [ "$up_try" = 1 ]; do
      up_try=0
      up_res=$(PROBE_HWID=$UA_PICK_HWID probe_ua "$up_ua" "$up_url" "$up_tmp")
      up_code=${up_res%%"$up_tab"*}; up_res=${up_res#*"$up_tab"}
      up_size=${up_res%%"$up_tab"*}; up_kind=${up_res#*"$up_tab"}
      up_n=$((up_n + 1))
      [ -z "$up_rows" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$up_ua" "$up_code" "$up_size" "$up_kind" "$UA_PICK_HWID" >> "$up_rows"
      if [ "$up_n" = 1 ] && [ "$up_code" = 000 ]; then UA_PICK_DEAD=1; return 0; fi
      case $up_kind in
        "заглушка:"*)
          if [ "$UA_PICK_HWID" = 0 ]; then
            if sub_device_load; then UA_PICK_HWID=1; up_try=1; else UA_PICK_ERR=$SUB_DEVICE_ERR; fi
          fi ;;
        "clash YAML, полный"*|"v2ray-подписка"*)
          UA_PICK_UA=$up_ua; UA_PICK_QUALITY=full; UA_PICK_KIND=$up_kind
          return 0 ;;
        "clash YAML, укороченный"*)
          [ -n "$up_fb" ] || { up_fb=$up_ua; up_fb_kind=$up_kind; } ;;
      esac
    done
  done <<UALIST
$UA_LIST
UALIST
  if [ -n "$up_fb" ]; then UA_PICK_UA=$up_fb; UA_PICK_QUALITY=short; UA_PICK_KIND=$up_fb_kind; fi
  return 0
}

# Делает один запрос с заданным User-Agent и печатает строку результата.
# Аргументы: User-Agent, URL, путь к файлу для тела ответа.
# Не полагается на общие $URL/$TMP - так функцию можно тестировать
# отдельно, подменяя curl через PATH (см. tests/test_detect_ua.sh).
try_one() {
  ua=$1
  res=$(probe_ua "$ua" "$2" "$3")
  code=${res%%"$(printf '\t')"*}
  res=${res#*"$(printf '\t')"}
  size=${res%%"$(printf '\t')"*}
  kind=${res#*"$(printf '\t')"}
  printf 'UA=[%s] -> HTTP %s, bytes=%s, %s\n' "$ua" "$code" "$size" "$kind"
}

if [ "${DETECT_UA_LIB_ONLY:-0}" != 1 ]; then
  URL=${1:-}
  if [ -z "$URL" ]; then
    echo "Использование: sh detect_ua.sh <URL подписки> [доп. User-Agent ...]" >&2
    exit 1
  fi
  shift

  TMP=$(mktemp "${TMPDIR:-/tmp}/detect_ua.XXXXXX")
  trap 'rm -f "$TMP" "$TMP.hdr"' EXIT INT TERM

  if [ "${DETECT_UA_HWID:-0}" = 1 ]; then
    sub_device_load || { echo "Ошибка: $SUB_DEVICE_ERR" >&2; exit 1; }
    PROBE_HWID=1
    echo "Запросы с HWID устройства $SUB_HWID ($SUB_DEVICE_OS $SUB_OS_VER, $SUB_DEVICE_MODEL)"
  fi

  echo "$UA_LIST" | while IFS= read -r ua; do
    [ -n "$ua" ] || continue
    try_one "$ua" "$URL" "$TMP"
  done

  for ua in "$@"; do
    try_one "$ua" "$URL" "$TMP"
  done
fi
