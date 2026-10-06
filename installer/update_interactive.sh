#!/bin/sh
# Диалог только для терминала. Веб и автоматизация вызывают update.sh напрямую.
set -eu
umask 077
DIR=${DIR:-/opt/etc/mihomo-speedtest}
TMPROOT=${TMPROOT:-/tmp}
[ -t 0 ] || exec sh "$DIR/update.sh" --check
TMPROOT=$(CDPATH= cd -- "$TMPROOT" && pwd -P)
case $TMPROOT in /tmp|/tmp/*|/private/tmp|/private/tmp/*) ;; *) echo 'Рабочий каталог обновления должен находиться в /tmp' >&2; exit 1 ;; esac
UP_WORK=$(mktemp -d "$TMPROOT/mst-interactive.XXXXXX")
UP_SAVED_ID=
cleanup() {
  if [ -n "$UP_SAVED_ID" ]; then
    sh "$DIR/update.sh" --discard-plan "$UP_SAVED_ID" </dev/null >/dev/null 2>&1 || true
  fi
  rm -rf "$UP_WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
ask() {
  while :; do
    printf '%s [д/Н]: ' "$1"
    IFS= read -r UP_ANSWER || return 1
    case $UP_ANSWER in д|Д|да|Да|ДА|y|Y|yes|YES) return 0 ;; ''|н|Н|нет|Нет|НЕТ|n|N|no|NO) return 1 ;; esac
    echo 'Введите д (да) или н (нет). Enter означает нет.'
  done
}
cancel() { echo 'Обновление отменено. Файлы проекта не изменены.'; exit 0; }
engine() {
  if sh "$DIR/update.sh" "$@" </dev/null > "$UP_WORK/result" 2> "$UP_WORK/error"; then return 0; fi
  echo 'Не удалось завершить этот шаг:' >&2
  tail -5 "$UP_WORK/error" >&2
  echo 'Устраните указанную причину и снова выполните mihomo-speedtest update.' >&2
  return 1
}
# Это разбор фиксированных полей JSON, который печатает update_plan.awk.
# Значения не исполняются через eval; свободный текст манифеста не разбирается.
read_plan() {
  awk '
    function str(k, v) {
      if (!match($0, "\"" k "\":\"[A-Za-z0-9_.-]*\"")) { bad=1; return "" }
      v=substr($0,RSTART,RLENGTH); sub(/^[^:]*:\"/,"",v); sub(/\"$/,"",v); return v
    }
    function bool(k, v) {
      if (!match($0, "\"" k "\":(true|false)")) { bad=1; return "" }
      v=substr($0,RSTART,RLENGTH); sub(/^[^:]*:/,"",v); return v
    }
    {
      tag=str("release_tag"); id=str("plan_id"); version=str("release_version")
      prepared=bool("prepared"); overwrite=bool("overwrite_required")
      config=bool("confirmation_required"); old=str("old_schema"); schema=str("config_schema_version")
      if (tag=="" || length(id)!=64 || id !~ /^[0-9a-f]+$/ || version !~ /^[0-9]+$/ || old !~ /^[0-9]+$/ || schema !~ /^[0-9]+$/) bad=1
      changes=($0 ~ /"state":"(new|missing|modified|changed|removed)"/)
      web=($0 ~ /"restart-web"/); mihomo=($0 ~ /"restart-mihomo"/)
      print tag; print id; print version; print prepared; print overwrite; print config
      print old; print schema; print changes; print web; print mihomo
    }
    END { if (NR!=1 || bad) exit 1 }
  ' "$UP_WORK/result" > "$UP_WORK/meta" || { echo 'Обновлятор вернул непонятный план; применение остановлено.' >&2; return 1; }
  {
    IFS= read -r UP_TAG; IFS= read -r UP_ID; IFS= read -r UP_VERSION
    IFS= read -r UP_PREPARED; IFS= read -r UP_OVERWRITE; IFS= read -r UP_CONFIG
    IFS= read -r UP_OLD_SCHEMA; IFS= read -r UP_SCHEMA; IFS= read -r UP_CHANGES
    IFS= read -r UP_WEB; IFS= read -r UP_MIHOMO
  } < "$UP_WORK/meta"
}
effects() {
  [ "$UP_WEB" != 1 ] || echo 'После установки веб-интерфейс ненадолго перезапустится.'
  [ "$UP_MIHOMO" != 1 ] || echo 'Будет перезапущен XKeen; соединения через прокси могут кратковременно прерваться.'
}
echo 'Проверяю обновления...'
engine --plan --format=json
read_plan
UP_INSTALLED=${INSTALLED_MANIFEST_PATH:-${UPDATE_STATE_DIR:-$DIR/.update}/installed-manifest.txt}
UP_OLD_TAG=$(sed -n 's/^RELEASE_TAG=//p' "$UP_INSTALLED" 2>/dev/null | head -1) || UP_OLD_TAG=
[ -z "$UP_OLD_TAG" ] || printf 'Установлен релиз: %s\n' "$UP_OLD_TAG"
if [ "$UP_CHANGES" = 0 ] && [ "$UP_OLD_TAG" = "$UP_TAG" ] && [ "$UP_SCHEMA" -le "$UP_OLD_SCHEMA" ]; then
  echo 'Обновлений нет. Установлена актуальная версия.'
  exit 0
fi
printf 'Доступен релиз: %s\n' "$UP_TAG"
effects
ask 'Установить обновление?' || cancel
UP_REQUESTED_TAG=$UP_TAG
UP_COMPONENTS=
if [ "$UP_SCHEMA" -gt "$UP_OLD_SCHEMA" ]; then
  echo 'Доступно также обновление config.yaml. Его можно отложить и выполнить через веб-интерфейс.'
  if ask 'Подготовить обновление config.yaml вместе с проектом?'; then
    # Состав берётся из плана: не фиксируем перечень компонентов в оболочке.
    UP_COMPONENTS=$(awk '
      { s=$0; sub(/^.*"components":\[/,"",s); sub(/\],"conflicts":.*$/,"",s)
        while(match(s,/"id":"[a-z][a-z0-9-]*"/)) {
          v=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
          sub(/^"id":"/,"",v); sub(/"$/,"",v); printf "%s%s",sep,v;sep=","
        }
      }' "$UP_WORK/result")
    [ -n "$UP_COMPONENTS" ] || { echo 'Не удалось определить компоненты обновления.' >&2; exit 1; }
    UP_COMPONENTS=$UP_COMPONENTS,active-config
  fi
fi
echo 'Скачиваю и проверяю файлы обновления...'
set -- --prepare --format=json
[ -z "$UP_COMPONENTS" ] || set -- "$@" "--components=$UP_COMPONENTS"
engine "$@"
read_plan
[ "$UP_PREPARED" = true ] || { echo 'Обновлятор не подтвердил готовность файлов.' >&2; exit 1; }
UP_SAVED_ID=$UP_ID
if [ "$UP_TAG" != "$UP_REQUESTED_TAG" ]; then
  printf 'За время проверки появился другой релиз: %s.\n' "$UP_TAG"
  ask 'Установить этот релиз?' || cancel
fi
set -- --apply "$UP_SAVED_ID" --format=json
if [ "$UP_OVERWRITE" = true ]; then
  echo 'Будут заменены локально изменённые файлы. Изменённые или удаляемые файлы:'
  awk '{gsub(/},{/,"}\n{"); print}' "$UP_WORK/result" | awk '
    /"state":"(modified|changed|removed)"/ {
      if(match($0,/"dest":"[^"]*"/)) {v=substr($0,RSTART+8,RLENGTH-9);print "  " v}
    }'
  ask 'Разрешить замену локальных правок?' || cancel
  set -- "$@" --confirm-local
fi
if [ "$UP_CONFIG" = true ]; then
  echo 'Изменения рабочего конфига:'
  engine --show-config-diff "$UP_SAVED_ID"
  cat "$UP_WORK/result"
  echo 'Применение конфига потребует перезапуска XKeen.'
  ask 'Применить эти изменения config.yaml?' || cancel
  set -- "$@" --confirm-config
fi
echo 'Устанавливаю обновление...'
engine "$@"
printf 'Готово. Установлен релиз %s.\n' "$UP_TAG"
if [ "$UP_SCHEMA" -gt "$UP_OLD_SCHEMA" ] && [ "$UP_CONFIG" != true ]; then
  echo 'Обновление config.yaml отложено. Оно доступно на вкладке «Обновления» веб-интерфейса.'
fi
