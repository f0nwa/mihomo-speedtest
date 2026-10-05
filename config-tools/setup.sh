#!/bin/sh
# setup.sh - установка с нуля: копирует config.example.yaml, собирает
# подписки (с необязательным импортом из старого config.yaml) и
# статические proxies, подбирает User-Agent автоматически, применяет
# конфиг и передаёт управление install.sh (speedtest).
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
BIN=${BIN:-/opt/sbin/mihomo}
API_MAIN=${API_MAIN:-127.0.0.1:9090}
SELFDIR=${SELFDIR:-.}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
CONFIG=${CONFIG:-$MIHOMO_DIR/config.yaml}
TEMPLATE=${TEMPLATE:-$SELFDIR/config.example.yaml}
# Разделитель URL<TAB>UA в строках между collect_subscriptions() и
# build_provider_specs() - существующий provider с уже настроенным
# header: {User-Agent: [...]} переносится как есть, без detect_ua.
TAB=$(printf '\t')

. "$SELFDIR/version_check.sh"
# Значения UI по умолчанию - не часть библиотеки: тесты подключают setup.sh
# как библиотеку (SETUP_LIB_ONLY=1) без ui_init и вызывают функции напрямую,
# а под `set -u` ui_ok/ui_warn не должны падать на неустановленных
# переменных. До ui_init (он вызывается только в main) режим - plain.
UI_LOG=${UI_LOG:-/opt/var/log/mihomo-speedtest-install.log}
UI_MODE=${UI_MODE:-plain}
UI_COLS=${UI_COLS:-80}
: "${UI_C_ACC=}" "${UI_C_OK=}" "${UI_C_ERR=}" "${UI_C_WARN=}" "${UI_C_DIM=}" "${UI_C_B=}" "${UI_C_0=}"
UI_G_OK=${UI_G_OK:-[OK]}; UI_G_ERR=${UI_G_ERR:-[!!]}; UI_G_WARN=${UI_G_WARN:-[!]}
UI_G_BAR=${UI_G_BAR:-|}; UI_SLEEP=${UI_SLEEP:-sleep 1}
# ui.sh лежит рядом (как version_check.sh); при подключении ничего не печатает.
. "$SELFDIR/ui.sh"
DETECT_UA_LIB_ONLY=1
. "$SELFDIR/detect_ua.sh"

collect_subscriptions() {
  # Печатает в stdout URL по одному на строку - итоговый список подписок
  # до автоподбора UA. Порядок: импорт из старого CONFIG (за вычетом
  # номеров, убранных пользователем) -> SUB_URLS из окружения -> ручной
  # интерактивный ввод.
  urls_file=$(mktemp "${TMPDIR:-/tmp}/setup_urls.XXXXXX")
  n=0

  if [ -f "$CONFIG" ]; then
    imported=$(mktemp "${TMPDIR:-/tmp}/setup_imported.XXXXXX")
    if awk -v urls_out="$imported" -v proxies_out="" -f "$SELFDIR/existing_config.awk" "$CONFIG" 2>/dev/null && [ -s "$imported" ]; then
      # Список - одним блоком (ui_note читает stdin, пишет в stderr);
      # счётчик i внутри конвейера живёт в подоболочке, ниже он обнуляется.
      {
      echo "Найдены подписки в текущем $CONFIG:"
      i=0
      while IFS= read -r u; do
        i=$((i + 1))
        case "$u" in
          *"$TAB"*)
            uu=${u%%"$TAB"*}
            rest=${u#*"$TAB"}
            case "$rest" in
              *"$TAB"*) ua=${rest%%"$TAB"*}; nm=${rest#*"$TAB"} ;;
              *) ua=""; nm="" ;;
            esac
            if [ -n "$ua" ] && [ -n "$nm" ]; then
              echo "  $i) $uu (свой UA: $ua, имя: $nm)"
            elif [ -n "$ua" ]; then
              echo "  $i) $uu (свой UA: $ua)"
            elif [ -n "$nm" ]; then
              echo "  $i) $uu (имя: $nm)"
            else
              echo "  $i) $uu"
            fi
            ;;
          *) echo "  $i) $u" ;;
        esac
      done < "$imported"
      } | ui_note info
      ui_ask "Введите номера через пробел, чтобы убрать лишние (Enter - оставить все)"
      read -r drop || drop=""
      i=0
      while IFS= read -r u; do
        i=$((i + 1))
        case " $drop " in
          *" $i "*) continue ;;
        esac
        n=$((n + 1))
        echo "$u" >> "$urls_file"
      done < "$imported"
    fi
    rm -f "$imported"
  fi

  if [ -n "${SUB_URLS:-}" ]; then
    for u in $SUB_URLS; do
      n=$((n + 1))
      echo "$u" >> "$urls_file"
    done
  else
    attempt=0
    while :; do
      if [ "$n" -eq 0 ]; then
        ui_ask "Ссылка на подписку #$((n + 1)) (обязательно)"
      else
        ui_ask "Есть ещё одна ссылка на подписку сверх уже указанных ($n шт.)? Если нет - просто нажмите Enter"
      fi
      read -r url || url=""
      if [ -z "$url" ]; then
        if [ "$n" -gt 0 ]; then break; fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
          ui_fail "Нужна хотя бы одна ссылка на подписку"
          rm -f "$urls_file"
          return 1
        fi
        continue
      fi
      n=$((n + 1))
      echo "$url" >> "$urls_file"
    done
  fi

  cat "$urls_file"
  rm -f "$urls_file"
}

pick_ua() {
  # $1 = URL. Печатает две строки: выбранный User-Agent и вид ответа
  # ("full"/"short"). Пустой вывод - ни один UA не подошёл.
  url=$1
  tmp=$(mktemp "${TMPDIR:-/tmp}/setup_ua.XXXXXX")
  found=""
  fallback=""
  while IFS= read -r ua; do
    [ -n "$ua" ] || continue
    curl -sL --compressed -o "$tmp" -w '%{http_code}' -m 10 -A "$ua" "$url" >/dev/null 2>&1 || true
    [ -f "$tmp" ] || : > "$tmp"
    kind=$(classify_body "$tmp")
    case "$kind" in
      "clash YAML, полный"*) found=$ua; break ;;
      "v2ray-подписка"*) found=$ua; break ;;
      "clash YAML, укороченный"*) [ -z "$fallback" ] && fallback=$ua ;;
    esac
  done <<UALIST
$UA_LIST
UALIST
  rm -f "$tmp"
  if [ -n "$found" ]; then
    printf '%s\nfull\n' "$found"
  elif [ -n "$fallback" ]; then
    printf '%s\nshort\n' "$fallback"
  fi
}

build_provider_specs() {
  # $1 = файл со списком строк "url" (новая подписка без известных UA и
  # имени) или "url<TAB>ua<TAB>name" (из collect_subscriptions -
  # ua и/или name уже могут быть известны из старого конфига, любое из
  # них может быть пустым). Печатает "url<TAB>ua<TAB>name" - ua подобран
  # автодетектом или уже был известен, name передан насквозь без
  # изменений (её присвоит assign_provider_names() следующим шагом; сама
  # build_provider_specs имена не проверяет и не трогает). Для подписок
  # без рабочего UA - WARN в stderr, строка отбрасывается целиком.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *"$TAB"*)
        url=${line%%"$TAB"*}
        rest=${line#*"$TAB"}
        case "$rest" in
          *"$TAB"*) ua=${rest%%"$TAB"*}; name=${rest#*"$TAB"} ;;
          *) ua=$rest; name="" ;;
        esac
        ;;
      *)
        url=$line; ua=""; name=""
        ;;
    esac
    if [ -n "$ua" ]; then
      ui_ok "Для $url используется сохранённый UA \"$ua\" (перенесён из старого конфига, заново не проверялся)"
      printf '%s\t%s\t%s\n' "$url" "$ua" "$name"
      continue
    fi
    # pick_ua печатает результат в stdout ($(...)), поэтому в ui_run его
    # не обернуть - даём строку «идёт» заранее: перебор UA может занять время.
    echo "Подбор User-Agent для $url" | ui_note info
    result=$(pick_ua "$url")
    ua=$(printf '%s\n' "$result" | sed -n 1p)
    kind=$(printf '%s\n' "$result" | sed -n 2p)
    if [ -z "$ua" ]; then
      ui_fail "Для $url не подобран рабочий User-Agent - подписка исключена (проверьте вручную: sh detect_ua.sh \"$url\")"
      continue
    fi
    if [ "$kind" = "short" ]; then
      ui_warn "WARN для $url подошёл только укороченный clash YAML - сверьте набор нод после установки"
    else
      ui_ok "Для $url подобран рабочий User-Agent \"$ua\""
    fi
    printf '%s\t%s\t%s\n' "$url" "$ua" "$name"
  done < "$1"
}

domain_label() {
  # $1 = URL. Печатает эвристическое "имя" для провайдера - предпоследнюю
  # точечную метку хоста (vpnshop.example.com -> example, example.com ->
  # example), в нижнем регистре. При хосте из одной метки (localhost и
  # т.п.) - весь хост как есть. Простая эвристика: составные TLD вида
  # co.uk/com.ru не распознаются (осознанное решение, см. дизайн-документ
  # docs/plans/2026-09-07-provider-naming-design.md).
  url=$1
  host=${url#*://}
  host=${host%%/*}
  host=${host%%\?*}
  host=${host%%#*}
  host=${host##*@}
  host=${host%%:*}
  label=$host
  oldifs=$IFS
  IFS=.
  set -- $host
  IFS=$oldifs
  n=$#
  if [ "$n" -ge 2 ]; then
    shift $((n - 2))
    label=$1
  fi
  printf '%s\n' "$label" | tr 'A-Z' 'a-z'
}

assign_provider_names() {
  # $1 = файл строк "url<TAB>ua<TAB>name" (name может быть пуст - новая
  # подписка без переносимого имени). Печатает на stdout те же строки, но
  # с гарантированно непустым и уникальным в рамках этого вызова третьим
  # полем: имя подтверждается/правится пользователем, как и UA в
  # build_provider_specs() выше. Кандидат - перенесённое имя (если оно
  # было) либо domain_label(url) для новой подписки.
  # Строки читаем через отдельный дескриптор (3), а не через stdin цикла
  # - иначе вложенный интерактивный `read -r final` ниже читал бы не
  # ответ пользователя, а следующую строку того же файла.
  names_file=$(mktemp "${TMPDIR:-/tmp}/setup_names.XXXXXX")
  : > "$names_file"
  exec 3< "$1"
  while IFS= read -r line <&3; do
    [ -n "$line" ] || continue
    url=${line%%"$TAB"*}
    rest=${line#*"$TAB"}
    case "$rest" in
      *"$TAB"*) ua=${rest%%"$TAB"*}; name=${rest#*"$TAB"} ;;
      *) ua=""; name="" ;;
    esac
    if [ -n "$name" ]; then
      candidate=$name
    else
      candidate=$(domain_label "$url")
    fi
    final=""
    while :; do
      if grep -qxF "$candidate" "$names_file" 2>/dev/null; then
        ui_warn "Имя \"$candidate\" для $url уже занято другой подпиской в этом запуске"
        ui_ask "Введите другое имя провайдера для $url"
        read -r final || final=""
      else
        ui_ask "Имя провайдера для $url [$candidate]"
        read -r final || final=""
        [ -n "$final" ] || final=$candidate
      fi
      case "$final" in
        '') ui_warn "Имя не может быть пустым"; continue ;;
        *[!A-Za-z0-9_-]*) ui_warn "Имя может содержать только латинские буквы, цифры, \"_\" и \"-\""; continue ;;
      esac
      if grep -qxF "$final" "$names_file" 2>/dev/null; then
        ui_warn "Имя \"$final\" уже занято другой подпиской в этом запуске"
        candidate=$final
        continue
      fi
      break
    done
    echo "$final" >> "$names_file"
    printf '%s\t%s\t%s\n' "$url" "$ua" "$final"
  done
  exec 3<&-
  rm -f "$names_file"
}

atomic_install() {
  src=$1
  dst=$2
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

# Безусловное предупреждение+подтверждение перед любой другой работой -
# до этого места main() ничего не менял на диске и не задавал никаких
# вопросов про подписки. Владелец должен явно увидеть, ЧТО сейчас
# произойдёт с config.yaml, прежде чем соглашаться, а не наткнуться на
# это где-то в середине уже начатого диалога про подписки. Если
# config.yaml уже существует - его сохранит бэкап (см. main() ниже), но
# сам вопрос об этом задаётся здесь заранее, а не постфактум.
# SKIP_CONFIRM=1 - явный обход для неинтерактивных прогонов/тестов (тот,
# кто это выставляет, берёт ответственность на себя) - по аналогии с
# uninstall.sh. SKIP_DNS_GUARD_CHECK=1 отдельно отключает именно проверку
# защиты Xkeen UI (и её абзац ниже), не трогая остальную часть вопроса.
confirm_config_replace() {
  [ "${SKIP_CONFIRM:-0}" = 1 ] && return 0
  ui_note warn <<'EOF'
config.yaml будет создан заново или полностью заменён (если уже существует - старый сохранится бэкапом рядом).
В новый config.yaml войдут провайдеры выбранных подписок и вспомогательные группы автоматического выбора прокси (Авто по пингу, Fallback-Stable).
EOF
  # Существующий dns: и так переносится как есть (existing_config.awk,
  # dns_out) - здесь речь не про сам DNS, а про стороннюю панель Xkeen UI:
  # она хранит хэш ВСЕГО config.yaml на момент включения своей "Защищённой
  # DNS Mihomo", и после перезаписи этот хэш неизбежно разойдётся, даже
  # если блок dns: не тронут ни на байт. Тогда её кнопка "Восстановить"
  # откатывает СВОЙ старый снимок и затирает то, что только что применил
  # setup.sh.
  if [ "${SKIP_DNS_GUARD_CHECK:-0}" != 1 ] && xkeen_ui_dns_protection_active; then
    ui_note warn <<'EOF'
Похоже, на роутере сейчас активна "Защищённая DNS Mihomo" панели Xkeen UI (или её DNS-over-VLESS для Xray - оба используют один и тот же переключатель Keenetic opkg dns-override).
Блок dns: перенесётся как есть, но хэш ВСЕГО файла, который панель Xkeen UI сверяет сама с собой, после этого не совпадёт.
После установки НЕ нажимайте "Восстановить" в панели Xkeen UI - это откатит её собственный старый снимок и затрёт результат этой установки. Если статус защиты в панели собьётся - просто включите её заново тем же способом, каким включали в первый раз.
EOF
  fi
  ui_ask "Продолжить установку? [y/N]"
  # Под "curl ... | sh" стандартный ввод занят телом самого install.sh/
  # setup.sh (см. тот же приём в uninstall.sh:confirm()) - без
  # переоткрытия от терминала read -r ниже сразу получит EOF и вопрос
  # молча откажет в установке, хотя человек сидит за интерактивным
  # терминалом. Редиректим саму команду read на /dev/tty точечно.
  if [ -t 0 ]; then
    read -r confirm_ans || confirm_ans=""
  elif (exec < /dev/tty) 2>/dev/null; then
    read -r confirm_ans < /dev/tty || confirm_ans=""
  else
    read -r confirm_ans || confirm_ans=""
  fi
  case "$confirm_ans" in
    [Yy]*) return 0 ;;
    *) ui_fail "Установка отменена"; return 1 ;;
  esac
}

# Перезапуск ядра и ожидание API - одной функцией под ui_run: вывод xkeen
# уходит в журнал, на экране только спиннер. stdin ui_run закрывает сам.
restart_core() {
  # Вывод xkeen - в /dev/null, а не в журнал ui_run (как в install.sh,
  # restart_core_and_wait): запущенный xkeen демон наследует дескрипторы и
  # иначе вечно писал бы в журнал установки на /opt.
  xkeen -restart >/dev/null 2>&1 </dev/null
  i=0
  while [ "$i" -lt 20 ]; do
    curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
  done
  curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1
}

main() {
  ui_init
  # Из install.sh (UI_CONTINUE=1) рамку уже показали - тогда только строка
  # раздела; отдельный запуск мастера показывает полный баннер.
  ui_banner "MIHOMO-SPEEDTEST" "Настройка нового роутера"

  check_mihomo_process && check_versions || return 1

  confirm_config_replace || return 1

  [ -f "$TEMPLATE" ] || { ui_fail "Шаблон $TEMPLATE не найден"; return 1; }

  ui_step 1 4 "Подписки"

  subs_file=$(mktemp "${TMPDIR:-/tmp}/setup_urls.XXXXXX")
  if ! collect_subscriptions > "$subs_file"; then
    rm -f "$subs_file"
    return 1
  fi

  ui_step 2 4 "User-Agent"
  specs_file=$(mktemp "${TMPDIR:-/tmp}/setup_specs.XXXXXX")
  build_provider_specs "$subs_file" > "$specs_file"
  rm -f "$subs_file"

  if [ ! -s "$specs_file" ]; then
    ui_fail "Ни одна подписка не прошла проверку - устанавливать нечего"
    rm -f "$specs_file"
    return 1
  fi

  ui_step 3 4 "Имена провайдеров"
  named_file=$(mktemp "${TMPDIR:-/tmp}/setup_named.XXXXXX")
  assign_provider_names "$specs_file" > "$named_file"
  rm -f "$specs_file"
  specs_file=$named_file

  ui_step 4 4 "Конфиг"
  static_file=""
  dns_file=""
  listeners_file=""
  if [ -f "$CONFIG" ]; then
    candidate=$(mktemp "${TMPDIR:-/tmp}/setup_static.XXXXXX")
    dns_candidate=$(mktemp "${TMPDIR:-/tmp}/setup_dns.XXXXXX")
    listeners_candidate=$(mktemp "${TMPDIR:-/tmp}/setup_listeners.XXXXXX")
    awk -v urls_out=/dev/null -v proxies_out="$candidate" -v dns_out="$dns_candidate" \
        -v listeners_out="$listeners_candidate" \
        -f "$SELFDIR/existing_config.awk" "$CONFIG" 2>/dev/null || true
    if [ -s "$candidate" ]; then
      count=$(grep -c '^  - name:' "$candidate" 2>/dev/null || echo 0)
      echo "Найден блок proxies ($count нод) в текущем $CONFIG." | ui_note info
      ui_ask "Перенести как есть в новый config.yaml? [Y/n]"
      read -r ans || ans=""
      case "$ans" in
        [Nn]*) ;;
        *) static_file=$candidate ;;
      esac
    fi
    [ "$static_file" = "$candidate" ] || rm -f "$candidate"
    if [ -s "$dns_candidate" ]; then
      ui_ok "Найден блок dns в текущем $CONFIG, переношу как есть в новый config.yaml"
      dns_file=$dns_candidate
    fi
    [ "$dns_file" = "$dns_candidate" ] || rm -f "$dns_candidate"
    # Свои входы (listeners) переносятся как есть; служебный вход
    # mst-speedtest (замер WireGuard/AmneziaWG через основное ядро) даёт шаблон.
    if [ -s "$listeners_candidate" ]; then
      ui_ok "Найдены свои входы (listeners) в текущем $CONFIG, переношу как есть в новый config.yaml"
      listeners_file=$listeners_candidate
    fi
    [ "$listeners_file" = "$listeners_candidate" ] || rm -f "$listeners_candidate"
  fi

  if [ -f "$CONFIG" ]; then
    backup="$CONFIG.$(date '+%Y-%m-%d_%H%M%S').bak"
    cp "$CONFIG" "$backup" || {
      ui_fail "Не удалось сохранить бэкап $backup"
      rm -f "$specs_file"
      [ -z "$static_file" ] || rm -f "$static_file"
      [ -z "$dns_file" ] || rm -f "$dns_file"
      [ -z "$listeners_file" ] || rm -f "$listeners_file"
      return 1
    }
    ui_ok "Старый конфиг сохранён в $backup"
  fi

  rendered=$(mktemp "${TMPDIR:-/tmp}/setup_config.XXXXXX")
  render_rc=0
  awk -v providers_file="$specs_file" -v static_file="$static_file" -v dns_file="$dns_file" \
      -v listeners_file="$listeners_file" -v mihomo_dir="$MIHOMO_DIR" \
      -f "$SELFDIR/render_config.awk" "$TEMPLATE" > "$rendered" || render_rc=$?
  # Очистка прежних групп FAST-WG и сохранение прямых ссылок на WG-победителей.
  if [ "$render_rc" = 0 ]; then
    awk -f "$SELFDIR/fast_wg.awk" "$rendered" > "$rendered.wg" && mv -f "$rendered.wg" "$rendered" || render_rc=$?
    rm -f "$rendered.wg"
  fi
  rm -f "$specs_file"
  [ -z "$static_file" ] || rm -f "$static_file"
  [ -z "$dns_file" ] || rm -f "$dns_file"
  [ -z "$listeners_file" ] || rm -f "$listeners_file"
  if [ "$render_rc" != 0 ]; then
    rm -f "$rendered"
    if [ "$render_rc" = 3 ]; then
      ui_fail "Свой вход в listeners текущего $CONFIG занимает порт 7896 служебного входа mst-speedtest (замер WireGuard/AmneziaWG); смените порт своего входа и повторите, $CONFIG не тронут"
    else
      ui_fail "Не удалось собрать новый config.yaml из шаблона, $CONFIG не тронут"
    fi
    return 1
  fi

  ui_ok "Новый config.yaml собран из шаблона"

  # mihomo -t под ui_run: полный вывод - в UI_LOG, на экране [!!] и хвост.
  if ! ui_run "Проверка конфига (mihomo -t)" "$BIN" -t -d "$MIHOMO_DIR" -f "$rendered"; then
    ui_fail "Новый конфиг не прошёл mihomo -t, $CONFIG не тронут"
    # Строку с путём не оформляем префиксом: по ней разбирают путь (тесты).
    echo "Непринятый конфиг оставлен в $rendered для разбора (удалите вручную, когда закончите)" >&2
    return 1
  fi

  mkdir -p "$DIR/proxy-providers"
  atomic_install "$rendered" "$CONFIG" || {
    ui_fail "Не удалось записать $CONFIG"
    rm -f "$rendered"
    return 1
  }

  if ! ui_run "Перезапуск ядра" restart_core; then
    ui_fail "mihomo не поднялся после xkeen -restart"
    ui_log "mihomo не поднялся после xkeen -restart"
    return 1
  fi

  ui_ok "Конфиг применён, запускаю install.sh"
  # install.sh продолжит оформление без повторной рамки (UI_CONTINUE) и
  # допишет в тот же журнал; env переживает exec.
  export UI_CONTINUE=1 UI_LOG
  MST_CONFIG_FROM_TEMPLATE=1 exec sh "$SELFDIR/install.sh"
}

if [ "${SETUP_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
