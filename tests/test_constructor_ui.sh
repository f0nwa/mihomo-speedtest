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
grep -q '"api/constructor/icons": ("stats_constructor.sh"' "$ROOT/web/stats_httpd.py" || fail "маршрут каталога иконок"
grep -q 'config-tools/rule-catalog.tsv|/opt/etc/mihomo-speedtest/rule-catalog.tsv' "$ROOT/release/components.txt" || fail "components: rule-catalog.tsv"
grep -q 'config-tools/icon-catalog.tsv|/opt/etc/mihomo-speedtest/icon-catalog.tsv' "$ROOT/release/components.txt" || fail "components: icon-catalog.tsv"
grep -q 'rule-catalog.tsv' "$ROOT/uninstall.sh" || fail "uninstall: rule-catalog.tsv"
grep -q 'icon-catalog.tsv' "$ROOT/uninstall.sh" || fail "uninstall: icon-catalog.tsv"
grep -q '^PROJECT_TOOLS=.*rule-catalog.tsv' "$ROOT/install.sh" || fail "PROJECT_TOOLS: rule-catalog.tsv"
grep -q '^PROJECT_TOOLS=.*icon-catalog.tsv' "$ROOT/install.sh" || fail "PROJECT_TOOLS: icon-catalog.tsv"

grep -q 'перехват' "$UI" || fail "нет предупреждения о перехвате трафика встроенного сервиса"
grep -q 'findByName' "$UI" || fail "имя существующей группы - подключение к ней, а не ошибка"
grep -q 'checkSource' "$UI" || fail "наборы проверяются до добавления"
grep -q 'URL иконки' "$UI" || fail "нет поля ручного URL иконки"
grep -q 'model.setServiceIcon(id' "$UI" || fail "иконка не сохраняется при создании сервиса"
grep -q 'ks.length > 0' "$UI" || fail "поле иконки показывается до выбора набора правил"
grep -q 'iconBox.hidden' "$UI" || fail "поле иконки не скрывается"
grep -q "fetchJson('/api/constructor/icons')" "$UI" || fail "каталог иконок не загружается"
grep -q 'if (!iconRequested)' "$UI" || fail "повторный запрос каталога при перерисовке окна"
grep -q 'if (closed || iconBox.hidden)' "$UI" || fail "запоздалый ответ меняет закрытое окно"
grep -q 'searchIcons(iconEntries, query, 6)' "$UI" || fail "поиск другого значка не ограничен шестью вариантами"
grep -q 'iconSearch' "$UI" || fail "нет поиска другого значка"

# Блоки порции 5: подписки, прокси, исключения нод, базовые группы
MOD="$ROOT/web/stats_app_constructor_modules.js"
grep -q '"app-constructor-modules.js": "stats_app_constructor_modules.js"' "$ROOT/web/stats_httpd.py" || fail "STATIC_FILES: app-constructor-modules.js"
grep -q '"app-constructor-modules-model.js": "stats_app_constructor_modules_model.js"' "$ROOT/web/stats_httpd.py" || fail "STATIC_FILES: app-constructor-modules-model.js"
grep -q 'for m in .*constructor_modules constructor_modules_model' "$ROOT/install.sh" || fail "install.sh: цикл stats_app_\$m без модулей"
for f in stats_app_constructor_modules.js stats_app_constructor_modules_model.js; do
  grep -q "web/$f|/opt/etc/mihomo-speedtest/$f|0644|none" "$ROOT/release/components.txt" || fail "components.txt: $f"
  grep -q "$f" "$ROOT/uninstall.sh" || fail "uninstall.sh: $f"
  case " $(sed -n 's/^ALL_PROJECT_FILES="\(.*\)"$/\1/p' "$ROOT/install.sh") " in *" $f "*) ;; *) fail "ALL_PROJECT_FILES: $f" ;; esac
done
for t in "layout.add(1, 'Подписки'" "layout.add(2, 'Прокси'" "layout.add(5, 'Исключения нод'" "layout.add(6, 'Базовые группы'"; do
  grep -qF "$t" "$MOD" || fail "нет карточки $t"
done
grep -q "createModuleCards" "$UI" || fail "UI не подключает блоки"
grep -q "mods.serialize()" "$UI" || fail "подписки, ноды и фильтр не уходят в состояние"
grep -q "mods.problems()" "$UI" || fail "применение не проверяет, что есть подписки или ноды"
grep -q "/api/constructor/wgconf" "$MOD" || fail "нет импорта WireGuard .conf"
grep -q "hostOf" "$MOD" || fail "адрес подписки показывается целиком (в нём ключ доступа)"

# Раскладка по макету: слева список модулей (название, сводка, «изменён»), справа выбранный; применение сверху
for t in "layout.add(3, 'Сервисы'" "layout.add(4, 'Свои домены'" "layout.add(7, 'Свои правила'"; do
  grep -qF "$t" "$UI" || fail "нет блока $t"
done
grep -q "'изменён'" "$MOD" || fail "нет пометки «изменён»"
grep -q "cx-topbar" "$UI" || fail "кнопка применения не наверху"
! grep -q "card('Изменения')" "$UI" || fail "осталась нижняя карточка «Изменения»"
grep -q "createLayout" "$UI" || fail "нет раскладки слева-справа"
grep -q "createLayout(opts.module != null ? opts.module : 1)" "$UI" || fail "по умолчанию должен открываться модуль «Подписки»"
grep -q "layout.add(0, 'Устройство')" "$UI" || fail "нет модуля «Устройство» перед «Подписками»"
grep -q "export function buildDevice" "$MOD" || fail "нет редактора устройства в модулях конструктора"
! grep -q "buildDevice\|api/constructor/device" "$ROOT/web/stats_app_settings.js" || fail "редактор устройства остался в Настройках"
! grep -q "cx-bnum" "$MOD" || fail "в списке модулей остались номера"
grep -q "cx-nav" "$MOD" || fail "нет списка модулей слева"
grep -q "model.changes(initial)" "$UI" || fail "блоки не помечаются изменёнными"
# режим по умолчанию - YAML (иначе каждый переход по вкладкам спрашивал бы подтверждение)
grep -q "=== 'constructor' ? 'constructor' : 'yaml'" "$CFG" || fail "по умолчанию должен открываться YAML"

# замена шаблоном (подписки и ноды остаются) и баннер при непроходящем конфиге
grep -q '/api/constructor/reset-preview' "$CFG" || fail "нет предпросмотра замены шаблоном"
grep -q '/api/constructor/reset?base=' "$CFG" || fail "замена шаблоном применяется без base"
grep -q 'Заменить шаблоном' "$CFG" || fail "нет пункта «Заменить шаблоном»"
grep -q 'function resetFromTemplate' "$CFG" || fail "нет resetFromTemplate()"
grep -q 'nothing_to_keep' "$CFG" || fail "нет сообщения «нечего переносить»"
grep -q "postText('/api/config/check'" "$CFG" || fail "баннер: нет автоматической проверки при открытии"
grep -q 'config-broken' "$CFG" || fail "нет баннера config-broken"

# повтор имени своей ноды: панель говорит, как нода переименована
grep -q 'переименованы' "$ROOT/web/stats_app_constructor_modules.js" || fail "нет сообщения о переименовании повторяющегося имени ноды"
grep -q 'renamed' "$ROOT/web/stats_app_constructor_modules.js" || fail "addPasted не собирает переименованные ноды"

# кнопки починки шаблоном - на панелях обоих режимов, а не в меню «Ещё»
grep -q "btn(row1, 'Миграция к шаблону'" "$CFG" || fail "YAML: «Миграция к шаблону» должна быть кнопкой панели"
grep -q "btn(row1, 'Заменить шаблоном…'" "$CFG" || fail "YAML: «Заменить шаблоном…» должна быть кнопкой панели"
grep -q "menuItem('Миграция к шаблону'" "$CFG" && fail "«Миграция к шаблону» осталась в меню «Ещё»"
grep -q "menuItem('Заменить шаблоном" "$CFG" && fail "«Заменить шаблоном…» осталась в меню «Ещё»"
grep -q "button('Миграция к шаблону'" "$UI" || fail "конструктор: нет кнопки «Миграция к шаблону»"
grep -q "button('Заменить шаблоном…'" "$UI" || fail "конструктор: нет кнопки «Заменить шаблоном…»"
grep -q "templateAction: templateActionFromConstructor" "$CFG" || fail "панель конструктора не получает templateAction"
[ "$(grep -c 'templateAction: opts.templateAction' "$UI")" = "$(grep -c 'renderConstructor(modeBar, {' "$UI")" ] || fail "перерисовка конструктора теряет templateAction"

# переключатель «куда попадают прокси» (ownscope) в разделе «Прокси»
M="$ROOT/web/stats_app_constructor_modules.js"
# базовые группы: тип, параметры и состав (вложенность)
for t in 'model.setMembers' 'model.resetBase' "'url-test'" "'fallback'" "'lazy'" 'Входят в группу' 'Вернуть как в шаблоне' 'Плюс закреплено'; do
  grep -q "$t" "$M" || fail "«Базовые группы»: нет $t"
done
grep -q 'baseOpen\[g.name\]' "$M" || fail "«Базовые группы»: группы не сворачиваются (аккордеон)"
grep -q "head.setAttribute('aria-expanded'" "$M" || fail "«Базовые группы»: у шапки группы нет aria-expanded"
grep -q 'setRoute(rt.name' "$M" || fail "«Базовые группы»: пропал выбор по умолчанию для сервисных групп"
grep -q 'model.setOwnScope' "$M" || fail "«Прокси»: нет переключателя ownscope"
grep -q 'model.ownScope()' "$M" || fail "«Прокси»: переключатель не читает состояние"
grep -q 'Только в базовые группы' "$M" || fail "«Прокси»: нет варианта «только в базовые группы»"
grep -q 'Ещё и во все сервисные группы' "$M" || fail "«Прокси»: нет варианта «во все сервисные группы»"
grep -q 'ch.proxies' "$UI" || fail "пометка «изменён» у «Прокси» не учитывает ownscope"

# Синтаксис ES-модулей (если есть node)
if command -v node >/dev/null 2>&1; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  for f in stats_app_constructor.js stats_app_constructor_model.js stats_app_constructor_modules.js stats_app_constructor_modules_model.js stats_app_settings.js stats_app_config.js; do
    cp "$ROOT/web/$f" "$T/${f%.js}.mjs"
    node --check "$T/${f%.js}.mjs" || fail "синтаксис $f"
  done
fi
# Поле «Адрес для проверки» (вкладка «Диагностика») в раскрытом сервисе.
grep -q 'Адрес для проверки' "$ROOT/web/stats_app_constructor.js" || fail "нет поля «Адрес для проверки» в редакторе сервиса"
grep -q 'model.setCheckUrl(' "$ROOT/web/stats_app_constructor.js" || fail "поле адреса проверки не сохраняет в модель"
grep -q 'model.defaultCheckUrls(' "$ROOT/web/stats_app_constructor.js" || fail "подсказка не показывает адрес по умолчанию"
grep -q 'serviceIconRow(s.id)' "$ROOT/web/stats_app_constructor.js" || fail "в раскрытом сервисе нет редактора иконки"
grep -q 'model.serviceIcon(id)' "$ROOT/web/stats_app_constructor.js" || fail "редактор не показывает текущую иконку"
grep -q 'model.setServiceIcon(id, iconIn.value.trim())' "$ROOT/web/stats_app_constructor.js" || fail "редактор не сохраняет новую иконку"
# Галочка «Блокировать QUIC» в раскрытом сервисе и пометка в строке сервиса.
grep -q 'Блокировать QUIC (UDP/443)' "$ROOT/web/stats_app_constructor.js" || fail "нет галочки «Блокировать QUIC» в редакторе сервиса"
grep -q 'model.setBlockQuic(id, cb.checked)' "$ROOT/web/stats_app_constructor.js" || fail "галочка QUIC не сохраняет в модель"
grep -q "model.blockQuic(s.id) ? ' · QUIC заблокирован'" "$ROOT/web/stats_app_constructor.js" || fail "строка сервиса не показывает блокировку QUIC"
echo "OK test_constructor_ui"
