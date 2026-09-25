#!/bin/sh
# setup.sh — установка с нуля: копирует config.example.yaml, собирает
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
DETECT_UA_LIB_ONLY=1
. "$SELFDIR/detect_ua.sh"

collect_subscriptions() {
  # Печатает в stdout URL по одному на строку — итоговый список подписок
  # до автоподбора UA. Порядок: импорт из старого CONFIG (за вычетом
  # номеров, убранных пользователем) -> SUB_URLS из окружения -> ручной
  # интерактивный ввод.
  urls_file=$(mktemp "${TMPDIR:-/tmp}/setup_urls.XXXXXX")
  n=0

  if [ -f "$CONFIG" ]; then
    imported=$(mktemp "${TMPDIR:-/tmp}/setup_imported.XXXXXX")
    if awk -v urls_out="$imported" -v proxies_out="" -f "$SELFDIR/existing_config.awk" "$CONFIG" 2>/dev/null && [ -s "$imported" ]; then
      echo "Найдены подписки в текущем $CONFIG:" >&2
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
              echo "  $i) $uu (свой UA: $ua, имя: $nm)" >&2
            elif [ -n "$ua" ]; then
              echo "  $i) $uu (свой UA: $ua)" >&2
            elif [ -n "$nm" ]; then
              echo "  $i) $uu (имя: $nm)" >&2
            else
              echo "  $i) $uu" >&2
            fi
            ;;
          *) echo "  $i) $u" >&2 ;;
        esac
      done < "$imported"
      printf 'Введите номера через пробел, чтобы убрать лишние (Enter — оставить все): ' >&2
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
        printf 'Ссылка на подписку #%d (обязательно): ' "$((n + 1))" >&2
      else
        printf 'Есть ещё одна ссылка на подписку сверх уже указанных (%d шт.)? Если нет - просто нажмите Enter: ' "$n" >&2
      fi
      read -r url || url=""
      if [ -z "$url" ]; then
        if [ "$n" -gt 0 ]; then break; fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
          echo "нужна хотя бы одна ссылка на подписку" >&2
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
  # ("full"/"short"). Пустой вывод — ни один UA не подошёл.
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
      echo "для $url используется сохранённый UA \"$ua\" (перенесён из старого конфига, заново не проверялся)" >&2
      printf '%s\t%s\t%s\n' "$url" "$ua" "$name"
      continue
    fi
    result=$(pick_ua "$url")
    ua=$(printf '%s\n' "$result" | sed -n 1p)
    kind=$(printf '%s\n' "$result" | sed -n 2p)
    if [ -z "$ua" ]; then
      echo "для $url не подобран рабочий User-Agent — подписка исключена (проверьте вручную: sh detect_ua.sh \"$url\")" >&2
      continue
    fi
    if [ "$kind" = "short" ]; then
      echo "WARN для $url подошёл только укороченный clash YAML — сверьте набор нод после установки" >&2
    else
      echo "для $url подобран рабочий User-Agent \"$ua\"" >&2
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
        echo "имя \"$candidate\" для $url уже занято другой подпиской в этом запуске" >&2
        printf 'Введите другое имя провайдера для %s: ' "$url" >&2
        read -r final || final=""
      else
        printf 'Имя провайдера для %s [%s]: ' "$url" "$candidate" >&2
        read -r final || final=""
        [ -n "$final" ] || final=$candidate
      fi
      case "$final" in
        '') echo "имя не может быть пустым" >&2; continue ;;
        *[!A-Za-z0-9_-]*) echo "имя может содержать только латинские буквы, цифры, \"_\" и \"-\"" >&2; continue ;;
      esac
      if grep -qxF "$final" "$names_file" 2>/dev/null; then
        echo "имя \"$final\" уже занято другой подпиской в этом запуске" >&2
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

main() {
  check_mihomo_process && check_versions || return 1

  # Существующий dns: и так переносится как есть (existing_config.awk,
  # dns_out) - здесь речь не про сам DNS, а про стороннюю панель Xkeen UI:
  # она хранит хэш ВСЕГО config.yaml на момент включения своей "Защищённой
  # DNS Mihomo", и после перезаписи этот хэш неизбежно разойдётся, даже
  # если блок dns: не тронут ни на байт. Тогда её кнопка "Восстановить"
  # откатывает СВОЙ старый снимок и затирает то, что только что применил
  # setup.sh. SKIP_DNS_GUARD_CHECK=1 - явный обход для неинтерактивных
  # прогонов (тот, кто это выставляет, берёт ответственность на себя).
  if [ "${SKIP_DNS_GUARD_CHECK:-0}" != 1 ] && xkeen_ui_dns_protection_active; then
    echo "похоже, на роутере сейчас активна \"Защищённая DNS Mihomo\" панели Xkeen UI (или её DNS-over-VLESS для Xray - оба используют один и тот же переключатель Keenetic opkg dns-override)." >&2
    echo "config.yaml будет перезаписан. Блок dns: перенесётся как есть, но хэш ВСЕГО файла, который панель Xkeen UI сверяет сама с собой, после этого не совпадёт." >&2
    echo "после установки НЕ нажимайте \"Восстановить\" в панели Xkeen UI - это откатит её собственный старый снимок и затрёт результат этой установки. Если статус защиты в панели собьётся - просто включите её заново тем же способом, каким включали в первый раз." >&2
    printf 'продолжить установку? [y/N] ' >&2
    read -r dns_guard_ans || dns_guard_ans=""
    case "$dns_guard_ans" in
      [Yy]*) ;;
      *) echo "установка отменена" >&2; return 1 ;;
    esac
  fi

  [ -f "$TEMPLATE" ] || { echo "шаблон $TEMPLATE не найден" >&2; return 1; }

  subs_file=$(mktemp "${TMPDIR:-/tmp}/setup_urls.XXXXXX")
  if ! collect_subscriptions > "$subs_file"; then
    rm -f "$subs_file"
    return 1
  fi

  specs_file=$(mktemp "${TMPDIR:-/tmp}/setup_specs.XXXXXX")
  build_provider_specs "$subs_file" > "$specs_file"
  rm -f "$subs_file"

  if [ ! -s "$specs_file" ]; then
    echo "ни одна подписка не прошла проверку — устанавливать нечего" >&2
    rm -f "$specs_file"
    return 1
  fi

  named_file=$(mktemp "${TMPDIR:-/tmp}/setup_named.XXXXXX")
  assign_provider_names "$specs_file" > "$named_file"
  rm -f "$specs_file"
  specs_file=$named_file

  static_file=""
  dns_file=""
  if [ -f "$CONFIG" ]; then
    candidate=$(mktemp "${TMPDIR:-/tmp}/setup_static.XXXXXX")
    dns_candidate=$(mktemp "${TMPDIR:-/tmp}/setup_dns.XXXXXX")
    awk -v urls_out=/dev/null -v proxies_out="$candidate" -v dns_out="$dns_candidate" \
        -f "$SELFDIR/existing_config.awk" "$CONFIG" 2>/dev/null || true
    if [ -s "$candidate" ]; then
      count=$(grep -c '^  - name:' "$candidate" 2>/dev/null || echo 0)
      printf 'Найден блок proxies (%s нод) в текущем %s.\nПеренести как есть в новый config.yaml? [Y/n] ' "$count" "$CONFIG" >&2
      read -r ans || ans=""
      case "$ans" in
        [Nn]*) ;;
        *) static_file=$candidate ;;
      esac
    fi
    [ "$static_file" = "$candidate" ] || rm -f "$candidate"
    if [ -s "$dns_candidate" ]; then
      echo "найден блок dns в текущем $CONFIG, переношу как есть в новый config.yaml" >&2
      dns_file=$dns_candidate
    fi
    [ "$dns_file" = "$dns_candidate" ] || rm -f "$dns_candidate"
  fi

  if [ -f "$CONFIG" ]; then
    backup="$CONFIG.$(date '+%Y-%m-%d_%H%M%S').bak"
    cp "$CONFIG" "$backup" || {
      echo "не удалось сохранить бэкап $backup" >&2
      rm -f "$specs_file"
      [ -z "$static_file" ] || rm -f "$static_file"
      [ -z "$dns_file" ] || rm -f "$dns_file"
      return 1
    }
    echo "старый конфиг сохранён в $backup" >&2
  fi

  rendered=$(mktemp "${TMPDIR:-/tmp}/setup_config.XXXXXX")
  awk -v providers_file="$specs_file" -v static_file="$static_file" -v dns_file="$dns_file" -v mihomo_dir="$MIHOMO_DIR" \
      -f "$SELFDIR/render_config.awk" "$TEMPLATE" > "$rendered"
  rm -f "$specs_file"
  [ -z "$static_file" ] || rm -f "$static_file"
  [ -z "$dns_file" ] || rm -f "$dns_file"

  mtest_log=$(mktemp "${TMPDIR:-/tmp}/setup_mtest.XXXXXX")
  if ! "$BIN" -t -d "$MIHOMO_DIR" -f "$rendered" >"$mtest_log" 2>&1; then
    echo "новый конфиг не прошёл mihomo -t, $CONFIG не тронут. Вывод mihomo -t:" >&2
    cat "$mtest_log" >&2
    rm -f "$mtest_log"
    echo "непринятый конфиг оставлен в $rendered для разбора (удалите вручную, когда закончите)" >&2
    return 1
  fi
  rm -f "$mtest_log"

  mkdir -p "$DIR/proxy-providers"
  atomic_install "$rendered" "$CONFIG" || {
    echo "не удалось записать $CONFIG" >&2
    rm -f "$rendered"
    return 1
  }

  xkeen -restart

  i=0
  while [ "$i" -lt 20 ]; do
    curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
  done
  if ! curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1; then
    echo "mihomo не поднялся после xkeen -restart" >&2
    return 1
  fi

  echo "конфиг применён, запускаю install.sh" >&2
  exec sh "$SELFDIR/install.sh"
}

if [ "${SETUP_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
