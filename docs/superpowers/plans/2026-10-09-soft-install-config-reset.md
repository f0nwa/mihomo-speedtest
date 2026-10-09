# Мягкая установка и замена конфига шаблоном: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Миграция не создаёт правила на несуществующие группы, конфиг можно заменить шаблоном, оставив подписки и ноды, а установка не падает из-за конфига.

**Architecture:** Три этапа. Этап 1 правит `config_to_state.awk` и сохранение состояния конструктора. Этап 2 добавляет `reset_config.sh` поверх `constructor_build.sh --state` и действия в `stats_constructor.sh` и веб-интерфейсе. Этап 3 меняет `setup.sh` и `install.sh` (мягкий режим).

**Tech Stack:** POSIX sh и awk (busybox на роутере, функции объявляются до первого вызова, вызов без пробела перед скобкой), CGI на sh, ванильный JS, тесты `tests/test_*.sh`.

**Spec:** `docs/superpowers/specs/2026-10-09-soft-install-config-reset-design.md`

## Global Constraints

- awk должен работать в busybox: функции объявлены до первого вызова, вызов пишется `имя(` без пробела.
- Значения конфига (ссылки подписок, пароли) не попадают в отчёты и сообщения: только имена и номера.
- Файлы кандидата и отчёта лежат в `/tmp` (требование `migrate_config.sh`).
- Новый файл `config-tools/reset_config.sh` регистрируется в `release/components.txt` (по образцу строки `constructor_build.sh`), в `PROJECT_TOOLS` и `ALL_PROJECT_FILES` в `install.sh`, в списке `uninstall.sh:84`.
- Проверки версий XKeen, mihomo, KeeneticOS остаются жёсткими.
- Коммиты идут прямо в `dev`, PR не создаётся. Концовка сообщения коммита: пустая строка, затем `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` и `Claude-Session: https://claude.ai/code/session_013pzmJWbqxij8mbtrJzsTZL`.
- Тексты для пользователя на русском, по стилю соседних сообщений.

## Review Focus

- Группа пользователя типа `url-test` или `select` с собственным `proxies:`: в состояние не должны попасть её `type:`/`proxies:` как `gkey`, иначе они перебьют `select-default` (Задача 1).
- Правило с целью `⚙️Manual # комментарий` или `…,no-resolve` после перенаправления сохраняет форму (Задача 1).
- Источник замены с `proxy-providers:` без подписок, `type: file` и `fast` (Задача 3).
- Заменяемый конфиг без единой подписки и ноды: отказ, конфиг не тронут (Задача 4).
- `mihomo -t` падает в мягкой установке: код возврата 0, пробный прогон пропущен, веб-панель поднята (Задача 7).

---

## Этап 1. Миграция

### Task 1: Группы пользователя становятся сервисами, правила без цели перенаправляются

**Files:**
- Modify: `config-tools/config_to_state.awk:235-279` (блоки «Свои группы» и «Правила»)
- Test: `tests/test_config_to_state.sh`

**Interfaces:**
- Produces: в `services.tsv` каждая группа вне базовых групп шаблона и вне встроенных сервисов даёт `svc<TAB>id<TAB>Имя<TAB>other`; отчёт `REVIEW|custom-group-pool|Имя` для группы без `<<: *select-default`; `REVIEW|rule-retargeted|N` (N — номер правила в `rules:`). В `user-rules.txt` нет правил с несуществующей целью.

- [ ] **Step 1: Обновить существующий тест и добавить новые** в `tests/test_config_to_state.sh`.
  - В блоке `test_import_custom_service` строка с `Mine` теперь даёт сервис: ожидаемый `services.tsv` содержит `svc\tmine\tMine\tother` после `icon\tnetflix…`, а проверка `REVIEW|custom-group|Mine` заменяется на `REVIEW|custom-group-pool|Mine`.
  - Новый блок `test_import_orphan_rules`. Конфиг: группы `FaceTime` (`type: select`, `proxies: [DIRECT]`), `🚀Auto-Best` (`type: url-test`), `"A, B"` (`<<: *select-default`); правила `DOMAIN-SUFFIX,facetime.apple.com,FaceTime`, `AND,((NETWORK,UDP),(DST-PORT,3478-3497)),FaceTime`, `DOMAIN-SUFFIX,xhamster.com,🚀Auto-Best`, `GEOSITE,foo,Ghost` (группы `Ghost` нет нигде) и `OR,((DOMAIN-SUFFIX,gql.twitch.tv),(DOMAIN-SUFFIX,usher.ttvnw.net)),⚙️Manual # хвост` (в шаблон теста `$T` добавить базовую группу `⚙️Manual`). Группа `"A, B"` правил не имеет, её проверяют только отчётом `custom-group-name`.
  - Ожидания: `services.tsv` содержит `svc\tfacetime\tFaceTime\tother` и `svc\tsvc1\t🚀Auto-Best\tother` (id из `new_id`), и не содержит строк `gkey`; `dom\tfacetime\tsuffix\tfacetime.apple.com`; `user-rules.txt` содержит `AND,((NETWORK,UDP),(DST-PORT,3478-3497)),FaceTime` без изменений и `GEOSITE,foo,DIRECT` (в шаблоне теста нет `🚀 Авто по пингу`, запасная цель — `DIRECT`); правило с `⚙️Manual` не тронуто; отчёт содержит `REVIEW|custom-group-pool|FaceTime`, `REVIEW|custom-group-pool|🚀Auto-Best`, `REVIEW|rule-retargeted|`, а группа `A, B` по-прежнему даёт `REVIEW|custom-group-name`.
  - Хелпер `dangling_targets FILE`: печатает цели правил из `rules:` собранного конфига, которых нет среди имён `proxy-groups`, `DIRECT`, `REJECT`, `REJECT-DROP`, `PASS`, `COMPATIBLE`. После `build "$WORK/st/services.tsv" '' "$WORK/st/user-rules.txt"` его вывод пуст.

- [ ] **Step 2: Запустить тест, убедиться, что он падает**

Run: `sh tests/test_config_to_state.sh`
Expected: FAIL (в отчёте нет `custom-group-pool`, `user-rules.txt` содержит правило на `Ghost`).

- [ ] **Step 3: Реализовать в `config_to_state.awk`**
  - В цикле «Свои группы» убрать `continue` на `!gr_select[i]`: группа без `<<: *select-default` теперь создаёт сервис, отчёт `REVIEW|custom-group-pool|имя`. Для такой группы `gkey` не пишутся (ни однострочные, ни `type:`/`proxies:`), `icon` переносится как у остальных.
  - Определить `function retarget(b, to,  n, f, k, i, out)` (объявить выше первого вызова): разбивает `b` по `,`, заменяет цель (`n-1`-е поле, если последнее `no-resolve`, иначе последнее), склеивает обратно.
  - Перед циклом правил собрать множество допустимых целей `ok_target`: `base_group`, имена встроенных сервисов с неудалённым id, `custom_id`, имена статических нод (в блоке `sect == "proxies"` ловить `^  - name:` в массив `prox_name`), ключевые слова `DIRECT REJECT REJECT-DROP PASS COMPATIBLE`, имена вида `FAST-WG …`.
  - Запасная цель `fb`: `🚀 Авто по пингу`, если она есть в `base_group`, иначе `DIRECT`.
  - В ветке, где правило уходит в `user_out`: если `tg` не в `ok_target`, `b = retarget(b, fb)` и `rep("REVIEW", "rule-retargeted|" i)`.

- [ ] **Step 4: Запустить тесты этапа**

Run: `sh tests/test_config_to_state.sh && sh tests/test_constructor_build.sh && sh tests/test_migrate_config.sh`
Expected: все три печатают OK (или пустой вывод и код 0, как принято в файле).

- [ ] **Step 5: Commit** (`git add config-tools/config_to_state.awk tests/test_config_to_state.sh`, сообщение «Конструктор: группы пользователя - сервисы, правила без цели перенаправляются»).

### Task 2: Состояние сохраняется после «Миграции к шаблону»

**Files:**
- Modify: `web/stats_config.sh` (добавить `persist_state`, расширить `after_apply_ok` у строки ~414; объявить `CONSTRUCTOR_DEFAULTS`, `CONFIG_TO_STATE_AWK` рядом с `CONSTRUCTOR_BUILD` у строки 54)
- Modify: `web/stats_constructor.sh:144-166` (`after_apply_ok` вызывает `persist_state`)
- Test: `tests/test_stats_config.sh`

**Interfaces:**
- Produces: `persist_state STATE_DIR` — копирует файлы состояния в `$CONFIG_STATE_DIR` (тот же порядок `.new`/`.old`, что сейчас в конструкторе, плюс пустой `services.tsv` и `managed.sig`), возвращает 0 при успехе и 1 при сбое, пишет в журнал через `alog`. `after_apply_ok` в `stats_config.sh`, когда состояния нет и в запросе есть `?schema=N`: импортирует применённый конфиг (`config_to_state.awk`), собирает его обратно (`constructor_build.sh --state`), и если `managed_sig` собранного совпал с применённым, вызывает `persist_state`.

- [ ] **Step 1: Написать падающий тест** в `tests/test_stats_config.sh` по образцу существующих `save`-проверок: состояния нет, `save?schema=1` с текстом, собранным шаблоном, после успеха существуют `$CONFIG_STATE_DIR/services.tsv` и `managed.sig`; `save` без `schema` состояние не создаёт; текст, не совпавший со сборкой, состояние не создаёт.

- [ ] **Step 2: Запустить**, убедиться, что падает.

Run: `sh tests/test_stats_config.sh`
Expected: FAIL на проверке наличия `services.tsv`.

- [ ] **Step 3: Реализовать.** Вынести тело записи состояния из `stats_constructor.sh:after_apply_ok` в `persist_state` (без вызова `sync_block`, он остаётся в конструкторе). В `stats_config.sh:after_apply_ok` добавить ветку «нет состояния + `query_param schema` непустой». Любой сбой — `alog "WARN: …"` и `return 0`.

- [ ] **Step 4: Запустить**

Run: `sh tests/test_stats_config.sh && sh tests/test_stats_constructor.sh`
Expected: OK (apply конструктора по-прежнему сохраняет состояние).

- [ ] **Step 5: Commit** («Конфиг: состояние конструктора сохраняется после миграции к шаблону»).

---

## Этап 2. Замена шаблоном

### Task 3: `reset_config.sh`

**Files:**
- Create: `config-tools/reset_config.sh`
- Modify: `config-tools/config_to_state.awk` (в `flush_sub`: `rep("REVIEW", "file-provider-dropped|" имя)` для `type: file`, кроме `fast`)
- Modify: `release/components.txt`, `install.sh` (`PROJECT_TOOLS`, `ALL_PROJECT_FILES`), `uninstall.sh:84`
- Test: `tests/test_reset_config.sh` (новый)

**Interfaces:**
- Produces: `sh reset_config.sh --source FILE --output OUT --report REPORT --state-out DIR`. Код 0: `OUT` — кандидат, `REPORT` — строки `RESET|kept-subscriptions|N`, `RESET|kept-nodes|M` и строки отчёта импорта; `DIR` (создаётся скриптом, внутри `/tmp`) — состояние: `subscriptions.tsv`, `proxies.yaml`, пустой `services.tsv`. Код 1: `ERROR: …` в stderr, `OUT` не создаётся. Если подписок и нод нет, скрипт завершается с `ERROR: нет ни подписок, ни нод - заменять нечем` (код 1, вывод `OUT` не создаётся).

- [ ] **Step 1: Написать тест** `tests/test_reset_config.sh` (по образцу `test_constructor_build.sh`: рабочий каталог в `/tmp`, инструменты копируются в каталог рядом). Случаи:
  - источник с двумя подписками (одна с `header: User-Agent`), двумя нодами, `dns:`, `listeners:`, `secret:`, своими группами и правилами: `OUT` содержит обе подписки с User-Agent и обе ноды, не содержит `dns:`, `secret:` и своих групп и правил (`grep -c`), `REPORT` содержит `RESET|kept-subscriptions|2` и `RESET|kept-nodes|2`; `DIR/services.tsv` существует и пуст;
  - источник проходит построчный разбор, но не проходит `mihomo -t` (правило на несуществующую группу): результат тот же, код 0;
  - `type: file` провайдер и `fast`: в `OUT` их нет, `REPORT` содержит `REVIEW|file-provider-dropped|имя` для `type: file`;
  - источник без подписок и нод: код 1 и `нет ни подписок, ни нод`, `OUT` не создан;
  - источник отсутствует или больше 1 МиБ: код 1.

- [ ] **Step 2: Запустить**, убедиться, что падает (скрипта нет).

Run: `sh tests/test_reset_config.sh`
Expected: FAIL (`reset_config.sh: not found`).

- [ ] **Step 3: Реализовать.** Скрипт по стилю `constructor_build.sh` (`set -eu`, `umask 077`, `fail()`, RAM-каталог, `trap`). Шаги: импорт `config_to_state.awk` во временный каталог, оставить только `subscriptions.tsv` и `proxies.yaml`, дописать пустой `services.tsv`, посчитать подписки (строки `subscriptions.tsv`) и ноды (`grep -c '^  - name:' proxies.yaml`), заглушка `proxy-providers:` как `--source`, `sh constructor_build.sh --state … --source STUB --output OUT --report REPORT`. Состояние копируется в `--state-out`.

- [ ] **Step 4: Зарегистрировать файл** (три списка из Global Constraints) и запустить

Run: `sh tests/test_reset_config.sh && sh tests/test_install.sh && sh tests/test_uninstall.sh`
Expected: OK.

- [ ] **Step 5: Commit** («Замена конфига шаблоном: reset_config.sh»).

### Task 4: Действия `reset-preview` и `reset` в CGI конструктора

**Files:**
- Modify: `web/stats_constructor.sh` (два новых `case`; документация в шапке)
- Modify: `web/stats_httpd.py:529-537` (два маршрута)
- Test: `tests/test_stats_constructor.sh`

**Interfaces:**
- Consumes: `reset_config.sh` (Задача 3), `persist_state` и `apply_candidate` (Задача 2, существующий).
- Produces: `POST /api/constructor/reset-preview`: `{"ok":true,"text":…,"report":[…],"check":…,"kept":{"subscriptions":N,"nodes":M}}`; `POST /api/constructor/reset?base=…`: применяет через `apply_candidate` с `NEW_STATE` (бэкап, `mihomo -t`, откат). Нет конфига: 404 `no_config`; нет подписок и нод: 422 `nothing_to_keep`; `reset_config.sh` не найден: 500 `no_tools`.

- [ ] **Step 1: Написать падающие тесты** в `tests/test_stats_constructor.sh` по образцу `apply`: `reset-preview` на битом конфиге возвращает `ok`, `kept`, `check`; `reset` пишет новый `config.yaml` без чужих групп, создаёт бэкап и состояние (`services.tsv` пуст), при падении `mihomo -t` конфиг не тронут; конфиг без подписок и нод даёт 422 `nothing_to_keep`; конфига нет даёт 404.

- [ ] **Step 2: Запустить**, убедиться, что падает.

Run: `sh tests/test_stats_constructor.sh`
Expected: FAIL (405 `method_not_allowed`).

- [ ] **Step 3: Реализовать.** Общая функция `build_reset_candidate` (по образцу `build_candidate`): определяет `target`, вызывает `reset_config.sh --source "$target" --output "$WORK/cand.yaml" --report "$WORK/report" --state-out "$WORK/state"`, `ERROR: …` превращает в `fail_json 422 reset_failed` (сообщение «нет ни подписок…» — в `nothing_to_keep`). Маршруты в `stats_httpd.py`: `reset-preview` (`MST_CGI_TIMEOUT` 60) и `reset` (180).

- [ ] **Step 4: Запустить**

Run: `sh tests/test_stats_constructor.sh`
Expected: OK.

- [ ] **Step 5: Commit** («Конструктор: действия reset-preview и reset»).

### Task 5: Веб-интерфейс: «Заменить шаблоном» и баннер

**Files:**
- Modify: `web/stats_app_config.js` (меню «Починка» у строки ~448; баннер при непроходящем конфиге; обработчик у строки ~915)
- Test: `tests/test_constructor_ui.sh` (grep-проверки)

**Interfaces:**
- Consumes: `POST /api/constructor/reset-preview`, `POST /api/constructor/reset?base=…` (Задача 4), существующие `postText`, `fetchConfigJson`, `msg`, `busy`, `clearOutput`.
- Produces: пункт меню «Заменить шаблоном, оставив подписки и ноды…», функция `resetFromTemplate()` (предпросмотр показывает «Останется: N подписок, M нод», отчёт и кнопку «Применить»), баннер `renderBrokenBanner()` над редактором, если автоматическая проверка (`/api/config/check` один раз при открытии) не прошла: три кнопки «Починить», «Миграция к шаблону», «Заменить шаблоном…».

- [ ] **Step 1: Добавить проверки** в `tests/test_constructor_ui.sh`: `grep -q '/api/constructor/reset-preview' "$CFG"`, `grep -q '/api/constructor/reset?base=' "$CFG"`, `grep -q 'Заменить шаблоном' "$CFG"`, `grep -q 'renderBrokenBanner' "$CFG"`.

- [ ] **Step 2: Запустить**, убедиться, что падает.

Run: `sh tests/test_constructor_ui.sh`
Expected: FAIL на первой новой проверке.

- [ ] **Step 3: Реализовать** меню, диалог (подтверждение, потом применение, как у `tplBtn`), баннер. После применения редактор перезагружается так же, как после `restore`. Правки в редакторе с `view.dirty` спрашивают подтверждение, как у `workBtn`.

- [ ] **Step 4: Запустить**

Run: `sh tests/test_constructor_ui.sh && node --check web/stats_app_config.js`
Expected: OK, `node --check` без вывода.

- [ ] **Step 5: Commit** («Веб-интерфейс: замена шаблоном и баннер при битом конфиге»).

---

## Этап 3. Мягкая установка

### Task 6: Мастер `setup.sh`: без терминала и при непройденных подписках

**Files:**
- Modify: `config-tools/setup.sh:95-122` (`collect_subscriptions`) и `:380-395` (ветка «Ни одна подписка не прошла проверку»)
- Test: `tests/test_setup.sh` (заменить проверку на строке ~840)

**Interfaces:**
- Produces: конец ввода без терминала: `SETUP_SKIPPED=1`, конфиг без нод, код 0 (раньше отказ после трёх попыток). Ни одна подписка не прошла проверку: при `SETUP_SOFT_EMPTY` (по умолчанию «да», Enter или конец ввода) мастер собирает конфиг без нод, при «n» завершается как раньше.

- [ ] **Step 1: Обновить тесты.** Сценарий `WORK9` (конец ввода, ждёт «Нужна хотя бы одна ссылка») теперь ожидает конфиг без нод и код 0. Новый сценарий: подписка не проходит проверку, на вопрос «Собрать конфиг без нод и продолжить?» ответ Enter даёт конфиг без нод; ответ `n` даёт прежний отказ «Ни одна подписка не прошла проверку».

- [ ] **Step 2: Запустить**, убедиться, что падает.

Run: `sh tests/test_setup.sh`
Expected: FAIL (прежнее поведение).

- [ ] **Step 3: Реализовать** в `collect_subscriptions` убрать счётчик попыток (`attempt`) и `ui_fail "Нужна хотя бы одна…"`: при `read_eof=1` и `n=0` выставить `SETUP_SKIPPED=1; break`. В `main` перед `ui_fail "Ни одна подписка не прошла проверку…"` спросить через `ui_ask` (по умолчанию да) и перейти в ветку `no_nodes=1`.

- [ ] **Step 4: Запустить**

Run: `sh tests/test_setup.sh`
Expected: OK.

- [ ] **Step 5: Commit** («Мастер настройки: без подписки конфиг собирается без нод»).

### Task 7: Мягкая установка в `install.sh`

**Files:**
- Modify: `install.sh` (`choose_config_mode` у строки 1546, `resolve_config_mode` у 1706, `main` у 1912-1921, сводка у 2037-2039; новая `reset_to_template` рядом с `migrate_to_template`; новая `broken_config_notice`)
- Test: `tests/test_install_config_mode.sh`, `tests/test_install.sh`

**Interfaces:**
- Consumes: `reset_config.sh` (Задача 3); существующие `config_target`, `replace_config_file`, `restart_core_and_wait`, `print_migration_report`, `ui_menu`, `ui_ask`.
- Produces: `reset_to_template` с теми же кодами возврата, что у `migrate_to_template` (0 — готово, 1 — конфиг не тронут, 2 — ядро не поднялось и на прежнем конфиге); `CONFIG_MODE=reset` (значения `template|own|reset`); `choose_config_mode` показывает меню из трёх пунктов (умолчание прежнее — свой); `MST_SOFT_CONFIG=1` при конфиге, не проходящем `mihomo -t`; `broken_config_notice` — жёлтый блок перед сводкой.

- [ ] **Step 1: Написать тесты.**
  - `tests/test_install_config_mode.sh`: `CONFIG_MODE=reset` заменяет конфиг шаблоном, подписки и ноды сохранены, бэкап рядом, `xkeen -restart` вызван; меню принимает `3` как «заменить»; Enter по-прежнему «свой».
  - `tests/test_install.sh`: `FAKE_MIHOMO_RC=1` (`mihomo -t` падает) и пустой ввод: код возврата 0, в выводе жёлтый блок с причиной, `speedtest2.sh` не запускался, init-скрипт веб-панели вызван.
  - Меню битого конфига: ввод `2` (заменить) вызывает `reset_to_template`; если замена не удалась, установка продолжается и завершается кодом 0.

- [ ] **Step 2: Запустить**, убедиться, что падает.

Run: `sh tests/test_install_config_mode.sh && sh tests/test_install.sh`
Expected: FAIL.

- [ ] **Step 3: Реализовать.**
  - `reset_to_template`: по образцу `migrate_to_template`, но кандидат строит `reset_config.sh`, а отчёт печатает `print_migration_report`, дополненный строками `RESET|kept-subscriptions|N`/`RESET|kept-nodes|M` («останется: N подписок, M нод»).
  - `choose_config_mode`: третий пункт; `CONFIG_MODE_CHOSEN` принимает `reset`.
  - `resolve_config_mode`: ветка `reset` вызывает `reset_to_template` с теми же правилами кодов.
  - `main`: вместо `ui_fail … return 1` при непроходящем `mihomo -t` показать меню из трёх пунктов (мигрировать, заменить, оставить как есть; Enter и отсутствие терминала — оставить). Результат выбора, кроме «ядро не поднялось» (код 2), не прерывает установку. Если конфиг остаётся битым, `MST_SOFT_CONFIG=1`, `NO_NODES=1`-путь: разбор провайдеров, пробный прогон и запуск ядра пропускаются, `BLOCK` берётся из `speedtest2.env` или значения по умолчанию.
  - `broken_config_notice`: причина (первая строка вывода `mihomo -t` из журнала), «веб-интерфейс → Конфиг», три действия.

- [ ] **Step 4: Запустить**

Run: `sh tests/test_install_config_mode.sh && sh tests/test_install.sh && sh tests/test_install_bootstrap.sh`
Expected: OK.

- [ ] **Step 5: Commit** («Установка: конфиг не останавливает установку, замена шаблоном»).

### Task 8: Документация

**Files:**
- Modify: `docs/guide.md` (раздел про установку и конфиг: три пункта меню, `CONFIG_MODE=reset`, мягкий режим, кнопка в панели)
- Modify: `README.md` (одна строка про мягкую установку)

- [ ] **Step 1: Дополнить документацию** описанием: что остаётся при замене шаблоном, что теряется, где бэкап; поведение установки без терминала и с битым конфигом.
- [ ] **Step 2: Прогнать весь набор**

Run: `for t in tests/test_*.sh; do sh "$t" >/dev/null 2>&1 || echo "FAIL $t"; done`
Expected: нет строк `FAIL`.

- [ ] **Step 3: Commit** («Документация: мягкая установка и замена шаблоном»).
