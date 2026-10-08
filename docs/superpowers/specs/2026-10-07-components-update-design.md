# Проверка и обновление компонентов (mihomo, zashboard, xkeen)

Дата: 2026-10-07. Статус: черновик на согласование.

## Цель

В разделе «Обновления» веб-панели показывать установленную и последнюю
версию ядра mihomo, zashboard и xkeen. Ядро и zashboard обновлять кнопкой
из браузера. Обновление самого проекта (`update.sh`) не меняется.

## Решения

- Новый CGI-модуль `web/stats_components.sh` и эндпоинты `/api/components/*`.
  В манифест и `update.sh` компоненты не встраиваются.
- Ядро и zashboard обновляются встроенным API mihomo (`external-controller`,
  `secret` из конфига): `POST /upgrade` и `POST /upgrade/ui`.
- xkeen: только индикатор «есть новая версия», кнопки обновления нет.
- Канал mihomo определяется автоматически: версия из `/version` с `alpha`
  или `Prerelease` сравнивается с тегом `Prerelease-Alpha`, иначе со stable
  `latest`. Ручного выбора канала нет.
- Автопроверка идёт по расписанию основного проекта (`UPDATE_CHECK_HOURS`):
  `stats_update.sh check` после проверки проекта вызывает
  `stats_components.sh check`. Отдельной cron-строки и настройки нет.

## Источники версий

| Компонент | Установлено | Последняя |
|---|---|---|
| mihomo | `GET /version` | GitHub Releases `MetaCubeX/mihomo` (stable `latest` или тег `Prerelease-Alpha`) |
| zashboard | версия из `./zash` (место уточнить при реализации) | GitHub Releases `Zephyruso/zashboard` |
| xkeen | `xkeen -v` | GitHub Releases репозитория XKeen |

Результат проверки кэшируется в `components.json` рядом с `last-check.json`
(`/tmp/mihomo-speedtest-update`). У каждой строки своё поле `error`: сбой
сети, лимит GitHub API или недоступность API ядра показываются в строке и не
ломают ни страницу, ни проверку проекта.

## Применение обновления

- `POST /api/components/apply?name=mihomo|zashboard`, `GET /api/components/status`
  (статус и лог). Фоновое задание, один за раз; замок и приём «job + лог»
  переиспользуются из `stats_xkeen.sh`, чтобы обновление не шло вместе с
  применением конфига.
- mihomo: `mihomo -t` текущего конфига, копия бинарника в `.bak`,
  `POST /upgrade`, затем опрос `/version`. Если ядро не поднялось за N секунд,
  бинарник возвращается из `.bak`, ядро перезапускается `xkeen -restart`, в
  лог пишется «откат выполнен».
- zashboard: `POST /upgrade/ui`, затем проверка, что `./zash` не пуст.
  Перезапуск ядра не нужен.
- Если `/upgrade` не поддерживается сборкой ядра, строка показывает
  «обновление ядра недоступно».
- Веб-панель на :8899 работает отдельно от ядра и остаётся доступной, но
  замеры и прокси кратко прерываются, поэтому кнопка просит подтверждение.

## Бейдж и плитка

Бейдж в меню и плитка «ОБНОВЛЕНИЕ» на `/stats` считают «доступно»,
если есть обновление проекта или любого компонента (включая индикатор xkeen).

## UI

Карточка «Компоненты» в `renderUpdates()` (`stats_app_updates.js`), логика в
новом `stats_app_components.js`: таблица из трёх строк (установлено /
доступно / статус); у mihomo и zashboard кнопка «Обновить» с `confirm` и
мини-консолью по образцу `renderUpdatesProgress`; у xkeen пометка
«обновление вручную» с командой (флаг уточнить по установленной версии).

## Затрагиваемые файлы

- новые: `web/stats_components.sh`, `web/stats_app_components.js`,
  `tests/test_stats_components.sh`;
- правки: `web/stats_httpd.py` (маршруты), `web/stats_update.sh` (вызов
  `check`), `web/stats_app_updates.js` (карточка, бейдж),
  `release/components.txt`, `docs/guide.md`, `README.md`.

## Тесты

В стиле существующих `tests/test_*.sh`: мок GitHub API и мок API mihomo
(локальный сервер). Проверяются: выбор канала, сравнение версий, откат при
неподнявшемся ядре, изоляция ошибок, блокировка параллельного запуска,
вклад компонентов в бейдж.

## Вне рамок

Обновление xkeen и xray, ручной выбор канала и версии, откат zashboard.

## Риски для проверки при реализации

- Где zashboard хранит свою версию.
- Путь бинарника mihomo на Keenetic.
- Поддержка `/upgrade` в установленной сборке ядра.
- Доступность `api.github.com` с роутера (проект уже ходит в GitHub Releases).
