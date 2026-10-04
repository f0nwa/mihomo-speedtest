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

mkdir -p "$T/self" "$T/bin" "$T/mihomo"
cp "$ROOT/config-tools/migrate_config.sh" "$ROOT/config-tools/migrate_config.awk" \
   "$ROOT/config-tools/config.example.yaml" "$T/self/"

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

# $1 - ответы на stdin; результат: $T/rc, $T/err
run_mode() {
  cp "$T/own.yaml" "$CONFIG"
  rm -f "$CONFIG".*.bak "$FAKE_XKEEN_LOG"
  rc=0
  printf '%b' "$1" | ( resolve_config_mode ) 2>"$T/err" || rc=$?
  echo "$rc" > "$T/rc"
}
unchanged() { cmp -s "$T/own.yaml" "$CONFIG" || fail "$1: конфиг не должен меняться"; }
own_notice() { grep -q "быстрый пул НЕ применяется" "$T/err" || fail "$1: нет предупреждения о своём конфиге"; }

# 1. Свой конфиг из окружения - без вопроса.
CONFIG_MODE=own run_mode ''
[ "$(cat "$T/rc")" = 0 ] || fail "CONFIG_MODE=own: rc"
unchanged "CONFIG_MODE=own"; own_notice "CONFIG_MODE=own"
grep -q "Введите номер" "$T/err" && fail "CONFIG_MODE=own не должен спрашивать"

# 2. Enter (и отсутствие терминала) - свой конфиг.
run_mode '\n'
unchanged "Enter"; own_notice "Enter"
grep -q "мигрировать конфиг к шаблону" "$T/err" || fail "вопрос о миграции не задан"

# 3. Миграция с подтверждением.
run_mode '1\ny\n'
[ "$(cat "$T/rc")" = 0 ] || fail "миграция: rc $(cat "$T/rc"): $(cat "$T/err")"
has_fast_group "$CONFIG" || fail "после миграции нет провайдера fast"
grep -q PRIVATE_TOKEN "$CONFIG" || fail "миграция потеряла подписку"
grep -q "сохранятся подписки: blancvpn" "$T/err" || fail "нет сводки миграции: $(cat "$T/err")"
grep -q "будут заменены шаблоном:.*rules" "$T/err" || fail "сводка не предупреждает о замене правил"
grep -q PRIVATE_TOKEN "$T/err" && fail "сводка раскрыла ссылку подписки"
set -- "$CONFIG".*.bak
[ -f "$1" ] && cmp -s "$1" "$T/own.yaml" || fail "нет бэкапа прежнего конфига"
grep -q -- -restart "$FAKE_XKEEN_LOG" || fail "ядро не перезапущено"
grep -q "быстрый пул НЕ применяется" "$T/err" && fail "после миграции не нужно предупреждение о своём конфиге"

# 4. Отказ на подтверждении.
run_mode '1\nn\n'
unchanged "отказ"; own_notice "отказ"
[ -f "$FAKE_XKEEN_LOG" ] && fail "отказ: ядро не должно перезапускаться"

# 5. Кандидат не прошёл mihomo -t.
FAKE_MIHOMO_RC=1 run_mode '1\ny\n'
unchanged "mihomo -t"; own_notice "mihomo -t"
grep -q "не прошёл mihomo -t" "$T/err" || fail "нет сообщения о mihomo -t"

# 6. Ядро не поднялось ни на новом, ни на прежнем конфиге: откат и стоп.
FAKE_CURL_RC=7 run_mode '1\ny\n'
[ "$(cat "$T/rc")" = 1 ] || fail "ядро не поднялось: установка должна остановиться"
unchanged "откат"
grep -q "возвращаю прежний" "$T/err" || fail "нет сообщения об откате"

# 7. Миграция невозможна - причина и свой конфиг.
printf 'log-level: info\n' >> "$T/own.yaml"
run_mode '1\ny\n'
grep -q "Миграция невозможна:.*log-level" "$T/err" || fail "нет причины отказа миграции: $(cat "$T/err")"
unchanged "невозможная миграция"; own_notice "невозможная миграция"

# 8. Быстрый пул уже есть - ничего не спрашиваем и не трогаем.
cp "$ROOT/config-tools/config.example.yaml" "$T/own.yaml"
run_mode ''
[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$T/err" ] || fail "с провайдером fast вопросов быть не должно: $(cat "$T/err")"
unchanged "есть fast"

echo "test_install_config_mode.sh: OK"
