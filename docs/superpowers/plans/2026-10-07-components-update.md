# Обновление компонентов (mihomo, zashboard, xkeen) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Карточка «Компоненты» в разделе «Обновления»: версии mihomo/zashboard/xkeen, автопроверка по расписанию проекта, обновление ядра и zashboard кнопкой.

**Architecture:** Новый CGI/CLI-модуль `web/stats_components.sh` (check / status / apply + фоновый воркер), маршруты в `stats_httpd.py`, вызов проверки из cron-ветки `stats_update.sh`, новый JS-модуль карточки. `update.sh` и манифест обновления проекта не меняются. Ядро и zashboard обновляются API mihomo (`POST /upgrade`, `POST /upgrade/ui`).

**Tech Stack:** POSIX sh (BusyBox на Keenetic), python3 (уже используется в тестах и httpd), ES-модули без сборки, тесты `tests/test_*.sh`.

**Spec:** `docs/superpowers/specs/2026-10-07-components-update-design.md`

## Global Constraints

- Только POSIX sh, без bash-измов; `set -eu`; переменные функций с префиксом (нет `local`), как в `stats_update.sh`.
- Тексты интерфейса и комментарии - по-русски, в стиле соседних файлов.
- Новые файлы регистрируются везде, где перечислены соседние (см. Task 3): иначе установщик и тесты установки их потеряют.
- Расписание проверки - то же, что у проекта (`UPDATE_CHECK_HOURS`); новой cron-строки и настроек нет.
- xkeen: только индикатор, кнопки обновления нет.
- Ошибка проверки компонентов никогда не валит проверку проекта и страницу (`|| true`, отдельное поле `error` у строки).
- Рабочий каталог проекта на роутере `/opt/etc/mihomo-speedtest`, конфиг `/opt/etc/mihomo/config.yaml`, ядро `/opt/sbin/mihomo`, xkeen `/opt/sbin/xkeen` (переопределяются `DIR`, `MIHOMO_DIR`, `BIN`, `XKEEN_BIN` как в `stats_config.sh`).

## Review Focus

- GitHub отвечает 403 (лимит), не-JSON или таймаутом: строка получает `error`, остальные строки и код выхода `check` не страдают.
- В конфиге нет `external-controller` или `secret` с кавычкой/обратным слэшем: строка «ядро не отвечает», без падения скрипта.
- `apply` во время применения конфига (замок `CONFIGEDIT_LOCK` занят) или второй `apply` параллельно: отказ `409 busy`, ничего не запущено.
- Установленная версия новее последней, пустая или нераспознанная (`xkeen -v` без номера): `available=false`, не ложное «есть обновление».
- Тег с префиксом `v`, alpha-сборка (`alpha-<sha>`), пустой ответ `/version`.
- `/upgrade` вернул успех, а версия не сменилась за таймаут (или ядро не поднялось): бинарник восстановлен, `xkeen -restart`, в логе «откат выполнен», job в `error`.

---

### Task 1: Проверка версий (`check`, `status`)

**Files:**
- Create: `web/stats_components.sh`
- Create: `tests/test_stats_components.sh`

**Interfaces:**
- Produces (CLI/CGI, действия через `MST_COMPONENTS_ACTION` или `$1`): `check [source]` - пишет `$STATS_UPDATE_RUNTIME_DIR/components.json` и печатает его; `status` - JSON `{"components":<components.json|null>,"job":<components-job.json|null>,"log":<строка|null>}`.
- Форма `components.json`: `{"schema_version":1,"checked_at":"YYYY-MM-DD HH:MM:SS","source":"cron|button","items":{"mihomo":ITEM,"zashboard":ITEM,"xkeen":ITEM}}`, где `ITEM = {"installed":str|null,"latest":str|null,"channel":"stable|alpha|null","available":bool,"can_apply":bool,"error":str|null}`; `can_apply` = false у xkeen.
- Тестовые крючки: `COMPONENTS_HTTP_CMD` - команда вместо `curl` (вызывается `$COMPONENTS_HTTP_CMD [-X POST] <url>`, печатает тело, ненулевой код = сбой); `GITHUB_API_BASE` (по умолчанию `https://api.github.com`); `XKEEN_RELEASES_REPO` (по умолчанию `jameszeroX/XKeen`, проверить в шаге 3, что у репозитория есть GitHub Releases; иначе взять `tags`).
- Внутренние функции: `api_init` (адрес и secret из `external-controller`/`secret` в `$CONFIG`, та же логика, что `main_api_init()` в `speedtest-runtime/speedtest2.sh:676`; secret - через файл curl-настроек 0600), `comp_http`, `latest_stable`, `latest_alpha`, `item_json`.

- [ ] **Step 1: Write the failing test.** `tests/test_stats_components.sh` в стиле `tests/test_stats_xkeen.sh` (mktemp, `fail`, `assert_contains`, заглушки в `$TMP/bin`). Заглушка `COMPONENTS_HTTP_CMD` отдаёт по подстроке URL фикстуру: `/version` -> `{"meta":true,"version":"v1.19.2"}`, `repos/MetaCubeX/mihomo/releases/latest` -> `{"tag_name":"v1.19.3"}`, `repos/Zephyruso/zashboard/releases/latest` -> `{"tag_name":"v2.6.0"}`, XKeen-репозиторий -> `{"tag_name":"v1.1"}`; заглушка `xkeen` печатает `XKeen 1.0`. Кейсы (имя -> проверка):
  - `stable_update`: `items.mihomo` = installed `v1.19.2`, latest `v1.19.3`, channel `stable`, available true, can_apply true.
  - `alpha_channel`: `/version` -> `alpha-abc1234`, релиз `Prerelease-Alpha` с ассетом `mihomo-linux-arm64-alpha-def5678.gz` -> channel `alpha`, latest `alpha-def5678`, available true; при одинаковом sha - available false.
  - `uptodate_and_newer`: installed >= latest или равна -> available false.
  - `xkeen_indicator`: installed `1.0`, latest `1.1`, available true, can_apply false.
  - `github_error_isolated`: заглушка возвращает код 22 для URL GitHub -> у каждой строки `error` непустой, `latest` null, процесс завершается кодом 0, `components.json` записан.
  - `core_down`: `/version` падает -> `items.mihomo.error` содержит «ядро не отвечает», `installed` null, остальные строки считаются.
  - `no_controller`: в конфиге нет `external-controller` -> то же «ядро не отвечает», без падения.
  - `bad_secret`: `secret: 'a"b'` -> то же, без падения.
  - `zashboard_unknown_installed`: нет маркера `$MIHOMO_DIR/zash/.mst-version` -> installed null, available false.
  - `status_nulls`: `status` без файлов -> `{"components":null,"job":null,"log":null}`.

- [ ] **Step 2: Run to verify it fails.** Run: `sh tests/test_stats_components.sh` -> Expected: FAIL (скрипта нет).

- [ ] **Step 3: Implement `web/stats_components.sh`** (`check`, `status`, CGI-диспетчер по образцу `stats_update.sh:509`: при `REQUEST_METHOD` - JSON-ответ с `Content-Type`, иначе CLI). Установленные версии: mihomo - поле `version` из `/version`; zashboard - содержимое `$MIHOMO_DIR/zash/.mst-version` (маркер пишет `apply`, Task 2); xkeen - первое `[0-9]+(\.[0-9]+)+` из `"$XKEEN_BIN" -v`. Последние: stable - `tag_name` из `releases/latest`; alpha (если установленная версия начинается с `alpha`) - `alpha-<sha>` из имени любого ассета релиза по тегу `Prerelease-Alpha`. `available` = обе версии известны, различаются после снятия ведущего `v`, и установленная не новее (для чисел вида `X.Y.Z` сравнить по полям; для alpha - просто «не равны»). JSON-строки экранировать так же, как `json_escape_line` в `stats_update.sh`. Запись `components.json` атомарно (tmp + `mv`).

- [ ] **Step 4: Run to verify it passes.** Run: `sh tests/test_stats_components.sh && sh -n web/stats_components.sh` -> Expected: все кейсы OK.

- [ ] **Step 5: Commit** `git add web/stats_components.sh tests/test_stats_components.sh && git commit -m "Компоненты: проверка версий mihomo/zashboard/xkeen"`.

### Task 2: Применение обновления (`apply`, фоновый воркер, откат)

**Files:**
- Modify: `web/stats_components.sh`
- Modify: `tests/test_stats_components.sh`

**Interfaces:**
- Consumes: `api_init`, `comp_http` из Task 1; библиотека `stats_config.sh` (`MST_CONFIG_LIB=1 . "$CONFIG_LIB"`, как в `web/stats_xkeen.sh:40`) для `CONFIGEDIT_LOCK`, `BIN`, `XKEEN_BIN`, `PIDOF_CMD`, `bounded`.
- Produces: действие `apply` (POST, `?name=mihomo|zashboard`) -> `{"started":true}` или `409 {"error":"busy"}`/`400 {"error":"unknown_component"}`; служебный `apply-worker <name>` (self-exec с очищенными `MST_COMPONENTS_ACTION=` и `REQUEST_METHOD=`, как `stats_update.sh:547`). Файлы `$STATS_UPDATE_RUNTIME_DIR/components-job.json` (`{"schema_version":1,"name":..,"state":"running|done|error","started_at":..,"finished_at":..|null,"error":str|null}`) и `components-job.log`. После успеха воркер сам перезапускает `check` (обновляет `components.json`). Тестовые переменные: `COMPONENTS_UPGRADE_WAIT` (секунды ожидания смены версии, по умолчанию 60).

- [ ] **Step 1: Write failing tests** (добавить в `tests/test_stats_components.sh`; заглушка `COMPONENTS_HTTP_CMD` ведёт журнал вызовов и состояние: `POST .../upgrade` меняет версию в `$TMP/state`, `POST .../upgrade/ui` создаёт `$TMP/mihomo/zash/index.html`):
  - `apply_zashboard_ok`: job `done`, лог содержит «zashboard обновлён», маркер `zash/.mst-version` равен последней версии, `xkeen -restart` не вызывался, `components.json` пересчитан (available false).
  - `apply_zashboard_empty_dir`: `/upgrade/ui` отработал, но каталог пуст -> job `error`.
  - `apply_mihomo_ok`: `mihomo -t` (заглушка `$TMP/bin/mihomo`) вызван до `POST /upgrade`; создан `$BIN.mst-bak`; версия сменилась -> job `done`, лог «ядро обновлено до».
  - `apply_mihomo_rollback`: `/upgrade` вернул успех, версия не сменилась за `COMPONENTS_UPGRADE_WAIT=2` -> `$BIN` восстановлен из `.mst-bak`, `xkeen -restart` вызван, лог содержит «откат выполнен», job `error`.
  - `apply_mihomo_config_invalid`: `mihomo -t` падает -> `/upgrade` не вызывался, job `error`, ядро не тронуто.
  - `apply_busy_lock`: `CONFIGEDIT_LOCK` занят живым pid -> ответ `409`, job не создан; второй `apply` при бегущем воркере -> `409`.
  - `apply_unknown_name`: `name=xkeen` и `name=foo` -> `400 unknown_component` (xkeen не обновляется).

- [ ] **Step 2: Run to verify they fail.** Run: `sh tests/test_stats_components.sh` -> Expected: новые кейсы FAIL.

- [ ] **Step 3: Implement `cmd_apply` и `cmd_apply_worker`.** `cmd_apply`: валидация имени, `take_lock` по образцу `stats_xkeen.sh:73` (то же сообщение об отказе, 409), запись job `running`, форк воркера, ответ `{"started":true}`. Воркер mihomo: `"$BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG"` -> `cp -p "$BIN" "$BIN.mst-bak"` -> `POST /upgrade` -> опрос `/version` каждые 2 с до смены версии или `COMPONENTS_UPGRADE_WAIT`; при провале `mv "$BIN.mst-bak" "$BIN"`, `bounded "$RESTART_TIMEOUT" "$XKEEN_BIN" -restart`, лог «откат выполнен». Воркер zashboard: `POST /upgrade/ui`, проверка `[ -n "$(ls -A "$MIHOMO_DIR/zash" 2>/dev/null)" ]`, запись маркера `.mst-version`. В конце - снять замок (`rm -rf "$CONFIGEDIT_LOCK"`), `check` без вывода, job `done`/`error` (`finished_at`). Каждый этап - строка в `components-job.log`.

- [ ] **Step 4: Run to verify they pass.** Run: `sh tests/test_stats_components.sh` -> Expected: все кейсы OK.

- [ ] **Step 5: Commit** `git commit -am "Компоненты: обновление ядра и zashboard с откатом"` (файлы из Task 2).

### Task 3: Подключение: маршруты, cron, регистрация файлов

**Files:**
- Modify: `web/stats_httpd.py` (`API_ROUTES` ~стр. 494, карта статики ~стр. 464)
- Modify: `web/stats_update.sh:598` (ветка `check)` CLI)
- Modify: `install.sh:29` (`ALL_PROJECT_FILES`) и блок `atomic_install` ~стр. 1105
- Modify: `uninstall.sh:81-82` (список файлов)
- Modify: `release/components.txt` (две строки `FILE|web|...`)
- Modify: `tests/test_install.sh` (три списка `cp`, стр. ~443, ~691, ~881), `tests/test_install_bootstrap.sh:13`
- Test: `tests/test_stats_httpd_py.sh`, `tests/test_stats_update.sh`, `tests/test_update_check_cron.sh`, `tests/test_install.sh`, `tests/test_install_bootstrap.sh`, `tests/test_generate_manifest.sh`

**Interfaces:**
- Produces: `api/components/check` (POST, `MST_CGI_TIMEOUT` 60), `api/components/status` (GET), `api/components/apply` (POST) -> `stats_components.sh` с `MST_COMPONENTS_ACTION=check|status|apply`; статика `app-components.js` -> `stats_app_components.js` (файл создаётся в Task 4, здесь в манифесте и списках объявляется заранее; чтобы тесты не падали между задачами, создать пустой модуль-заглушку `export {};` и заменить его в Task 4).

- [ ] **Step 1: Write failing tests.** В `tests/test_stats_update.sh`: CLI `check` вызывает `stats_components.sh check cron`, а падение компонентов (`exit 1`) не меняет код выхода `check`. В `tests/test_stats_httpd_py.sh`: три маршрута присутствуют, `app-components.js` раздаётся. Остальные тесты (`test_install*`, `test_generate_manifest`) уже падают при несовпадении списков - прогнать их после правок.

- [ ] **Step 2: Run to verify the new cases fail.** Run: `sh tests/test_stats_update.sh; sh tests/test_stats_httpd_py.sh` -> Expected: новые проверки FAIL.

- [ ] **Step 3: Implement.** Маршруты и статика - по образцу соседних записей. `stats_update.sh`: в CLI-ветке `check)` после `cmd_check` добавить `[ -f "$DIR/stats_components.sh" ] && ( MST_COMPONENTS_ACTION= REQUEST_METHOD= sh "$DIR/stats_components.sh" check cron >/dev/null 2>&1 || true )` (внутри `set -e` обязательно `|| true`). Регистрация `stats_components.sh` (0755, `sh`) и `stats_app_components.js` (0644, `none`) во всех перечисленных списках.

- [ ] **Step 4: Run to verify.** Run: `for t in test_stats_update test_stats_httpd_py test_update_check_cron test_install test_install_bootstrap test_generate_manifest test_uninstall; do sh tests/$t.sh || echo FAIL $t; done` -> Expected: без FAIL.

- [ ] **Step 5: Commit** `git commit -am "Компоненты: маршруты, cron-проверка, регистрация файлов"` (с новыми файлами).

### Task 4: UI: карточка «Компоненты», бейдж и плитка

**Files:**
- Modify: `web/stats_app_components.js` (заменить заглушку)
- Modify: `web/stats_app_updates.js` (`renderUpdates`, `refreshUpdatesBadge` стр. 15-35)
- Modify: `web/stats_style.css` (только если нужны новые классы; по возможности использовать `update-console`, `hint`, `submit`)
- Test: `tests/test_stats_updates_ui.sh`, `tests/test_stats_update_badge_recheck.sh`

**Interfaces:**
- Consumes: `/api/components/check`, `/api/components/status`, `/api/components/apply` (Task 1-3); хелперы из `app-core.js` (`card`, `el`, `fetchJson`, `showFormMessage`).
- Produces: `export function componentsAvailable(data)` -> `true`, если в ответе `/api/components/status` есть `components.items.*.available`; `export function buildComponentsCard(onChanged)` -> элемент карточки с таблицей из трёх строк (установлено / доступно / статус), кнопкой «Обновить» у mihomo и zashboard (`confirm` перед запуском; для mihomo текст предупреждает о коротком перерыве прокси), опросом `status` каждые 2 с с мини-консолью (как `renderUpdatesProgress`), у xkeen - подпись «обновление вручную: xkeen -uxk» вместо кнопки (уточнить флаг по `xkeen -h`, если доступен, иначе оставить текст без флага), кнопкой «Проверить сейчас» (`POST /api/components/check`).

- [ ] **Step 1: Write failing tests** по образцу `tests/test_stats_updates_ui.sh` (как там проверяется JS - так же): `componentsAvailable` истинна при `available`, ложна при `null`/ошибках; карточка рисует три строки, у xkeen нет кнопки, у строки с `error` виден текст ошибки; `refreshUpdatesBadge` показывает бейдж и `kpi-danger`, если доступно обновление только компонента (при этом проект актуален).

- [ ] **Step 2: Run to verify they fail.** Run: `sh tests/test_stats_updates_ui.sh; sh tests/test_stats_update_badge_recheck.sh` -> Expected: новые проверки FAIL.

- [ ] **Step 3: Implement** модуль и подключение: в `renderUpdates()` добавить `buildComponentsCard` после карточки «Обновления»; в `refreshUpdatesBadge` запрашивать `/api/components/status` параллельно и объединять `available` (одна формула на бейдж и плитку, как требует комментарий в файле). Сетевая ошибка запроса компонентов не должна скрывать бейдж проекта.

- [ ] **Step 4: Run to verify.** Run: `for t in test_stats_updates_ui test_stats_update_badge_recheck test_stats_view_guard test_ui_no_raw_echo; do sh tests/$t.sh || echo FAIL $t; done` -> Expected: без FAIL.

- [ ] **Step 5: Commit** `git commit -am "Компоненты: карточка в разделе «Обновления», бейдж и плитка"`.

### Task 5: Документация и общий прогон

**Files:**
- Modify: `docs/guide.md` (раздел про `/updates`, рядом со стр. ~628-660), `README.md` (список возможностей веб-панели)

- [ ] **Step 1: Document.** В `docs/guide.md`: что показывает карточка, откуда берутся версии, как выбирается канал mihomo, что xkeen - только индикатор, что обновление ядра кратко прерывает прокси и откатывается при неудаче, расписание = `UPDATE_CHECK_HOURS`. В `README.md` - одна строка в «Веб-панель».

- [ ] **Step 2: Full run.** Run: `for t in tests/test_*.sh; do sh "$t" >/dev/null 2>&1 || echo FAIL $t; done` -> Expected: ни одного FAIL (если часть тестов падала до изменений - сверить с `git stash`).

- [ ] **Step 3: Commit and push** `git commit -am "Документация: обновление компонентов" && git push -u origin dev`.
