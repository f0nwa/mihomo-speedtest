# Файловый менеджер веб-панели - план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Вкладка «Файлы» (дерево + список + редактор, вариант B) с доступом от корня `/`, одинаково на mipsel и aarch64.

**Architecture:** Чистый модуль `web/stats_files.py` (без HTTP) делает всю работу с ФС и проверки безопасности; `stats_httpd.py` только маршрутизирует `/api/fm/*` в него, отдаёт и принимает файлы потоком; фронтенд - отдельный модуль `web/stats_app_files.js` по образцу `stats_app_xkeen.js`.

**Tech Stack:** python3 stdlib (3.7+), sh-тесты в стиле `tests/test_stats_*.sh`, ES-модули без сборки, готовый CodeMirror (`codemirror.js`).

**Spec:** `docs/superpowers/specs/2026-10-07-web-file-manager-design.md`. Макет: https://claude.ai/artifact/BduRjMW3Q7796NSzcQ6ZiG (артборд B).

## Global Constraints

- Только стандартная библиотека python3, без бинарей и новых зависимостей; код должен работать на Python 3.7+.
- Единственный корень `/`; пути в API абсолютные; нулевой байт и относительные пути - отказ.
- Изменяющие запросы (POST/PUT/DELETE) уже требуют `X-CSRF-Token` в `_authorize()`; новые маршруты проходят через неё без исключений.
- Чтение/скачивание - только обычные файлы (S_ISREG); текст для редактора - до 1 МиБ.
- Защищённые пути (нельзя удалить/переименовать): `/`, `/bin`, `/sbin`, `/lib`, `/etc`, `/opt`, `/proc`, `/sys`, `/dev` и точки монтирования из `/proc/mounts`.
- Рекурсивное удаление только с `recursive=true` и `confirm=<тот же путь>`.
- Файлы панели (`$DIR/stats_auth*`, каталог `STATS_AUTH_STATE_DIR`) - только на чтение.
- Загрузка и скачивание потоком блоками 64 КиБ; запись атомарно (`*.part` + `rename`, правка текста - с `.bak`).
- Комментарии и тексты интерфейса - на русском, как в остальном коде.

## Review Focus

- Битая ссылка и ссылка на каталог в списке: показывается как `link`, не падает; удаление ссылки удаляет ссылку, а не цель (Task 2).
- Огромный каталог (`/proc`, `/var/log`): список режется лимитом 2000 записей с флагом `truncated` (Task 1).
- Имя файла с не-UTF-8 байтами или переводом строки: не ломает JSON (Task 1).
- Загрузка с именем `../x` или `a/b`: отказ, файл вне каталога не создаётся (Task 2).
- Обрыв загрузки или нехватка места: не остаётся `*.part`, целевой файл не изменён (Task 2).
- Переименование поверх существующего файла: отказ 409, без потери данных (Task 2).

---

### Task 1: Пути, защита, список, дерево, чтение

**Files:**
- Create: `web/stats_files.py`
- Create: `tests/test_stats_files.sh` (вызывает `tests/stats_files_check.py` через `python3 -I`)
- Create: `tests/stats_files_check.py` (unittest)

**Interfaces:**
- Produces:
  - `class FileError(Exception)`: поля `status: int`, `code: str`.
  - `normalize(path: str) -> str` - абсолютный нормализованный путь; `FileError(400,"bad_path")` для относительного, пустого, с `\0`.
  - `is_protected(path: str, mounts_file: str = "/proc/mounts") -> bool`
  - `is_readonly(path: str) -> bool` - файл панели (из `FM_READONLY` и `STATS_AUTH_STATE_DIR`).
  - `list_dir(path: str, show_hidden: bool = False, limit: int = 2000) -> dict` -> `{"path", "entries": [{"name","type","size","mtime","mode","link"}], "truncated": bool}`; `type` один из `dir|file|link|other`; `.bak` и `.part` скрыты без `show_hidden`; сначала каталоги, затем файлы, по имени.
  - `tree(path: str) -> list` - имена подкаталогов (для ленивого дерева).
  - `read_text(path: str, limit: int = 1048576) -> dict` -> `{"content","mtime","size","readonly"}`; `FileError(415,"not_text")` для бинарных (есть `\0` в первых 8 КиБ или не UTF-8), `FileError(413,"too_large")`, `FileError(415,"not_regular")`.

- [ ] **Step 1: Write failing tests** в `tests/stats_files_check.py` (unittest, временный каталог): `test_normalize_rejects_relative_and_nul`, `test_normalize_collapses_dotdot` (`/a/../b` -> `/b`), `test_protected_paths` (`/`, `/etc`, смонтированный путь из подставного mounts-файла -> True; `/etc/mihomo` -> False), `test_list_dir_sorts_dirs_first_and_hides_bak`, `test_list_dir_truncates` (limit=3 при 5 файлах -> `truncated` True, 3 записи), `test_list_dir_broken_symlink` (type `link`, без исключения), `test_list_dir_non_utf8_name` (имя `b'\xff'` -> JSON-сериализуется через `json.dumps`), `test_read_text_ok_binary_large_and_device` (`/dev/null` -> 415), `test_tree_only_dirs`.
- [ ] **Step 2:** `tests/test_stats_files.sh` - `set -eu`, как `test_stats_httpd_py.sh` (пропуск без python3), запускает `python3 -I "$ROOT/tests/stats_files_check.py"`. Run: `sh tests/test_stats_files.sh` -> FAIL (модуля нет).
- [ ] **Step 3: Implement** перечисленные функции в `web/stats_files.py` (docstring модуля на русском - в стиле `stats_auth.py`). Имена декодировать через `os.fsdecode`, ошибочные байты - `surrogateescape`, для JSON заменять на `replace`. `lstat` для типов; `link` = путь цели из `os.readlink` или `None`.
- [ ] **Step 4:** Run `sh tests/test_stats_files.sh` -> PASS.
- [ ] **Step 5: Commit** `feat(files): пути, защита, список и чтение для файлового менеджера`.

### Task 2: Запись, загрузка, mkdir, переименование, удаление

**Files:**
- Modify: `web/stats_files.py`
- Modify: `tests/stats_files_check.py`

**Interfaces:**
- Consumes: `normalize`, `is_protected`, `is_readonly`, `FileError` (Task 1).
- Produces:
  - `write_text(path, content: str, expected_mtime: float = None) -> dict` -> `{"mtime","size"}`; `FileError(409,"conflict")` при расхождении mtime; `FileError(403,"readonly")` для файлов панели; перед заменой старое содержимое копируется в `<path>.bak`; запись `*.part` + `fsync` + `os.replace`, права сохраняются.
  - `save_stream(dest_dir, name, rfile, length, max_bytes=67108864, chunk=65536) -> dict` -> `{"path","size"}`; `name` без `/` и `\0` и не `.`/`..` (`FileError(400,"bad_name")`); `length > max_bytes` -> 413; свободное место проверяется `os.statvfs` (-> 507 `no_space`); при любой ошибке `*.part` удаляется; существующий файл заменяется атомарно.
  - `mkdir(path)`, `rename(src, dst)` (отказ 409 `exists` если `dst` есть; 403 `protected` для защищённых путей), `delete(path, recursive=False, confirm=None)` (ссылка удаляется как ссылка, `shutil.rmtree` только при `recursive` и `confirm == path`; иначе 409 `not_empty`/400 `confirm_required`; защищённые пути - 403).

- [ ] **Step 1: Write failing tests:** `test_write_text_makes_bak_and_preserves_mode`, `test_write_text_conflict_on_stale_mtime`, `test_write_text_refuses_panel_files` (через `FM_READONLY`), `test_save_stream_roundtrip_and_replace`, `test_save_stream_rejects_slash_dotdot_nul_names`, `test_save_stream_too_large_and_cleans_part` (rfile обрывается раньше `length` -> нет `*.part`), `test_save_stream_no_space` (подставной `statvfs`), `test_rename_refuses_existing`, `test_rename_and_delete_protected`, `test_delete_symlink_keeps_target`, `test_delete_recursive_needs_confirm`.
- [ ] **Step 2:** Run `sh tests/test_stats_files.sh` -> FAIL на новых тестах.
- [ ] **Step 3: Implement** функции выше; ошибки ввода/вывода (`OSError`) переводить в `FileError` с кодами `permission` (403), `not_found` (404), `io` (500).
- [ ] **Step 4:** Run `sh tests/test_stats_files.sh` -> PASS.
- [ ] **Step 5: Commit** `feat(files): запись, загрузка, переименование и удаление`.

### Task 3: HTTP-маршруты `/api/fm/*`

**Files:**
- Modify: `web/stats_httpd.py` (импорт `stats_files`; константы рядом с `SCRIPT_BODY_LIMIT`; ветка в `_handle()` после `api/system`, до `API_ROUTES`)
- Create: `tests/test_stats_files_http.sh` (по образцу `tests/test_stats_httpd_py.sh`: поднять сервер, войти, ходить `curl`)

**Interfaces:**
- Consumes: функции `stats_files` (Tasks 1-2).
- Produces (все под сессией и CSRF для не-GET):
  - `GET /api/fm/tree?path=` -> `{"dirs":[...]}`
  - `GET /api/fm/list?path=&hidden=0|1` -> результат `list_dir`
  - `GET /api/fm/read?path=` -> результат `read_text`
  - `GET /api/fm/download?path=` - поток, `Content-Length`, `Content-Disposition: attachment; filename*=UTF-8''...`
  - `PUT /api/fm/write` JSON `{path, content, mtime}`; тело ≤ 2 МиБ
  - `POST /api/fm/upload?path=<каталог>&name=<имя>` - тело = сырой файл, читается потоком в `save_stream`
  - `POST /api/fm/mkdir` `{path}`, `/rename` `{src,dst}`, `/delete` `{path,recursive,confirm}`
  - ошибки: `{"error": code}` со статусом `FileError.status`.
- Каждая изменяющая операция пишет строку в живой журнал панели (существующий механизм `live_log`, метка `files`); upload и delete ограничиваются `_rate_limit`.

- [ ] **Step 1: Write failing test** `test_stats_files_http.sh`: без сессии `GET /api/fm/list?path=/` -> 401; с сессией -> 200 и JSON с `entries`; `POST /api/fm/mkdir` без CSRF -> 403; mkdir/upload/download/read/write/rename/delete по цепочке в `$TEST_ROOT/data`; загрузка 5 МиБ (больше `SCRIPT_BODY_LIMIT`) проходит и совпадает по `cmp`; `delete` защищённого `/etc` -> 403; `download` `/dev/null` -> 415.
- [ ] **Step 2:** Run `sh tests/test_stats_files_http.sh` -> FAIL (маршруты дают 501).
- [ ] **Step 3: Implement** метод `_handle_files(rel)` в `Handler` и вызов из `_handle()` для `rel.startswith("api/fm/")`; параметры запроса разбирать `urllib.parse.parse_qs`; для download/upload не использовать `_run_script` и `_read_json`, читать `self.rfile` блоками; неизвестные `api/fm/*` -> 501 как сейчас.
- [ ] **Step 4:** Run `sh tests/test_stats_files_http.sh && sh tests/test_stats_httpd_py.sh && sh tests/test_stats_auth_http.sh` -> PASS (старые тесты не сломаны).
- [ ] **Step 5: Commit** `feat(files): маршруты /api/fm/* в веб-сервере`.

### Task 4: Интерфейс вкладки «Файлы»

**Files:**
- Create: `web/stats_app_files.js`
- Modify: `web/stats_httpd.py` (`STATIC_FILES`: `"app-files.js": "stats_app_files.js"`)
- Modify: `web/stats_index.html` (пункт `<a href="/files" data-link>Файлы</a>` между XKeen и Журналом)
- Modify: `web/stats_app.js` (импорт `renderFiles`, `stopFiles`, `filesDirty`; ветка `path === '/files'`; защита от потери несохранённой правки, как для xkeen)
- Modify: `web/stats_style.css` (классы `.fm-*`: три колонки, на узком экране экраны)
- Create: `tests/test_stats_files_ui.sh`

**Interfaces:**
- Consumes: `/api/fm/*` (Task 3); из `app-core.js`: `fetchJson`, `el`, `card`, `showError`, `viewGuard`, `session`.
- Produces: `export function renderFiles()`, `export function stopFiles()`, `export function filesDirty(): boolean`.

- [ ] **Step 1: Write failing test** `tests/test_stats_files_ui.sh` (стиль `tests/test_stats_xkeen.sh`, строки 205-215): `STATIC_FILES` содержит `app-files.js`; `stats_index.html` содержит ссылку `/files`; `stats_app.js` импортирует `./app-files.js`; если есть `node`, `node --check` по `stats_app_files.js`; модуль вызывает все восемь эндпоинтов (grep по `/api/fm/tree|list|read|download|write|upload|mkdir|rename|delete`).
- [ ] **Step 2:** Run -> FAIL.
- [ ] **Step 3: Implement** по макету B: колонка дерева (ленивая загрузка `tree`, раскрытие ▸/▾, подсветка текущего), колонка списка (хлебные крошки с переходом, «Загрузить», «Папка», «Файл», зона перетаскивания и `XMLHttpRequest` с прогрессом на `upload`, сортировка по имени/размеру/дате, переключатель «показать .bak/.part»), колонка редактора (CodeMirror из `codemirror.js`, «Сохранить» с `mtime`, «Скачать» ссылкой на `download`, «Переименовать», «Удалить»; конфликт 409 показывает предложение перечитать). Подтверждение `confirm()` на удаление, для каталога - ввод пути; пометка файлов панели «только чтение». На ширине до 900 px показывается одна колонка с кнопкой «Назад».
- [ ] **Step 4:** Run `sh tests/test_stats_files_ui.sh && sh tests/test_stats_xkeen.sh` -> PASS. Затем вручную запустить сервер на тестовой ФС и открыть `/files` в браузере (Playwright, Chromium из `/opt/pw-browsers`), снять скриншот и сверить с макетом B.
- [ ] **Step 5: Commit** `feat(files): вкладка «Файлы» в веб-панели`.

### Task 5: Установка, манифест, документация

**Files:**
- Modify: `install.sh:29` (`ALL_PROJECT_FILES` + `stats_files.py`, `stats_app_files.js`)
- Modify: `uninstall.sh:81-82` (те же имена)
- Modify: `release/components.txt` (две строки `FILE|web|...`: `web/stats_files.py` режим `0644` `py`, `web/stats_app_files.js` `0644` `none`)
- Modify: `tests/test_install.sh` (три длинных `cp`-списка на строках 443, 691, 881) и `tests/test_install_bootstrap.sh:13`
- Modify: `docs/guide.md`, `README.md`

**Interfaces:**
- Consumes: имена файлов из Tasks 1 и 4.

- [ ] **Step 1: Write failing test:** в `tests/test_install_bootstrap.sh` добавить `stats_files.py|stats_app_files.js` в `case` (-> `web`) и убедиться, что `sh tests/test_install.sh`, `sh tests/test_generate_manifest.sh`, `sh tests/test_uninstall.sh` падают без новых файлов в списках.
- [ ] **Step 2:** Run эти тесты -> FAIL.
- [ ] **Step 3: Implement** правки в перечисленных файлах; в `docs/guide.md` раздел «Файловый менеджер» (возможности, доступ от `/`, защищённые пути, предупреждение о безопасности и рекомендация закрыть порт 8899 от интернета), в README одна строка в списке веб-панели.
- [ ] **Step 4:** Run всё: `for t in tests/test_*.sh; do sh "$t" || echo "FAIL $t"; done` -> без `FAIL`.
- [ ] **Step 5: Commit** `feat(files): установка, манифест и документация файлового менеджера`.

---

## Self-review

- **Покрытие спецификации:** защита пути, защищённые пути, только чтение для файлов панели, чтение обычных файлов, лимиты, атомарная запись/.bak/mtime, потоковая загрузка с `statvfs`, mkdir/rename/delete с `confirm`, CSRF/rate-limit/журнал, дерево/список/редактор, установка и документация - Tasks 1-5.
- **Согласованность типов:** `FileError`, `list_dir`, `tree`, `read_text`, `write_text`, `save_stream`, `delete` одинаково называются в Tasks 1-3; в Task 4 используются эндпоинты Task 3.
- **Пропорция:** план короче кода, который он описывает; тела функций не приведены.
