// Раздел «Настройки» (/settings): параметры отбора и сброс статистики.
// Фильтр нод (какие ноды не проверять и не брать в группы) правится в
// конструкторе конфига, блок «Исключения нод».

import { app, card, clearApp, el, fetchJson, setLoading, showError, showFormMessage, showNotYetMoved, viewGuard } from './app-core.js';

// ----- раздел "Настройки" (/api/settings) -----

// Описание полей формы. label - подпись, hint - одна строка под полем,
// help - подробная подсказка (появляется, если задержать курсор на поле,
// или по кнопке «?» - для телефона и клавиатуры): пары [заголовок, текст].
// Тексты должны совпадать с тем, что реально делают speedtest2.sh,
// prep.awk, node_stats_update.awk и install.sh - меняя поведение там,
// правьте подсказку здесь.
var HELP_WHEN = ['Когда действует', 'Со следующего прогона (по расписанию раз в 3 часа или по кнопке «Сохранить и запустить»). Сам по себе этот параметр ничего не меняет и никакими другими настройками не перезаписывается.'];
var FIELD_DEFS = {
  min_ratio: {
    label: 'Порог скорости: доля от скорости вашего канала', type: 'number', min: 0.01, max: 1, step: 'any',
    hint: '0.25 = для досрочной остановки нужны ноды быстрее 25% прямого канала.',
    help: [
      ['Что это', 'Порог для досрочного завершения замеров. В итоговый пул входят до заданного максимума самых быстрых рабочих нод, включая WG, даже если их скорость ниже порога. Порог пересчитывается в каждом прогоне от скорости вашего интернета.'],
      ['Как работает', 'В начале каждого прогона роутер качает тестовый файл напрямую, без прокси, и получает скорость канала. Порог = скорость канала × эта доля, но не ниже значения «Порог скорости: не ниже».'],
      ['Пример', 'Канал 100 Мбит/с, доля 0.25 → порог 25 Мбит/с. Вечером канал просел до 60 Мбит/с → порог сам станет 15 Мбит/с. В обоих случаях пул заполняется самыми быстрыми рабочими нодами из замеренных.'],
      ['Как выбрать', 'Большая доля требует более быстрых результатов для досрочной остановки. Меньшая доля позволяет закончить замер раньше; в обоих случаях итоговый пул ограничен настройкой «Сколько нод держать в быстром пуле».'],
      ['Связи', 'Если замер канала не удался (нет интернета напрямую), вместо этой формулы берётся «Запасной порог» из раздела «Дополнительно». Команда mihomo-speedtest recalibrate и переустановка пересчитывают запасной порог по этой доле.'],
      HELP_WHEN
    ]
  },
  min_floor_mb: {
    label: 'Порог скорости: не ниже, Мбит/с', type: 'number', min: 0, step: 'any',
    hint: 'Нижняя граница для порога выше. 0 = без границы.',
    help: [
      ['Что это', 'Страховка для порога «доля от канала»: какой бы медленной ни оказалась прямая скорость в момент замера, порог не опустится ниже этого числа.'],
      ['Пример', 'Доля 0.25, этот параметр 4 Мбит/с. Если прямой канал показал 8 Мбит/с, расчёт даст 2 Мбит/с, но порог для досрочной остановки останется 4 Мбит/с.'],
      ['Как выбрать', 'Минимальная скорость, которую надо превысить для досрочной остановки. 0 - порог всегда равен доле от канала.'],
      HELP_WHEN
    ]
  },
  topn: {
    label: 'Сколько нод держать в быстром пуле (максимум)', type: 'number', min: 1, max: 50,
    hint: 'До этого числа самых быстрых рабочих нод, включая WG.',
    help: [
      ['Что это', 'Общий предел группы «⚡ Быстрый пул». Обычные ноды записываются в fast.yaml, WG входят прямыми ссылками. Внутри группы Mihomo выбирает ноду с лучшим пингом.'],
      ['Как работает', 'Протестированные рабочие ноды сортируются по скорости. Первые N входят в пул даже тогда, когда они ниже порога скорости. Нестабильные обычные ноды добавляются только как резерв до заданного минимума.'],
      ['Пример', 'Значение 15, замерено 40 рабочих нод → в пул попадут 15 самых быстрых, включая WG. Если рабочих нод только 6 → попадут все 6.'],
      ['Как выбрать', 'Больше - группе есть из чего выбирать, если нода упадёт между прогонами. Меньше - в пуле только лучшие. 10-20 подходит большинству.'],
      ['Связи', 'Прогон перестаёт проверять ноды, как только найдено «Остановиться, когда найдено быстрых нод». Если это число меньше, чем здесь, пул никогда не заполнится полностью - держите его не меньше этого значения.'],
      HELP_WHEN
    ]
  },
  min_winners: {
    label: 'Минимум нод в быстром пуле', type: 'number', min: 0, max: 50,
    hint: 'Сколько нод можно добрать из нестабильного резерва. 0 = не добирать.',
    help: [
      ['Что это', 'Защита от пустого пула, когда после отбора стабильных рабочих нод их меньше этого числа. Тогда можно добрать обычные ноды с низким накопленным Uptime.'],
      ['Пример', 'Значение 3, рабочих стабильных нод две, но есть нестабильная рабочая нода → она войдёт в пул третьей. Ноды, которые вообще не скачали файл, не добираются никогда.'],
      ['Как выбрать', '2-3 обычно достаточно. 0 - нестабильные обычные ноды не добираются. Максимальный размер пула по-прежнему задаёт настройка выше.'],
      HELP_WHEN
    ]
  },
  stable_min_uptime: {
    label: 'Минимальный Uptime ноды для быстрого пула, %', type: 'number', min: 0, max: 100,
    hint: 'Ноды, которые часто не отвечают, не попадают в пул, даже если быстрые. 0 = не учитывать.',
    help: [
      ['Что это', 'Скорость меряется один раз за прогон, и нода может случайно показать хороший результат, а между прогонами то и дело падать. Здесь задаётся, какую долю прогонов нода должна была отвечать, чтобы её пустили в пул.'],
      ['Как работает', 'Uptime считается по той же статистике, что и таблица «Статистика доступности нод», но только за последние «За сколько прогонов считать Uptime для отбора». Пока у ноды мало проверок (меньше «Сколько проверок нужно, чтобы учитывать Uptime»), она отбирается как раньше - только по скорости.'],
      ['Пример', 'Значение 80, за последние 24 прогона нода отвечала в 15 (62%) → в пул не попадёт, даже если сейчас самая быстрая. Отвечала в 22 (92%) → проходит как обычно.'],
      ['Если нод мало', 'Нестабильные ноды - последний резерв для «Минимум нод в быстром пуле»: их добирают, только если не хватает ни быстрых, ни медленных стабильных.'],
      ['Как выбрать', '70-90 подходит большинству. Выше - пул надёжнее, но меньше. 0 - отбор только по скорости, как в старых версиях.'],
      HELP_WHEN
    ]
  },
  stable_lookback: {
    label: 'За сколько прогонов считать Uptime для отбора', type: 'number', min: 1, max: 5000,
    hint: 'Чем меньше, тем быстрее нода, которая починилась, вернётся в пул.',
    help: [
      ['Что это', 'Сколько последних прогонов учитывать при проверке «Минимальный Uptime ноды для быстрого пула». Не путать с «Окно для расчёта Uptime» - то влияет только на таблицу доступности.'],
      ['Пример', '24 при прогоне раз в 3 часа - последние 3 суток. 8 - последние сутки: быстрее реагирует, но случайный сбой весит больше.'],
      ['Связи', 'Не может быть больше «Окно для расчёта Uptime» - статистика дальше не хранится.'],
      HELP_WHEN
    ]
  },
  stable_min_runs: {
    label: 'Сколько проверок нужно, чтобы учитывать Uptime', type: 'number', min: 1, max: 5000,
    hint: 'Пока проверок меньше, новая нода отбирается только по скорости.',
    help: [
      ['Что это', 'Защита новых нод: пока статистики мало, Uptime ненадёжен. Если у ноды за «За сколько прогонов считать Uptime для отбора» проверок меньше этого числа, фильтр по Uptime к ней не применяется.'],
      ['Пример', '8 при прогоне раз в 3 часа - нода, появившаяся в подписке, первые сутки отбирается только по скорости.'],
      HELP_WHEN
    ]
  },
  max_tested: {
    label: 'Сколько нод проверять на скорость за прогон (максимум)', type: 'number', min: 0,
    hint: '0 = все доступные ноды. Меньше - прогон быстрее и тратит меньше трафика.',
    help: [
      ['Что это', 'Сначала все ноды подписок быстро проверяются на доступность. Из живых на скорость проверяются не больше этого числа - первые по времени ответа.'],
      ['Как работает', 'Ноды проверяются по очереди, по одной. На каждую уходит до «Максимум времени на одну ноду» и скачивается до «Объём скачивания на одну ноду».'],
      ['Пример', 'Значение 40, объём 10 МБ, время 15 сек: прогон скачает не больше 400 МБ и займёт не дольше 10 минут. При прогоне раз в 3 часа это до 3,2 ГБ трафика в сутки.'],
      ['Связи', 'Прогон может закончиться раньше - когда найдено «Остановиться, когда найдено быстрых нод». Этот параметр - верхняя граница на случай, когда быстрых нод мало.'],
      HELP_WHEN
    ]
  },
  enough: {
    label: 'Остановиться, когда найдено быстрых нод', type: 'number', min: 1, max: 100,
    hint: 'Экономит время и трафик: дальше не проверяем. Держите не меньше размера пула.',
    help: [
      ['Что это', 'Как только столько проверенных нод оказались выше порога, прогон перестаёт скачивать через остальные.'],
      ['Пример', 'Значение 20, размер пула 15: прогон найдёт 20 быстрых нод, остановится и возьмёт в пул 15 лучших из них. Оставшиеся кандидаты в этот раз не проверяются.'],
      ['Как выбрать', 'Не меньше «Сколько нод держать в быстром пуле», лучше немного больше - тогда в пул попадут лучшие из найденных, а не просто первые. Больше - точнее отбор, но дольше прогон.'],
      HELP_WHEN
    ]
  },
  keep_runs: {
    label: 'Хранить прогонов (0 = не ограничивать)', type: 'number', min: 0,
    hint: 'Сколько последних прогонов помнить для графиков.',
    help: [
      ['Что это', 'История прогонов для графиков на странице статистики. Старые прогоны удаляются.'],
      ['Как работает', 'Действуют оба ограничения - «прогонов» и «дней»: срабатывает то, что наступит раньше. 200 прогонов при прогоне раз в 3 часа - это 25 дней.'],
      ['Связи', 'Лишние прогоны удаляются при следующем прогоне, не сразу. На таблицу «Статистика доступности нод» не влияет - у неё свои параметры в разделе «Дополнительно».'],
      HELP_WHEN
    ]
  },
  keep_days: {
    label: 'Хранить дней (0 = не ограничивать)', type: 'number', min: 0,
    hint: 'Нельзя занулить оба ограничения сразу.',
    help: [
      ['Что это', 'Прогоны старше стольких дней удаляются из истории графиков.'],
      ['Пример', '«Прогонов» 200 и «дней» 7: хранится неделя, даже если за неделю прошло меньше 200 прогонов.'],
      HELP_WHEN
    ]
  },
  node_cap: {
    label: 'Сколько нод показывать в ленте доступности сразу (1-50)', type: 'number', min: 1, max: 50,
    hint: 'Самые стабильные. Остальные - кнопкой «Все» или через поиск.',
    help: [
      ['Что это', 'Только отображение: сколько нод лента «Доступность нод по прогонам» показывает при открытии страницы. На отбор нод не влияет.'],
      ['Как работает', 'Ноды упорядочены по аптайму за последние прогоны - сверху самые живые. Остальные показывает кнопка «Все», любую ноду можно найти поиском.'],
      ['Когда действует', 'Сразу после сохранения.']
    ]
  },
  update_channel: {
    label: 'Канал обновлений', type: 'select', dflt: 'stable',
    options: [['stable', 'Стабильный'], ['dev', 'Разработка (тестовые сборки)']],
    hint: 'Стабильный - для всех. Разработка - новые функции раньше, но возможны ошибки.',
    help: [
      ['Что это', 'Откуда роутер берёт обновления проекта: только стабильные релизы или ещё и тестовые сборки из разработки.'],
      ['Разработка', 'Тестовые сборки выходят чаще и могут содержать ошибки. Подходят, если хотите проверить новое раньше всех.'],
      ['Возврат на стабильный', 'Переключиться обратно можно в любой момент. Если уже стоит тестовая сборка новее стабильной, роутер останется на ней до выхода следующего стабильного релиза.'],
      ['Когда действует', 'Со следующей проверки обновлений или сразу по кнопке «Проверить сейчас» выше.']
    ]
  },
  update_check_hours: {
    label: 'Проверять обновления', type: 'select', dflt: 12,
    options: [[1, 'каждый час'], [2, 'раз в 2 часа'], [3, 'раз в 3 часа'], [4, 'раз в 4 часа'], [6, 'раз в 6 часов'], [8, 'раз в 8 часов'], [12, 'раз в 12 часов'], [24, 'раз в сутки']],
    hint: 'Только проверка. Обновление ставится кнопкой «Обновить» выше.',
    help: [
      ['Что это', 'Как часто роутер сам спрашивает GitHub, не вышла ли новая версия проекта. Если вышла - на вкладке «Обновления» появляется отметка и кнопка «Обновить».'],
      ['Важно', 'Ничего не устанавливается само: обновление всегда запускается только кнопкой «Обновить».'],
      ['Когда действует', 'Сразу после сохранения - расписание в cron переписывается.']
    ]
  },
  extype: {
    label: 'Не проверять ноды этих типов (через |)', type: 'text', placeholder: 'например trojan|ss',
    hint: 'Типы протоколов, которые пропускаются целиком. Пусто = пропускается только trojan.',
    help: [
      ['Что это', 'Ноды с таким протоколом (поле type в подписке) не проверяются на скорость и не попадают в быстрый пул.'],
      ['Пример', 'trojan|ss - пропустить Trojan и Shadowsocks. Другие типы: vless, vmess, hysteria2, tuic, wireguard.'],
      ['Зачем', 'Если какой-то протокол у вас не работает или работает плохо, нет смысла тратить на него время и трафик.'],
      ['Связи', 'В config.yaml у провайдера fast тоже есть exclude-type (по умолчанию trojan|ss): если убрать тип отсюда, но оставить там, ноды этого типа будут проверяться, но Mihomo всё равно не возьмёт их в «⚡ Быстрый пул». Пустое поле не отключает фильтр - тогда пропускается trojan.'],
      HELP_WHEN
    ]
  },
  size_mb: {
    label: 'Объём скачивания на одну ноду, МБ', type: 'number', min: 1, max: 100, step: 'any',
    hint: 'Меньше 10 МБ занижает результат. Больше - точнее, но больше трафика.',
    help: [
      ['Что это', 'Сколько данных скачивается через каждую ноду для замера (файл с speed.cloudflare.com). Скорость = объём / время.'],
      ['Почему не меньше 10', 'Первые доли секунды уходят на установку соединения. На маленьком файле они занимают большую часть времени: на 3 МБ нода с реальными 12 МБ/с показывала 4,5 МБ/с.'],
      ['Трафик', 'Объём × число проверенных нод за прогон. 10 МБ × 40 нод = до 400 МБ за прогон.'],
      HELP_WHEN
    ]
  },
  dl_timeout: {
    label: 'Максимум времени на одну ноду, сек', type: 'number', min: 1, max: 120,
    hint: 'Медленная нода не задерживает прогон дольше этого.',
    help: [
      ['Что это', 'Сколько секунд максимум ждать скачивания через одну ноду. Если не успела - засчитывается скорость, с которой она качала до обрыва.'],
      ['Пример', '10 МБ за 15 секунд - это около 5,6 Мбит/с. Нода медленнее за 15 секунд файл не докачает, но её скорость всё равно будет измерена.'],
      ['Связи', 'Самый долгий прогон ≈ это время × «Сколько нод проверять на скорость за прогон». Этим же временем ограничен замер прямого канала в начале прогона.'],
      HELP_WHEN
    ]
  },
  min_speed_mb: {
    label: 'Запасной порог, Мбит/с (если замер канала не удался)', type: 'number', min: 0.1, max: 10000, step: 'any',
    hint: 'Используется только когда прямой замер канала не удался.',
    help: [
      ['Что это', 'Порог скорости на крайний случай. Обычно порог считается в каждом прогоне как «доля от скорости канала», а это число не используется.'],
      ['Когда используется', 'Если в начале прогона не удалось скачать тестовый файл напрямую, без прокси (провайдер недоступен, Cloudflare заблокирован и т.п.).'],
      ['Меняется ли само', 'Да: install.sh при установке и команда mihomo-speedtest recalibrate пересчитывают его по текущей скорости канала и долям выше. Здесь его можно поправить вручную - значение продержится до следующего recalibrate или переустановки.']
    ]
  },
  stability_window: {
    label: 'Окно для расчёта Uptime, прогонов', type: 'number', min: 1, max: 5000,
    hint: 'За сколько последних прогонов считать Uptime в таблице доступности.',
    help: [
      ['Что это', 'Столбец Uptime в таблице «Статистика доступности нод» - доля прогонов, в которых нода отвечала. Этот параметр - за сколько последних прогонов считать.'],
      ['Пример', '200 прогонов при прогоне раз в 3 часа - около 25 дней. 8 - только последние сутки.'],
      ['Связи', 'Влияет только на таблицу доступности. Для отбора нод в пул Uptime считается отдельно - см. «За сколько прогонов считать Uptime для отбора».'],
      HELP_WHEN
    ]
  },
  stability_drop_after: {
    label: 'Убирать из таблицы доступности ноду, пропавшую из подписки, через N прогонов (0 = никогда)', type: 'number', min: 0,
    hint: 'Чистит таблицу от нод, которых больше нет в подписках.',
    help: [
      ['Что это', 'Если нода исчезла из подписки и не появляется столько прогонов подряд, её строка удаляется из таблицы «Статистика доступности нод».'],
      ['Пример', '8 - нода, пропавшая из подписки, исчезнет из таблицы через сутки (при прогоне раз в 3 часа). 0 - строки никогда не удаляются.'],
      HELP_WHEN
    ]
  }
};

var CARDS = [
  // На виду - только то, что понятно без подсказок: насколько строго отбирать
  // ноды (пресет) и сколько их держать в пуле. Остальное - в свёрнутом блоке.
  { title: 'Быстрый пул', preset: true, fields: ['topn'] },
  { title: 'Дополнительно', advanced: true, note: 'Редко нужные параметры. Значения по умолчанию подходят большинству.', groups: [
    { title: 'Отбор в быстрый пул', fields: ['min_ratio', 'min_floor_mb', 'min_winners', 'stable_min_uptime', 'stable_lookback'] },
    { title: 'Сколько нод проверять за прогон', fields: ['max_tested', 'enough'] },
    { title: 'История и графики', fields: ['keep_runs', 'keep_days', 'node_cap'] },
    { title: 'Прочее', fields: ['extype', 'size_mb', 'dl_timeout', 'min_speed_mb', 'stability_window', 'stability_drop_after', 'stable_min_runs'] }
  ] }
];

// Короткая схема прогона над формой - чтобы подсказки полей было к чему
// привязать («порог», «пул», «кандидаты»).
function buildRunOverviewCard() {
  var c = el('details', 'card settings-overview');
  c.open = true;
  c.appendChild(el('summary', null, 'Как устроен прогон - кратко'));
  var ol = el('ol');
  [
    'Раз в 3 часа (или по кнопке) роутер берёт все ноды из подписок, кроме отфильтрованных гео-фильтром и по типу.',
    'Быстро проверяет, какие из них вообще отвечают.',
    'Замеряет скорость вашего интернета без прокси и считает порог: доля от канала, но не ниже заданного минимума.',
    'По очереди качает тестовый файл через живые ноды и останавливается, когда нашёл достаточно быстрых или проверил максимум нод.',
    'Самые быстрые рабочие ноды входят в «⚡ Быстрый пул»: обычные через fast.yaml, WG прямыми ссылками. Внутри группы Mihomo выбирает ноду с лучшим пингом.'
  ].forEach(function (t) { ol.appendChild(el('li', null, t)); });
  c.appendChild(ol);
  c.appendChild(el('p', 'hint', 'Задержите курсор на любом поле или нажмите «?» рядом с ним - появится подробное объяснение с примерами.'));
  return c;
}

// Подробная подсказка поля: появляется, если задержать курсор на поле
// (HELP_DELAY_MS), и по кнопке «?» (закрепляется до повторного нажатия,
// клика мимо или Esc). Одновременно открыта одна.
var HELP_DELAY_MS = 600;
var openHelp = null;

function closeOpenHelp() {
  if (openHelp) { openHelp.hide(); }
}

document.addEventListener('click', function (e) {
  if (openHelp && !openHelp.wrap.contains(e.target)) { closeOpenHelp(); }
});
document.addEventListener('keydown', function (e) {
  if (e.key === 'Escape') { closeOpenHelp(); }
});

function attachHelp(wrap, head, name, def) {
  var pop = el('div', 'help-pop');
  pop.id = 'help-' + name;
  pop.setAttribute('role', 'tooltip');
  pop.hidden = true;
  pop.appendChild(el('div', 'help-title', def.label));
  def.help.forEach(function (part) {
    var p = el('p');
    p.appendChild(el('b', null, part[0] + '. '));
    p.appendChild(document.createTextNode(part[1]));
    pop.appendChild(p);
  });
  var q = el('button', 'help-q', '?');
  q.type = 'button';
  q.setAttribute('aria-label', 'Подробнее: ' + def.label);
  q.setAttribute('aria-expanded', 'false');
  q.setAttribute('aria-describedby', pop.id);
  head.appendChild(q);
  wrap.appendChild(pop);

  var timer = null, pinned = false;
  var api = {
    wrap: wrap,
    show: function () {
      if (openHelp && openHelp !== api) { openHelp.hide(); }
      pop.hidden = false;
      q.setAttribute('aria-expanded', 'true');
      openHelp = api;
    },
    hide: function () {
      clearTimeout(timer);
      pinned = false;
      pop.hidden = true;
      q.setAttribute('aria-expanded', 'false');
      if (openHelp === api) { openHelp = null; }
    }
  };
  wrap.addEventListener('mouseenter', function () {
    clearTimeout(timer);
    if (pop.hidden) { timer = setTimeout(api.show, HELP_DELAY_MS); }
  });
  wrap.addEventListener('mouseleave', function () {
    clearTimeout(timer);
    if (!pinned) { api.hide(); }
  });
  q.addEventListener('click', function () {
    if (pinned) { api.hide(); return; }
    api.show();
    pinned = true;
  });
}

// Экспорт: карточка «Настройки обновлений» на вкладке «Обновления»
// (stats_app_updates.js) строит свои поля тем же кодом.
// PRESETS-LOGIC-BEGIN
// «Насколько строго отбирать»: пресет задаёт два поля - долю от канала
// (min_ratio) и минимальный Uptime (stable_min_uptime). Остальное (нижняя
// граница порога, минимум нод, окно Uptime) пресеты не трогают. Значения не
// совпали ни с одним пресетом - «Свои значения» (ничего не затирается).
var STRICTNESS_PRESETS = [
  { id: 'soft', label: 'Мягко - ниже требование к Uptime', min_ratio: 0.15, stable_min_uptime: 60 },
  { id: 'normal', label: 'Обычно (рекомендуется)', min_ratio: 0.25, stable_min_uptime: 80 },
  { id: 'strict', label: 'Строго - выше Uptime, дольше замер', min_ratio: 0.4, stable_min_uptime: 90 }
];
function numberOf(v, dflt) {
  var n = parseFloat(String(v === undefined || v === null ? '' : v).replace(',', '.'));
  return isFinite(n) ? n : dflt;
}
function presetOf(values) {
  var r = numberOf(values.min_ratio, 0.25), u = numberOf(values.stable_min_uptime, 80);
  for (var i = 0; i < STRICTNESS_PRESETS.length; i++) {
    if (STRICTNESS_PRESETS[i].min_ratio === r && STRICTNESS_PRESETS[i].stable_min_uptime === u) { return STRICTNESS_PRESETS[i].id; }
  }
  return 'custom';
}
function presetValues(id) {
  for (var i = 0; i < STRICTNESS_PRESETS.length; i++) {
    if (STRICTNESS_PRESETS[i].id === id) {
      return { min_ratio: STRICTNESS_PRESETS[i].min_ratio, stable_min_uptime: STRICTNESS_PRESETS[i].stable_min_uptime };
    }
  }
  return null;
}
// PRESETS-LOGIC-END

// Выбор строгости отбора. Сам не уходит в POST (нет name): отправляются поля
// min_ratio и stable_min_uptime из блока «Дополнительно», пресет их заполняет.
function buildPresetField(values, form) {
  var wrap = el('div', 'field');
  var head = el('div', 'field-head');
  var label = el('label', null, 'Строгость проверки и стабильности нод');
  label.setAttribute('for', 'strictness');
  head.appendChild(label);
  wrap.appendChild(head);
  var sel = el('select');
  sel.id = 'strictness';
  STRICTNESS_PRESETS.forEach(function (p) {
    var o = el('option', null, p.label); o.value = p.id; sel.appendChild(o);
  });
  var custom = el('option', null, 'Свои значения (заданы в «Дополнительно»)');
  custom.value = 'custom';
  sel.appendChild(custom);
  sel.value = presetOf(values);
  wrap.appendChild(sel);
  wrap.appendChild(el('p', 'hint', 'Режим меняет требование к Uptime и порог досрочной остановки замеров. Размер пула задаётся отдельно.'));
  function field(name) { return form.querySelector('[name="' + name + '"]'); }
  sel.addEventListener('change', function () {
    var v = presetValues(sel.value);
    if (!v) { return; }
    field('min_ratio').value = v.min_ratio;
    field('stable_min_uptime').value = v.stable_min_uptime;
  });
  // Правка точных полей вручную возвращает выбор в «Обычно / Мягко / Строго»
  // или «Свои значения».
  form.addEventListener('input', function (e) {
    if (e.target && (e.target.name === 'min_ratio' || e.target.name === 'stable_min_uptime')) {
      sel.value = presetOf({ min_ratio: field('min_ratio').value, stable_min_uptime: field('stable_min_uptime').value });
    }
  });
  return wrap;
}

export function buildField(name, value) {
  var def = FIELD_DEFS[name];
  var wrap = el('div', 'field');
  var head = el('div', 'field-head');
  var label = el('label', null, def.label);
  label.setAttribute('for', name);
  head.appendChild(label);
  wrap.appendChild(head);
  var input;
  if (def.type === 'select') {
    input = el('select');
    def.options.forEach(function (opt) {
      var o = el('option', null, opt[1]);
      o.value = String(opt[0]);
      input.appendChild(o);
    });
  } else {
    input = el('input');
    input.type = def.type;
  }
  input.id = name;
  input.name = name;
  if (def.type === 'number') {
    if (def.min !== undefined) { input.min = def.min; }
    if (def.max !== undefined) { input.max = def.max; }
    if (def.step !== undefined) { input.step = def.step; }
  }
  if (def.placeholder) { input.placeholder = def.placeholder; }
  input.value = value === undefined || value === null ? '' : value;
  if (def.type === 'select' && !input.value) { input.value = String(def.dflt); }
  wrap.appendChild(input);
  if (def.hint) { wrap.appendChild(el('p', 'hint', def.hint)); }
  if (def.help) { attachHelp(wrap, head, name, def); }
  return wrap;
}

function buildSettingsForm(values) {
  var form = document.createElement('form');
  form.appendChild(buildRunOverviewCard());
  // Браузерная проверка min/max не может показать ошибку в поле внутри
  // свёрнутого <details> и молча не отправляет форму - раскрываем блок.
  form.addEventListener('invalid', function (e) {
    var fold = e.target.closest && e.target.closest('details');
    if (fold) { fold.open = true; }
  }, true);

  CARDS.forEach(function (cardDef) {
    var c;
    if (cardDef.advanced) {
      // Свёрнутый блок: поля внутри <details> всё равно уходят в POST.
      c = el('details', 'card settings-advanced');
      c.appendChild(el('summary', null, cardDef.title));
    } else {
      c = card(cardDef.title);
    }
    if (cardDef.note) { c.appendChild(el('p', 'hint', cardDef.note)); }
    if (cardDef.preset) { c.appendChild(buildPresetField(values, form)); }
    (cardDef.groups || [{ fields: cardDef.fields }]).forEach(function (grp) {
      if (grp.title) { c.appendChild(el('h3', 'settings-group', grp.title)); }
      grp.fields.forEach(function (name) {
        c.appendChild(buildField(name, values[name]));
      });
    });
    form.appendChild(c);
  });

  var btnRow = el('div', 'btn-row');
  var saveBtn = el('button', 'submit', 'Сохранить');
  saveBtn.type = 'submit';
  var saveRunBtn = el('button', 'submit secondary', 'Сохранить и запустить');
  saveRunBtn.type = 'submit';
  btnRow.appendChild(saveBtn);
  btnRow.appendChild(saveRunBtn);
  form.appendChild(btnRow);

  // Какая кнопка нажата - запоминаем по клику (событие click срабатывает
  // раньше submit), чтобы после успешного сохранения решить, звать ли
  // ещё и /api/run (кнопка "Сохранить и запустить").
  var runAfterSave = false;
  saveBtn.addEventListener('click', function () { runAfterSave = false; });
  saveRunBtn.addEventListener('click', function () { runAfterSave = true; });

  function setFormButtonsDisabled(disabled) {
    saveBtn.disabled = disabled;
    saveRunBtn.disabled = disabled;
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var alive = viewGuard();
    var shouldRun = runAfterSave;
    setFormButtonsDisabled(true);
    showFormMessage(form, null);
    var body = new URLSearchParams(new FormData(form));
    fetchJson('/api/settings', { method: 'POST', body: body }).then(function (resp) {
      if (!resp.ok) {
        var texts = [];
        var errs = resp.errors || {};
        Object.keys(errs).forEach(function (key) {
          texts.push(errs[key]);
          var badInput = form.querySelector('[name="' + key + '"]');
          if (badInput) {
            badInput.classList.add('input-err');
            // ошибка в свёрнутом «Дополнительно» - раскрыть, иначе её не видно
            var fold = badInput.closest && badInput.closest('details');
            if (fold) { fold.open = true; }
          }
        });
        showFormMessage(form, texts.join(' '), 'err');
        setFormButtonsDisabled(false);
        return;
      }
      if (!alive()) { return; }
      if (!shouldRun) {
        renderSettings('Настройки сохранены.');
        return;
      }
      return fetchJson('/api/run', { method: 'POST' }).then(function (d) {
        var msg = d.started ? 'Настройки сохранены, прогон запущен.' : 'Настройки сохранены, прогон уже шёл - новый не запускался.';
        if (alive()) { renderSettings(msg); }
      })['catch'](function (err) {
        if (alive()) { renderSettings('Настройки сохранены, но не удалось запустить прогон: ' + err.message); }
      });
    })['catch'](function (err) {
      showFormMessage(form, 'Не удалось сохранить: ' + err.message, 'err');
      setFormButtonsDisabled(false);
    });
  });

  return form;
}

// Полный сброс статистики: сводка прогонов, история нод-победителей и
// доступность нод (лента и таблица) (reset_node_stats() в stats_cgi.sh).
// Настройки не меняются.
function buildResetStatsCard() {
  var c = card('Сброс статистики');
  c.appendChild(el('p', 'hint', 'Очищает всю статистику: историю прогонов, ленту «Доступность нод по прогонам» и таблицу «Статистика доступности нод» - они начнут копиться заново со следующего прогона. Настройки не меняются.'));
  var msg = el('p', 'hint');
  var btn = el('button', 'submit secondary', 'Сбросить статистику');
  btn.type = 'button';
  btn.addEventListener('click', function () {
    if (!window.confirm('Сбросить всю статистику: историю прогонов, ленту и таблицу доступности нод? Отменить сброс нельзя.')) { return; }
    btn.disabled = true;
    msg.className = 'hint';
    msg.textContent = 'Сбрасываю...';
    fetchJson('/api/settings', { method: 'POST', body: new URLSearchParams({ action: 'reset_node_stats' }) }).then(function (resp) {
      if (resp.ok) {
        msg.className = 'msg-ok';
        msg.textContent = 'Статистика сброшена.';
      } else {
        var errs = resp.errors || {};
        msg.className = 'msg-err';
        msg.textContent = errs.reset || 'Не удалось сбросить статистику.';
      }
      btn.disabled = false;
    })['catch'](function (err) {
      msg.className = 'msg-err';
      msg.textContent = 'Не удалось сбросить статистику: ' + err.message;
      btn.disabled = false;
    });
  });
  var row = el('div', 'btn-row');
  row.appendChild(btn);
  c.appendChild(row);
  c.appendChild(msg);
  return c;
}

export function renderSettings(justSavedMsg) {
  setLoading();
  var alive = viewGuard();
  fetchJson('/api/settings').then(function (data) {
    if (!alive()) { return; }
    clearApp();
    var values = data.values || {};
    var form = buildSettingsForm(values);
    app.appendChild(form);
    app.appendChild(buildResetStatsCard());
    if (justSavedMsg) { showFormMessage(form, justSavedMsg, 'ok'); }
  })['catch'](function (err) {
    if (!alive()) { return; }
    if (err.message === 'not_implemented') {
      showNotYetMoved('Форма настройки ещё переезжает на новый интерфейс.');
      return;
    }
    showError('Не удалось загрузить настройки: ', err);
  });
}
