#!/bin/sh
# Интерфейс конструктора конфига: файлы подключены и раздаются, режимы
# переключаются, уход с несохранёнными правками спрашивает подтверждение.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
UI=$ROOT/web/stats_app_constructor.js
CFG=$ROOT/web/stats_app_config.js
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$UI" ] || fail "нет web/stats_app_constructor.js"
grep -q '"app-constructor.js": "stats_app_constructor.js"' "$ROOT/web/stats_httpd.py" || fail "STATIC_FILES: app-constructor.js"
grep -q '"app-constructor-model.js": "stats_app_constructor_model.js"' "$ROOT/web/stats_httpd.py" || fail "STATIC_FILES: app-constructor-model.js"
grep -q 'for m in .*constructor constructor_model' "$ROOT/install.sh" || fail "install.sh: цикл stats_app_\$m без constructor"
for f in stats_app_constructor.js stats_app_constructor_model.js stats_app_constructor_modules.js stats_app_constructor_modules_model.js; do
  grep -q "web/$f|/opt/etc/mihomo-speedtest/$f|0644|none" "$ROOT/release/components.txt" || fail "components.txt: $f"
  grep -q "$f" "$ROOT/uninstall.sh" || fail "uninstall.sh: $f"
  case " $(sed -n 's/^ALL_PROJECT_FILES="\(.*\)"$/\1/p' "$ROOT/install.sh") " in *" $f "*) ;; *) fail "ALL_PROJECT_FILES: $f" ;; esac
done

# Режимы и dirty
grep -q "from './app-constructor.js'" "$CFG" || fail "app-config.js не подключает конструктор"
grep -q 'constructorDirty()' "$CFG" || fail "configDirty не учитывает правки конструктора"
grep -q "'Конструктор'" "$CFG" && grep -q "'YAML'" "$CFG" || fail "нет переключателя Конструктор/YAML"
grep -q "from './app-constructor-model.js'" "$UI" || fail "UI не использует модель"
grep -q "/api/constructor/preview" "$UI" || fail "нет предпросмотра"
grep -q "/api/constructor/apply?base=" "$UI" || fail "применение без base"
grep -q "import=1" "$UI" || fail "нет «Перенести в конструктор»"
grep -q "Проверить и применить" "$UI" || fail "нет кнопки применения"

# ревью порции 3
grep -q "if (configDirty())" "$CFG" || fail "beforeunload не учитывает правки конструктора"
awk '/function modeBar/{on=1} on && /nextView\(\)/{f=1} on && /^}/{exit} END{exit !f}' "$CFG" || fail "переключение режима без nextView()"
grep -q "nextView()" "$UI" || fail "перерисовка конструктора без nextView()"
grep -q "Перенос из config.yaml" "$UI" || fail "перенос не считается изменением"
grep -q "conflict" "$UI" && grep -q "ещё раз" "$UI" || fail "409: правки должны сохраняться, нужно применить ещё раз"

# порция 4: база правил
grep -q '/api/constructor/catalog' "$UI" || fail "UI не загружает каталог"
grep -q 'Куда отправлять' "$UI" || fail "нет поля «Куда отправлять»"
grep -q 'Уже в конфиге' "$UI" || fail "нет фильтра «Уже в конфиге»"
grep -q 'базы обновлены' "$UI" || fail "нет даты базы"
grep -q 'Можно и без базы' "$UI" || fail "нет подсказки про добавление без базы"
grep -q 'Добавить сервис из базы' "$UI" || fail "нет кнопки «Добавить сервис из базы»"
grep -q 'showModal' "$UI" || fail "окно добавления не модальное"
grep -q 'searchCatalog' "$UI" || fail "UI не ищет через модель"
grep -q '"api/constructor/catalog": ("stats_constructor.sh"' "$ROOT/web/stats_httpd.py" || fail "маршрут каталога"
grep -q 'config-tools/rule-catalog.tsv|/opt/etc/mihomo-speedtest/rule-catalog.tsv' "$ROOT/release/components.txt" || fail "components: rule-catalog.tsv"
grep -q 'rule-catalog.tsv' "$ROOT/uninstall.sh" || fail "uninstall: rule-catalog.tsv"
grep -q '^PROJECT_TOOLS=.*rule-catalog.tsv' "$ROOT/install.sh" || fail "PROJECT_TOOLS: rule-catalog.tsv"

grep -q 'перехват' "$UI" || fail "нет предупреждения о перехвате трафика встроенного сервиса"
grep -q 'findByName' "$UI" || fail "имя существующей группы - подключение к ней, а не ошибка"
grep -q 'checkSource' "$UI" || fail "наборы проверяются до добавления"

# Блоки порции 5: подписки, свои прокси, исключения нод, базовые группы
MOD="$ROOT/web/stats_app_constructor_modules.js"
grep -q '"app-constructor-modules.js": "stats_app_constructor_modules.js"' "$ROOT/web/stats_httpd.py" || fail "STATIC_FILES: app-constructor-modules.js"
grep -q '"app-constructor-modules-model.js": "stats_app_constructor_modules_model.js"' "$ROOT/web/stats_httpd.py" || fail "STATIC_FILES: app-constructor-modules-model.js"
grep -q 'for m in .*constructor_modules constructor_modules_model' "$ROOT/install.sh" || fail "install.sh: цикл stats_app_\$m без модулей"
for f in stats_app_constructor_modules.js stats_app_constructor_modules_model.js; do
  grep -q "web/$f|/opt/etc/mihomo-speedtest/$f|0644|none" "$ROOT/release/components.txt" || fail "components.txt: $f"
  grep -q "$f" "$ROOT/uninstall.sh" || fail "uninstall.sh: $f"
  case " $(sed -n 's/^ALL_PROJECT_FILES="\(.*\)"$/\1/p' "$ROOT/install.sh") " in *" $f "*) ;; *) fail "ALL_PROJECT_FILES: $f" ;; esac
done
for t in "card('Подписки')" "card('Свои прокси')" "card('Исключения нод')" "card('Базовые группы')"; do
  grep -qF "$t" "$MOD" || fail "нет карточки $t"
done
grep -q "createModuleCards" "$UI" || fail "UI не подключает блоки"
grep -q "mods.serialize()" "$UI" || fail "подписки, ноды и фильтр не уходят в состояние"
grep -q "mods.problems()" "$UI" || fail "применение не проверяет, что есть подписки или ноды"
grep -q "/api/constructor/wgconf" "$MOD" || fail "нет импорта WireGuard .conf"
grep -q "hostOf" "$MOD" || fail "адрес подписки показывается целиком (в нём ключ доступа)"

# Синтаксис ES-модулей (если есть node)
if command -v node >/dev/null 2>&1; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  for f in stats_app_constructor.js stats_app_constructor_model.js stats_app_constructor_modules.js stats_app_constructor_modules_model.js stats_app_settings.js stats_app_config.js; do
    cp "$ROOT/web/$f" "$T/${f%.js}.mjs"
    node --check "$T/${f%.js}.mjs" || fail "синтаксис $f"
  done
fi
echo "OK test_constructor_ui"
