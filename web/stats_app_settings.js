// Раздел «Настройки» (/settings): гео-фильтр, параметры отбора и
// сброс статистики.

import { app, card, clearApp, el, fetchJson, setLoading, showError, showFormMessage, showNotYetMoved, viewGuard } from './app-core.js';

// ----- гео-фильтр спидтеста (BLOCK): карточка "Какие ноды не проверять" -----
// Дизайн: docs/superpowers/specs/2026-09-28-block-filter-ui-design.md.
// BLOCK - не regex, а список подстрок через | (см. prep.awk): нода
// пропускается, если её имя содержит любое слово без учёта регистра.
// Блок между метками GEO-LOGIC-BEGIN/END - чистые функции без DOM;
// tests/test_stats_geo_filter.sh вырезает его и проверяет в node.
// GEO-LOGIC-BEGIN
function geoCountry(code, flag, ru, en, extra, common) {
  return { code: code, flag: flag, ru: ru, words: [flag, en, ru].concat(extra || []), common: !!common };
}

// Наборы слов - только флаг и полные названия (у "других" стран ещё
// столица/хаб): голые 2-3-буквенные коды совпадали бы внутри чужих
// имён ("RU" - Brussels, Peru; "USA" - Jerusalem). У России - ещё
// привычные метки нод из шаблона (MSK/SPB оставлены сознательно).
var GEO_CATALOG = [
  geoCountry('RU', '🇷🇺', 'Россия', 'Russia', ['RU-', 'RU_', 'Moscow', 'Москва', 'MSK', 'МСК', 'SPB', 'СПб'], true),
  geoCountry('UA', '🇺🇦', 'Украина', 'Ukraine', [], true),
  geoCountry('KZ', '🇰🇿', 'Казахстан', 'Kazakhstan', [], true),
  geoCountry('BY', '🇧🇾', 'Беларусь', 'Belarus', ['Minsk', 'Минск'], true),
  geoCountry('TR', '🇹🇷', 'Турция', 'Turkey', ['Türkiye'], true),
  geoCountry('IL', '🇮🇱', 'Израиль', 'Israel', [], true),
  geoCountry('IN', '🇮🇳', 'Индия', 'India', [], true),
  geoCountry('JP', '🇯🇵', 'Япония', 'Japan', [], true),
  geoCountry('KR', '🇰🇷', 'Корея', 'Korea', [], true),
  geoCountry('MY', '🇲🇾', 'Малайзия', 'Malaysia', [], true),
  geoCountry('AU', '🇦🇺', 'Австралия', 'Australia', [], true),
  geoCountry('ZA', '🇿🇦', 'ЮАР', 'South Africa', [], true),
  geoCountry('NG', '🇳🇬', 'Нигерия', 'Nigeria', [], true),
  geoCountry('BR', '🇧🇷', 'Бразилия', 'Brazil', [], true),
  geoCountry('AR', '🇦🇷', 'Аргентина', 'Argentina', [], true),
  geoCountry('CL', '🇨🇱', 'Чили', 'Chile', [], true),
  geoCountry('CO', '🇨🇴', 'Колумбия', 'Colombia', [], true),
  geoCountry('PE', '🇵🇪', 'Перу', 'Peru', [], true),
  geoCountry('MX', '🇲🇽', 'Мексика', 'Mexico', [], true),
  geoCountry('US', '🇺🇸', 'США', 'United States', []),
  geoCountry('CA', '🇨🇦', 'Канада', 'Canada', []),
  geoCountry('GB', '🇬🇧', 'Великобритания', 'United Kingdom', ['London']),
  geoCountry('DE', '🇩🇪', 'Германия', 'Germany', ['Frankfurt']),
  geoCountry('NL', '🇳🇱', 'Нидерланды', 'Netherlands', ['Amsterdam']),
  geoCountry('FR', '🇫🇷', 'Франция', 'France', ['Paris']),
  geoCountry('FI', '🇫🇮', 'Финляндия', 'Finland', ['Helsinki']),
  geoCountry('SE', '🇸🇪', 'Швеция', 'Sweden', ['Stockholm']),
  geoCountry('PL', '🇵🇱', 'Польша', 'Poland', ['Warsaw']),
  geoCountry('EE', '🇪🇪', 'Эстония', 'Estonia', ['Tallinn']),
  geoCountry('LV', '🇱🇻', 'Латвия', 'Latvia', ['Riga']),
  geoCountry('LT', '🇱🇹', 'Литва', 'Lithuania', ['Vilnius']),
  geoCountry('CH', '🇨🇭', 'Швейцария', 'Switzerland', ['Zurich']),
  geoCountry('AT', '🇦🇹', 'Австрия', 'Austria', ['Vienna']),
  geoCountry('SG', '🇸🇬', 'Сингапур', 'Singapore', []),
  geoCountry('HK', '🇭🇰', 'Гонконг', 'Hong Kong', []),
  geoCountry('BG', '🇧🇬', 'Болгария', 'Bulgaria', ['Sofia', 'София']),
  geoCountry('RO', '🇷🇴', 'Румыния', 'Romania', ['Bucharest', 'Бухарест']),
  geoCountry('MD', '🇲🇩', 'Молдова', 'Moldova', ['Chisinau', 'Кишинёв']),
  geoCountry('CZ', '🇨🇿', 'Чехия', 'Czech', ['Prague', 'Прага']),
  geoCountry('SK', '🇸🇰', 'Словакия', 'Slovakia', ['Bratislava']),
  geoCountry('HU', '🇭🇺', 'Венгрия', 'Hungary', ['Budapest', 'Будапешт']),
  geoCountry('SI', '🇸🇮', 'Словения', 'Slovenia', ['Ljubljana']),
  geoCountry('HR', '🇭🇷', 'Хорватия', 'Croatia', ['Zagreb']),
  geoCountry('RS', '🇷🇸', 'Сербия', 'Serbia', ['Belgrade', 'Белград']),
  geoCountry('GR', '🇬🇷', 'Греция', 'Greece', ['Athens', 'Афины']),
  geoCountry('CY', '🇨🇾', 'Кипр', 'Cyprus', ['Limassol', 'Nicosia']),
  geoCountry('IT', '🇮🇹', 'Италия', 'Italy', ['Milan', 'Милан']),
  geoCountry('ES', '🇪🇸', 'Испания', 'Spain', ['Madrid', 'Мадрид']),
  geoCountry('PT', '🇵🇹', 'Португалия', 'Portugal', ['Lisbon', 'Лиссабон']),
  geoCountry('IE', '🇮🇪', 'Ирландия', 'Ireland', ['Dublin']),
  geoCountry('BE', '🇧🇪', 'Бельгия', 'Belgium', []),
  geoCountry('LU', '🇱🇺', 'Люксембург', 'Luxembourg', []),
  geoCountry('DK', '🇩🇰', 'Дания', 'Denmark', ['Copenhagen']),
  geoCountry('NO', '🇳🇴', 'Норвегия', 'Norway', ['Oslo']),
  geoCountry('IS', '🇮🇸', 'Исландия', 'Iceland', ['Reykjavik']),
  geoCountry('GE', '🇬🇪', 'Грузия', 'Georgia', ['Tbilisi', 'Тбилиси']),
  geoCountry('AM', '🇦🇲', 'Армения', 'Armenia', ['Yerevan', 'Ереван']),
  geoCountry('AZ', '🇦🇿', 'Азербайджан', 'Azerbaijan', ['Baku', 'Баку']),
  geoCountry('UZ', '🇺🇿', 'Узбекистан', 'Uzbekistan', ['Tashkent', 'Ташкент']),
  geoCountry('KG', '🇰🇬', 'Киргизия', 'Kyrgyzstan', ['Bishkek', 'Бишкек']),
  geoCountry('AE', '🇦🇪', 'ОАЭ', 'United Arab Emirates', ['Dubai', 'Дубай', 'Emirates']),
  geoCountry('TW', '🇹🇼', 'Тайвань', 'Taiwan', ['Taipei']),
  geoCountry('VN', '🇻🇳', 'Вьетнам', 'Vietnam', ['Hanoi']),
  geoCountry('TH', '🇹🇭', 'Таиланд', 'Thailand', ['Bangkok']),
  geoCountry('ID', '🇮🇩', 'Индонезия', 'Indonesia', ['Jakarta']),
  geoCountry('PH', '🇵🇭', 'Филиппины', 'Philippines', ['Manila']),
  geoCountry('NZ', '🇳🇿', 'Новая Зеландия', 'New Zealand', ['Auckland'])
];

function geoLc(s) { return String(s).toLowerCase(); }

// Строка BLOCK (или exclude-filter из config.yaml) -> слова: режем по |,
// срезаем пробелы и префикс "(?i)" (в BLOCK он не нужен и ломал поиск).
function geoSplit(s) {
  return String(s || '').split('|').map(function (t) {
    return t.trim().replace(/^\(\?i\)/, '').trim();
  }).filter(function (t) { return t !== ''; });
}

// Текст поля "Свои слова": по слову на строку (| внутри строки тоже делит).
function geoCustomList(text) {
  return geoSplit(String(text || '').replace(/\r?\n/g, '|'));
}

// Страна отмечена, если в строке есть её флаг; все её слова уходят из
// "своих", остальные слова остаются как есть.
function geoParse(s) {
  var tokens = geoSplit(s);
  var have = {}, sel = {}, used = {};
  tokens.forEach(function (t) { have[geoLc(t)] = true; });
  GEO_CATALOG.forEach(function (c) {
    if (have[geoLc(c.flag)]) {
      sel[c.code] = true;
      c.words.forEach(function (w) { used[geoLc(w)] = true; });
    }
  });
  return {
    sel: sel,
    custom: tokens.filter(function (t) { return !used[geoLc(t)]; }),
    hadRegex: /(^|\|)\s*\(\?i\)/.test(String(s || ''))
  };
}

// Слова отмеченных стран (в порядке каталога), затем свои; дубликаты
// без учёта регистра убираются.
function geoBuild(sel, customList) {
  var seen = {}, out = [];
  function add(t) {
    var k = geoLc(t);
    if (k && !seen[k]) { seen[k] = true; out.push(t); }
  }
  GEO_CATALOG.forEach(function (c) { if (sel[c.code]) { c.words.forEach(add); } });
  customList.forEach(add);
  return out;
}

// Замечания к фильтру. kind: 'err' - сервер не примет, 'important' -
// Россия не выбрана, 'warn' - слово, скорее всего, работает не так,
// как задумано, 'info' - к сведению. Сохранять мешает только 'err'.
function geoWarnings(sel, customList, hadRegex) {
  var out = [], owner = {};
  GEO_CATALOG.forEach(function (c) {
    c.words.forEach(function (w) { if (!owner[geoLc(w)]) { owner[geoLc(w)] = c; } });
  });
  if (geoBuild(sel, customList).length === 0) {
    out.push({ kind: 'err', text: 'Фильтр пуст - сохранить нельзя.' });
  }
  if (!sel.RU) {
    out.push({ kind: 'important', text: 'Россия не выбрана - российская нода может выиграть замер по пингу.' });
  }
  customList.forEach(function (t) {
    if (/[\\^$*+?()[\]{}]/.test(t)) {
      out.push({ kind: 'warn', text: '«' + t + '» похоже на регулярное выражение. Символы ищутся буквально, так что правило, скорее всего, не сработает.' });
    } else if (/^[A-Za-z]{1,3}$/.test(t)) {
      var isRu = geoLc(t) === 'ru';
      out.push({ kind: 'warn', text: '«' + t + '» слишком короткое: совпадёт и там, где эти буквы стоят внутри слова' +
        (isRu ? ' (Brussels, Peru, Truckee).' + (sel.RU ? ' Для России уже есть RU- и RU_.' : '') : '.') });
    }
    var o = owner[geoLc(t)];
    if (o && sel[o.code]) {
      out.push({ kind: 'info', text: '«' + t + '» уже входит в страну «' + o.ru + '» - строку можно удалить.' });
    }
  });
  if (hadRegex) {
    out.push({ kind: 'info', text: 'Префикс (?i) убран: здесь это не регулярное выражение, регистр и так не важен, а с префиксом первое слово не находилось.' });
  }
  return out;
}
// GEO-LOGIC-END

var GEO_WARN_TAGS = { err: 'ОШИБКА', important: 'ВАЖНО', warn: 'ВНИМАНИЕ', info: 'ИНФО' };

// Карточка формы настроек. Готовую строку кладёт в скрытое поле
// geo_filter - API /api/settings и серверная валидация не меняются.
function buildGeoFilterCard(saved, candidates) {
  var c = card('Какие ноды не проверять');
  c.appendChild(el('p', 'hint', 'Спидтест пропускает ноду, если в её имени есть любое из слов ниже. Регистр не важен. ' +
    'Обязательно исключите Россию - иначе российская нода может выиграть замер по пингу. ' +
    'На основное ядро (config.yaml) эта настройка не влияет.'));

  var hidden = el('input');
  hidden.type = 'hidden';
  hidden.name = 'geo_filter';
  hidden.id = 'geo_filter';
  c.appendChild(hidden);

  var savedSet = {};
  geoSplit(saved).forEach(function (t) { savedSet[geoLc(t)] = true; });
  var st = { sel: {}, loadedRegex: false };
  var boxes = {};

  // --- кнопки "Заполнить из config.yaml" / "Вернуть сохранённое" ---
  var tools = el('div', 'geo-tools');
  var candSelect = null;
  candidates = candidates || [];
  if (candidates.length) {
    if (candidates.length > 1) {
      candSelect = el('select');
      candSelect.setAttribute('aria-label', 'Вариант exclude-filter из config.yaml');
      candidates.forEach(function (cand, i) {
        var o = el('option', null, 'Вариант ' + (i + 1) + ': ' + (cand.length > 60 ? cand.slice(0, 60) + '…' : cand));
        o.value = String(i);
        candSelect.appendChild(o);
      });
      tools.appendChild(candSelect);
    }
    var fillBtn = el('button', 'small', 'Заполнить из config.yaml');
    fillBtn.type = 'button';
    fillBtn.addEventListener('click', function () {
      var cand = candidates[candSelect ? Number(candSelect.value) : 0];
      load(cand, 'Форма заполнена из exclude-filter в config.yaml. Проверьте итог и сохраните.');
    });
    tools.appendChild(fillBtn);
  }
  var resetBtn = el('button', 'small muted', 'Вернуть сохранённое');
  resetBtn.type = 'button';
  resetBtn.addEventListener('click', function () { load(saved, 'Возвращено сохранённое значение.'); });
  tools.appendChild(resetBtn);
  c.appendChild(tools);

  var flash = el('p', 'msg-ok geo-flash');
  flash.hidden = true;
  c.appendChild(flash);

  // --- страны ---
  var searchLabel = el('label', null, 'Страны');
  searchLabel.setAttribute('for', 'geo_search');
  c.appendChild(searchLabel);
  var search = el('input', 'geo-search');
  search.type = 'text';
  search.id = 'geo_search';
  search.placeholder = 'Найти страну: Россия, Japan…';
  search.autocomplete = 'off';
  c.appendChild(search);

  function group(title, list) {
    var head = el('div', 'geo-group-title');
    var grid = el('div', 'geo-grid');
    list.forEach(function (country) {
      var lab = el('label', 'geo-country');
      var cb = el('input');
      cb.type = 'checkbox';
      cb.addEventListener('change', function () {
        if (cb.checked) { st.sel[country.code] = true; } else { delete st.sel[country.code]; }
        flash.hidden = true;
        update();
      });
      lab.appendChild(cb);
      lab.appendChild(el('span', 'geo-flag', country.flag));
      lab.appendChild(el('span', 'geo-name', country.ru));
      lab.appendChild(el('span', 'geo-code', country.code));
      grid.appendChild(lab);
      boxes[country.code] = { cb: cb, label: lab, country: country };
    });
    c.appendChild(head);
    c.appendChild(grid);
    return { title: title, head: head, grid: grid, list: list };
  }
  var groups = [
    group('Обычно исключают', GEO_CATALOG.filter(function (x) { return x.common; })),
    group('Другие страны', GEO_CATALOG.filter(function (x) { return !x.common; }))
  ];
  var noMatch = el('p', 'hint', 'Страна не найдена в списке - её можно добавить словом в поле ниже.');
  noMatch.hidden = true;
  c.appendChild(noMatch);

  search.addEventListener('input', function () {
    var q = geoLc(search.value.trim());
    var shown = 0;
    groups.forEach(function (g) {
      var inGroup = 0;
      g.list.forEach(function (country) {
        var hit = !q || geoLc(country.code).indexOf(q) >= 0 ||
          country.words.some(function (w) { return geoLc(w).indexOf(q) >= 0; });
        boxes[country.code].label.hidden = !hit;
        if (hit) { inGroup++; }
      });
      g.head.hidden = g.grid.hidden = inGroup === 0;
      shown += inGroup;
    });
    noMatch.hidden = shown > 0;
  });

  // --- свои слова и замечания ---
  var cols = el('div', 'geo-cols');
  var left = el('div');
  var taLabel = el('label', null, 'Свои слова - по одному на строку');
  taLabel.setAttribute('for', 'geo_custom');
  left.appendChild(taLabel);
  var customTa = el('textarea');
  customTa.id = 'geo_custom';
  customTa.rows = 7;
  customTa.addEventListener('input', function () { flash.hidden = true; update(); });
  left.appendChild(customTa);
  left.appendChild(el('p', 'hint', 'Например: whitelist, Обход, RU- . Слово ищется как есть, без регулярных выражений.'));
  var right = el('div');
  right.appendChild(el('label', null, 'Проверка'));
  var warnBox = el('div');
  right.appendChild(warnBox);
  cols.appendChild(left);
  cols.appendChild(right);
  c.appendChild(cols);

  // --- итог ---
  var summary = el('div', 'geo-summary');
  var countLine = el('div');
  summary.appendChild(countLine);
  var chips = el('div', 'geo-chips');
  summary.appendChild(chips);
  var removedLine = el('div', 'geo-chips');
  summary.appendChild(removedLine);
  summary.appendChild(el('p', 'hint', '+ и пунктир - слово добавится, зачёркнутое - исчезнет по сравнению с сохранённым.'));
  var details = el('details');
  details.appendChild(el('summary', null, 'Строка BLOCK, которая запишется в speedtest2.env'));
  var pre = el('pre');
  details.appendChild(pre);
  summary.appendChild(details);
  c.appendChild(summary);

  function update() {
    var custom = geoCustomList(customTa.value);
    var tokens = geoBuild(st.sel, custom);
    hidden.value = tokens.join('|');

    Object.keys(boxes).forEach(function (code) {
      var b = boxes[code];
      b.cb.checked = !!st.sel[code];
      b.label.classList.toggle('on', !!st.sel[code]);
    });
    groups.forEach(function (g) {
      var n = g.list.filter(function (x) { return st.sel[x.code]; }).length;
      g.head.textContent = g.title + ' · выбрано ' + n + ' из ' + g.list.length;
    });

    while (warnBox.firstChild) { warnBox.removeChild(warnBox.firstChild); }
    var hadRegex = st.loadedRegex || /\(\?i\)/.test(customTa.value);
    var warns = geoWarnings(st.sel, custom, hadRegex);
    if (!warns.length) { warnBox.appendChild(el('p', 'geo-warn', 'Замечаний нет.')); }
    warns.forEach(function (w) {
      var row = el('div', 'geo-warn ' + w.kind);
      row.appendChild(el('span', 'geo-warn-tag', GEO_WARN_TAGS[w.kind]));
      row.appendChild(el('span', null, w.text));
      warnBox.appendChild(row);
    });

    countLine.textContent = 'Будут пропущены ноды, в имени которых есть (слов: ' + tokens.length + '):';
    while (chips.firstChild) { chips.removeChild(chips.firstChild); }
    var nowSet = {};
    tokens.forEach(function (t) {
      nowSet[geoLc(t)] = true;
      var isNew = !savedSet[geoLc(t)];
      chips.appendChild(el('span', 'geo-chip' + (isNew ? ' new' : ''), (isNew ? '+ ' : '') + t));
    });
    while (removedLine.firstChild) { removedLine.removeChild(removedLine.firstChild); }
    var removed = geoSplit(saved).filter(function (t) { return !nowSet[geoLc(t)]; });
    removedLine.hidden = removed.length === 0;
    if (removed.length) {
      removedLine.appendChild(el('span', 'hint', 'Исчезнут:'));
      removed.forEach(function (t) { removedLine.appendChild(el('span', 'geo-chip removed', t)); });
    }
    pre.textContent = "BLOCK='" + hidden.value + "'";
  }

  function load(value, msg) {
    var p = geoParse(value);
    st.sel = p.sel;
    st.loadedRegex = p.hadRegex;
    customTa.value = p.custom.join('\n');
    flash.textContent = msg || '';
    flash.hidden = !msg;
    update();
  }

  load(saved, null);
  return c;
}

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
    hint: '0.25 = нода должна выдать хотя бы 25% скорости интернета без прокси.',
    help: [
      ['Что это', 'Главная настройка отбора. Нода попадает в быстрый пул, только если её скорость не ниже порога. Порог не задаётся числом раз и навсегда - он пересчитывается в каждом прогоне от скорости вашего интернета.'],
      ['Как работает', 'В начале каждого прогона роутер качает тестовый файл напрямую, без прокси, и получает скорость канала. Порог = скорость канала × эта доля, но не ниже значения «Порог скорости: не ниже».'],
      ['Пример', 'Канал 100 Мбит/с, доля 0.25 → порог 25 Мбит/с. Вечером канал просел до 60 Мбит/с → порог сам станет 15 Мбит/с, и пул не опустеет из-за того, что провайдер медленнее.'],
      ['Как выбрать', 'Больше (0.4-0.5) - в пул попадут только самые быстрые ноды, но их может оказаться мало. Меньше (0.1-0.15) - пул шире, но в него попадут и средние ноды.'],
      ['Связи', 'Если замер канала не удался (нет интернета напрямую), вместо этой формулы берётся «Запасной порог» из раздела «Дополнительно». Команда mihomo-speedtest recalibrate и переустановка пересчитывают запасной порог по этой доле.'],
      HELP_WHEN
    ]
  },
  min_floor_mb: {
    label: 'Порог скорости: не ниже, Мбит/с', type: 'number', min: 0, step: 'any',
    hint: 'Нижняя граница для порога выше. 0 = без границы.',
    help: [
      ['Что это', 'Страховка для порога «доля от канала»: какой бы медленной ни оказалась прямая скорость в момент замера, порог не опустится ниже этого числа.'],
      ['Пример', 'Доля 0.25, этот параметр 4 Мбит/с. Ночью канал намерился всего 8 Мбит/с (кто-то качал торрент) → 8 × 0.25 = 2, но порог станет 4 Мбит/с, и совсем медленные ноды в пул не пройдут.'],
      ['Как выбрать', 'Минимальная скорость, при которой вам ещё комфортно (видео, звонки). 0 - порог всегда равен доле от канала.'],
      HELP_WHEN
    ]
  },
  topn: {
    label: 'Сколько нод держать в быстром пуле (максимум)', type: 'number', min: 1, max: 50,
    hint: 'Самые быстрые ноды выше порога попадают в fast.yaml.',
    help: [
      ['Что это', 'Сколько нод-победителей записывается в fast.yaml. Из них Mihomo собирает группу «⚡ Быстрый пул» и сам выбирает внутри неё ноду с лучшим пингом, раз в минуту.'],
      ['Как работает', 'Все проверенные ноды выше порога сортируются по скорости, первые N становятся пулом. Если нод выше порога меньше - пул будет меньше (см. «Минимум нод в быстром пуле»).'],
      ['Пример', 'Значение 15, выше порога оказалось 22 ноды → в пул попадут 15 самых быстрых. Оказалось 6 → в пул попадут 6.'],
      ['Как выбрать', 'Больше - группе есть из чего выбирать, если нода упадёт между прогонами. Меньше - в пуле только лучшие. 10-20 подходит большинству.'],
      ['Связи', 'Прогон перестаёт проверять ноды, как только найдено «Остановиться, когда найдено быстрых нод». Если это число меньше, чем здесь, пул никогда не заполнится полностью - держите его не меньше этого значения.'],
      HELP_WHEN
    ]
  },
  min_winners: {
    label: 'Минимум нод в быстром пуле', type: 'number', min: 0, max: 50,
    hint: 'Если быстрых нод мало - добираем самыми быстрыми из остальных. 0 = не добирать.',
    help: [
      ['Что это', 'Защита от пустого пула. Если нод выше порога набралось меньше этого числа, пул добирается самыми быстрыми из рабочих нод ниже порога.'],
      ['Пример', 'Значение 3, выше порога прошла только 1 нода → в пул попадут она и ещё 2 самые быстрые из остальных, даже если они медленнее порога. Ноды, которые вообще не скачали файл, не добираются никогда.'],
      ['Как выбрать', '2-3 обычно достаточно: пул из одной ноды перестаёт работать, как только она упадёт. 0 - в пул попадают только ноды выше порога, даже если это значит пустой пул (тогда остаётся прошлый fast.yaml).'],
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
  { geo: true }, // своя карточка - buildGeoFilterCard()
  { title: 'Быстрый пул: какие ноды в него попадают', fields: ['min_ratio', 'min_floor_mb', 'topn', 'min_winners', 'stable_min_uptime', 'stable_lookback'] },
  { title: 'Сколько нод проверять за прогон', fields: ['max_tested', 'enough'] },
  { title: 'История и графики', fields: ['keep_runs', 'keep_days', 'node_cap'] },
  { title: 'Дополнительно', advanced: true, note: 'Редко нужные параметры. Значения по умолчанию подходят большинству.', fields: ['extype', 'size_mb', 'dl_timeout', 'min_speed_mb', 'stability_window', 'stability_drop_after', 'stable_min_runs'] }
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
    'Самые быстрые ноды выше порога записываются в fast.yaml - это группа «⚡ Быстрый пул» в Mihomo. Внутри неё Mihomo сам выбирает ноду с лучшим пингом.'
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
    if (cardDef.geo) {
      form.appendChild(buildGeoFilterCard(values.geo_filter || '', values.geo_filter_candidates));
      return;
    }
    var c;
    if (cardDef.advanced) {
      // Свёрнутый блок: поля внутри <details> всё равно уходят в POST.
      c = el('details', 'card settings-advanced');
      c.appendChild(el('summary', null, cardDef.title));
    } else {
      c = card(cardDef.title);
    }
    if (cardDef.note) { c.appendChild(el('p', 'hint', cardDef.note)); }
    cardDef.fields.forEach(function (name) {
      c.appendChild(buildField(name, values[name]));
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
