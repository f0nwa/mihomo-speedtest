#!/bin/sh
# Конфиг без быстрого пула при установке: миграция к шаблону или свой
# конфиг (install.sh:resolve_config_mode).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/install.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

# migrate_config.sh принимает выход только в /tmp.
T=$(mktemp -d /tmp/install-config-mode-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
# Журнал UI - во временный каталог (не /opt/var/log): ui_run пишет туда
# вывод mihomo -t и перезапуска ядра.
UI_LOG=$T/ui.log
export UI_LOG

mkdir -p "$T/self" "$T/bin" "$T/mihomo"
cp "$ROOT/config-tools/migrate_config.sh" "$ROOT/config-tools/migrate_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/config.example.yaml" "$ROOT/config-tools/reset_config.sh" "$ROOT/config-tools/constructor_build.sh" \
   "$ROOT/config-tools/render_services.awk" "$ROOT/config-tools/config_to_state.awk" "$ROOT/config-tools/services.default.tsv" "$T/self/"

cat > "$T/bin/mihomo" <<'INNER'
#!/bin/sh
exit "${FAKE_MIHOMO_RC:-0}"
INNER
cat > "$T/bin/xkeen" <<'INNER'
#!/bin/sh
echo "$*" >> "$FAKE_XKEEN_LOG"
INNER
cat > "$T/bin/curl" <<'INNER'
#!/bin/sh
exit "${FAKE_CURL_RC:-0}"
INNER
chmod +x "$T/bin/mihomo" "$T/bin/xkeen" "$T/bin/curl"

cat > "$T/own.yaml" <<'INNER'
log-level: silent
external-controller: 0.0.0.0:9090
anchors:
  a1: &domain { type: http, format: mrs, behavior: domain, interval: 86400 }
proxy-providers:
  blancvpn:
    type: http
    url: "https://sub.example/PRIVATE_TOKEN"
    path: ./proxy-providers/blancvpn.yaml
    interval: 86400
proxy-groups:
  - name: Mine
    type: select
    use: [blancvpn]
rules:
  - MATCH,Mine
INNER

INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$SCRIPT"
unset INSTALL_LIB_ONLY
SELFDIR=$T/self
MIHOMO_DIR=$T/mihomo
CONFIG=$T/mihomo/config.yaml
BIN=$T/bin/mihomo
XKEEN_BIN=$T/bin/xkeen
TMPROOT=$T
CORE_WAIT=1
PATH="$T/bin:$PATH"
FAKE_XKEEN_LOG=$T/xkeen.log
export PATH FAKE_XKEEN_LOG
# Схема конфига: после миграции к шаблону (или конфига от мастера setup.sh)
# установщик пишет схему установленного релиза в config-schema-version.
UPDATE_STATE_DIR=$T/state
INSTALLED_MANIFEST_PATH=$T/state/installed-manifest.txt
SV=$T/state/config-schema-version
mkdir -p "$T/state"
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=9\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=4\nRELEASE_TAG=v9\n' > "$INSTALLED_MANIFEST_PATH"
no_schema() { [ ! -e "$SV" ] || fail "$1: схема конфига не должна записываться"; }

# $1 - ответы на stdin; результат: $T/rc, $T/err
run_mode() {
  cp "$T/own.yaml" "$CONFIG"
  rm -f "$CONFIG".*.bak "$FAKE_XKEEN_LOG" "$SV"
  rc=0
  # Флаг MST_OWN_CONFIG живёт в подоболочке - выносим его в файл.
  printf '%b' "$1" | ( rm_rc=0; resolve_config_mode || rm_rc=$?; echo "${MST_OWN_CONFIG:-0}" > "$T/own"; exit "$rm_rc" ) 2>"$T/err" || rc=$?
  echo "$rc" > "$T/rc"
}
unchanged() { cmp -s "$T/own.yaml" "$CONFIG" || fail "$1: конфиг не должен меняться"; }
# Свой конфиг: resolve_config_mode только ставит флаг MST_OWN_CONFIG=1, а
# сам блок предупреждения main() печатает перед сводкой (own_config_notice).
own_notice() {
  [ "$(cat "$T/own")" = 1 ] || fail "$1: нет флага MST_OWN_CONFIG=1"
  grep -q "быстрый пул НЕ применяется" "$T/err" && fail "$1: предупреждение печатается main() перед сводкой, не здесь"
  ( own_config_notice ) 2>"$T/notice"
  grep -q "^  | .*быстрый пул НЕ применяется" "$T/notice" || fail "$1: own_config_notice должен печатать блок: $(cat "$T/notice")"
}

# 1. Свой конфиг из окружения - без вопроса.
CONFIG_MODE=own run_mode ''
[ "$(cat "$T/rc")" = 0 ] || fail "CONFIG_MODE=own: rc"
unchanged "CONFIG_MODE=own"; own_notice "CONFIG_MODE=own"; no_schema "CONFIG_MODE=own"
grep -q "Введите номер" "$T/err" && fail "CONFIG_MODE=own не должен спрашивать"

# 2. Enter (и отсутствие терминала) - свой конфиг.
run_mode '\n'
unchanged "Enter"; own_notice "Enter"
grep -q "мигрировать конфиг к шаблону" "$T/err" || fail "вопрос о миграции не задан"
# Меню - блоком: заголовок и пункты (с пояснениями к пункту 1) за чертой.
grep -q '^  | В конфиге нет быстрого пула' "$T/err" || fail "вопрос о миграции должен быть блоком: $(cat "$T/err")"
grep -q '^  |  1) мигрировать конфиг к шаблону' "$T/err" || fail "пункт 1 меню миграции не в блоке"
grep -q '^  | .*rule-providers и правила будут из шаблона' "$T/err" || fail "пояснение к пункту 1 должно быть строкой того же блока"
grep -q '^\[??\] Введите номер или Enter для 2: ' "$T/err" || fail "нет приглашения ввода ui_ask"

# 3. Миграция с подтверждением.
run_mode '1\ny\n'
[ "$(cat "$T/rc")" = 0 ] || fail "миграция: rc $(cat "$T/rc"): $(cat "$T/err")"
has_fast_group "$CONFIG" || fail "после миграции нет провайдера fast"
grep -q PRIVATE_TOKEN "$CONFIG" || fail "миграция потеряла подписку"
grep -q "| сохранятся подписки: blancvpn" "$T/err" || fail "нет сводки миграции блоком: $(cat "$T/err")"
grep -q "будут заменены шаблоном:.*rules" "$T/err" || fail "сводка не предупреждает о замене правил"
grep -q PRIVATE_TOKEN "$T/err" && fail "сводка раскрыла ссылку подписки"
set -- "$CONFIG".*.bak
[ -f "$1" ] && cmp -s "$1" "$T/own.yaml" || fail "нет бэкапа прежнего конфига"
grep -q -- -restart "$FAKE_XKEEN_LOG" || fail "ядро не перезапущено"
[ "$(cat "$T/own")" = 0 ] || fail "после миграции не нужно предупреждение о своём конфиге (MST_OWN_CONFIG)"
[ "$(cat "$SV" 2>/dev/null)" = 4 ] || fail "миграция: схема конфига не записана"
[ "$(stat -c %a "$SV" 2>/dev/null || stat -f %Lp "$SV")" = 600 ] || fail "миграция: режим файла схемы"
# Без установленного манифеста (файлы перенесены вручную) схема не пишется.
mv "$INSTALLED_MANIFEST_PATH" "$T/manifest.saved"
run_mode '1\ny\n'
[ "$(cat "$T/rc")" = 0 ] || fail "миграция без манифеста: rc"
no_schema "миграция без манифеста"
mv "$T/manifest.saved" "$INSTALLED_MANIFEST_PATH"

# 4. Отказ на подтверждении.
run_mode '1\nn\n'
unchanged "отказ"; own_notice "отказ"; no_schema "отказ"
[ -f "$FAKE_XKEEN_LOG" ] && fail "отказ: ядро не должно перезапускаться"

# 5. Кандидат не прошёл mihomo -t.
FAKE_MIHOMO_RC=1 run_mode '1\ny\n'
unchanged "mihomo -t"; own_notice "mihomo -t"
grep -q "не прошёл mihomo -t" "$T/err" || fail "нет сообщения о mihomo -t"

# 6. Ядро не поднялось ни на новом, ни на прежнем конфиге: откат и стоп.
FAKE_CURL_RC=7 run_mode '1\ny\n'
[ "$(cat "$T/rc")" = 1 ] || fail "ядро не поднялось: установка должна остановиться"
unchanged "откат"; no_schema "откат"
grep -q "возвращаю прежний" "$T/err" || fail "нет сообщения об откате"

# 7. Миграция невозможна - причина и свой конфиг.
printf 'log-level: info\n' >> "$T/own.yaml"
run_mode '1\ny\n'
grep -q "Миграция невозможна:.*log-level" "$T/err" || fail "нет причины отказа миграции: $(cat "$T/err")"
unchanged "невозможная миграция"; own_notice "невозможная миграция"

# 8. config.yaml - символическая ссылка на профиль XKeen UI: миграция
# пишет в профиль, ссылка остаётся; при откате - тоже.
sed '/^log-level: info$/d' "$T/own.yaml" > "$T/own-link.yaml"
mkdir -p "$T/mihomo/profiles"
link_mode() {
  rm -f "$CONFIG" "$CONFIG".*.bak "$FAKE_XKEEN_LOG"
  cp "$T/own-link.yaml" "$T/mihomo/profiles/default.yaml"
  chmod 0640 "$T/mihomo/profiles/default.yaml"
  ln -s profiles/default.yaml "$CONFIG"
  rc=0
  printf '%b' "$1" | ( resolve_config_mode ) 2>"$T/err" || rc=$?
  echo "$rc" > "$T/rc"
  [ -L "$CONFIG" ] && [ "$(readlink "$CONFIG")" = profiles/default.yaml ] || fail "$2: config.yaml перестал быть ссылкой"
}
link_mode '1\ny\n' "ссылка, миграция"
[ "$(cat "$T/rc")" = 0 ] || fail "ссылка, миграция: rc $(cat "$T/rc"): $(cat "$T/err")"
has_fast_group "$T/mihomo/profiles/default.yaml" || fail "ссылка: профиль не мигрирован"
grep -q PRIVATE_TOKEN "$T/mihomo/profiles/default.yaml" || fail "ссылка: потеряна подписка"
[ "$(stat -c %a "$T/mihomo/profiles/default.yaml" 2>/dev/null || stat -f %Lp "$T/mihomo/profiles/default.yaml")" = 640 ] || fail "ссылка: права профиля изменились"
set -- "$CONFIG".*.bak
[ -f "$1" ] && [ ! -L "$1" ] && cmp -s "$1" "$T/own-link.yaml" || fail "ссылка: бэкап должен быть копией содержимого"
FAKE_CURL_RC=7 link_mode '1\ny\n' "ссылка, откат"
cmp -s "$T/mihomo/profiles/default.yaml" "$T/own-link.yaml" || fail "ссылка, откат: профиль не восстановлен"
rm -f "$CONFIG" "$CONFIG".*.bak; rm -rf "$T/mihomo/profiles"

# 10. Замена шаблоном (CONFIG_MODE=reset и пункт 3 меню): остаются только
# подписки и ноды, остальное из шаблона; бэкап, перезапуск, схема конфига.
cp "$T/own-link.yaml" "$T/own.yaml"
CONFIG_MODE=reset run_mode ''
[ "$(cat "$T/rc")" = 0 ] || fail "замена: rc $(cat "$T/rc"): $(cat "$T/err")"
has_fast_group "$CONFIG" || fail "после замены нет провайдера fast"
grep -q PRIVATE_TOKEN "$CONFIG" || fail "замена потеряла подписку"
grep -q 'name: Mine' "$CONFIG" && fail "замена оставила чужую группу"
grep -q PRIVATE_TOKEN "$T/err" && fail "сводка замены раскрыла ссылку подписки"
grep -q "подписок 1, нод 0" "$T/err" || fail "нет сводки замены (сколько осталось): $(cat "$T/err")"
set -- "$CONFIG".*.bak
[ -f "$1" ] && cmp -s "$1" "$T/own.yaml" || fail "замена: нет бэкапа прежнего конфига"
grep -q -- -restart "$FAKE_XKEEN_LOG" || fail "замена: ядро не перезапущено"
[ "$(cat "$T/own")" = 0 ] || fail "после замены не нужно предупреждение о своём конфиге"
[ "$(cat "$SV" 2>/dev/null)" = 4 ] || fail "замена: схема конфига не записана"
# Меню: пункт 3 - замена, пункт 2 по-прежнему умолчание (свой конфиг).
run_mode '3\ny\n'
[ "$(cat "$T/rc")" = 0 ] || fail "пункт 3: rc"
grep -q 'name: Mine' "$CONFIG" && fail "пункт 3 не заменил конфиг"
grep -q '^  |  3) заменить шаблоном' "$T/err" || fail "в меню нет пункта 3: $(cat "$T/err")"
grep -q '^\[??\] Введите номер или Enter для 2: ' "$T/err" || fail "умолчание меню изменилось"
# Отказ на подтверждении замены.
run_mode '3\nn\n'
unchanged "отказ от замены"; own_notice "отказ от замены"; no_schema "отказ от замены"
# Кандидат замены не прошёл mihomo -t.
FAKE_MIHOMO_RC=1 CONFIG_MODE=reset run_mode ''
unchanged "замена, mihomo -t"; own_notice "замена, mihomo -t"
grep -q "не прошёл mihomo -t" "$T/err" || fail "замена: нет сообщения о mihomo -t"
# Ядро не поднялось ни на новом, ни на прежнем конфиге: откат и стоп.
FAKE_CURL_RC=7 CONFIG_MODE=reset run_mode ''
[ "$(cat "$T/rc")" = 1 ] || fail "замена, ядро не поднялось: установка должна остановиться"
unchanged "замена, откат"; no_schema "замена, откат"
# Нечего переносить: ни подписок, ни нод - причина и свой конфиг.
printf 'log-level: silent\nrules:\n  - MATCH,DIRECT\n' > "$T/own.yaml"
CONFIG_MODE=reset run_mode ''
grep -q "Замена шаблоном невозможна:.*нет ни подписок, ни нод" "$T/err" || fail "нет причины отказа замены: $(cat "$T/err")"
unchanged "замена без подписок"; own_notice "замена без подписок"

# 9. Быстрый пул уже есть - ничего не спрашиваем и не трогаем.
cp "$ROOT/config-tools/config.example.yaml" "$T/own.yaml"
run_mode ''
[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$T/err" ] || fail "с провайдером fast вопросов быть не должно: $(cat "$T/err")"
unchanged "есть fast"; no_schema "есть fast"
# Конфиг только что создал мастер setup.sh (MST_CONFIG_FROM_TEMPLATE=1).
MST_CONFIG_FROM_TEMPLATE=1 run_mode ''
[ "$(cat "$T/rc")" = 0 ] || fail "после setup.sh: rc"
[ "$(cat "$SV" 2>/dev/null)" = 4 ] || fail "после setup.sh: схема конфига не записана"
grep -q 'MST_CONFIG_FROM_TEMPLATE=1 exec sh "$SELFDIR/install.sh"' "$ROOT/config-tools/setup.sh" || fail "setup.sh не помечает конфиг из шаблона"

echo "test_install_config_mode.sh: OK"
