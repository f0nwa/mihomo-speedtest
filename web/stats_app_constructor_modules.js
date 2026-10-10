// Блоки конструктора конфига: «Подписки», «Свои прокси», «Исключения нод» и
// «Базовые группы». Логика - app-constructor-modules-model.js (подписки,
// ноды, фильтр) и app-constructor-model.js (базовые группы в отличиях
// сервисов); здесь только отрисовка. Применяется вместе с остальным
// конструктором (см. app-constructor.js): сборка на роутере, mihomo -t.

import { el, fetchJson } from './app-core.js';
import { UA_PRESETS } from './app-constructor-modules-model.js';

// ----- фильтр нод: страны и свои слова -----
// Один фильтр на всё: слова идут в exclude-filter подписок в config.yaml и в
// список нод, которые не проверяет спидтест (BLOCK в speedtest2.env) - сервер
// пишет BLOCK при применении конструктора. BLOCK - не regex, а список
// подстрок через | (см. prep.awk): нода пропускается, если её имя содержит
// любое слово без учёта регистра. Блок между метками GEO-LOGIC-BEGIN/END -
// чистые функции без DOM; tests/test_stats_geo_filter.sh вырезает его и
// проверяет в node.
// GEO-LOGIC-BEGIN
function geoCountry(code, flag, ru, en, extra, common) {
  return { code: code, flag: flag, ru: ru, words: [flag, en, ru].concat(extra || []), common: !!common };
}

// Наборы слов - только флаг и полные названия (у "других" стран ещё
// столица/хаб): голые 2-3-буквенные коды совпадали бы внутри чужих
// имён ("RU" - Brussels, Peru; "USA" - Jerusalem). У России - ещё
// привычные метки нод из шаблона (MSK/SPB оставлены сознательно).
export var GEO_CATALOG = [
  geoCountry('RU', '🇷🇺', 'Россия', 'Russia', ['RU-', 'RU_', 'Moscow', 'Москва', 'MSK', 'МСК', 'SPB', 'СПб'], true),
  geoCountry('UA', '🇺🇦', 'Украина', 'Ukraine', [], true),
  geoCountry('KZ', '🇰🇿', 'Казахстан', 'Kazakhstan', [], true),
  geoCountry('BY', '🇧🇾', 'Беларусь', 'Belarus', ['Minsk', 'Минск', 'Белоруссия'], true),
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
export function geoParse(s) {
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
export function geoBuild(sel, customList) {
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

// Панель фильтра нод: поиск по странам, две группы стран (обе раскрыты),
// свои слова с проверкой и итог относительно сохранённого. words - текущие
// слова, saved - сохранённые (для «+» и «исчезнут»); onChange(слова) зовётся
// при каждой правке пользователя (не при первой отрисовке).
function buildFilterPanel(words, saved, onChange) {
  var c = el('div', 'geo-panel');
  c.appendChild(el('p', 'hint', 'Ноды, в имени которых есть любое из слов ниже, не попадают в группы «Авто по пингу» и Fallback ' +
    '(exclude-filter подписок в config.yaml), и спидтест их не проверяет. Регистр не важен. ' +
    'Обязательно исключите Россию - иначе российская нода может выиграть замер по пингу.'));

  var savedSet = {};
  saved.forEach(function (t) { savedSet[geoLc(t)] = true; });
  var st = { sel: {}, loadedRegex: false };
  var boxes = {};
  var ready = false;

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
  customTa.setAttribute('aria-label', 'Свои слова фильтра');
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
  details.appendChild(el('summary', null, 'Строка фильтра: BLOCK в speedtest2.env, она же слова exclude-filter'));
  var pre = el('pre');
  details.appendChild(pre);
  summary.appendChild(details);
  c.appendChild(summary);

  function update() {
    var custom = geoCustomList(customTa.value);
    var tokens = geoBuild(st.sel, custom);

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
    var removed = saved.filter(function (t) { return !nowSet[geoLc(t)]; });
    removedLine.hidden = removed.length === 0;
    if (removed.length) {
      removedLine.appendChild(el('span', 'hint', 'Исчезнут:'));
      removed.forEach(function (t) { removedLine.appendChild(el('span', 'geo-chip removed', t)); });
    }
    pre.textContent = "BLOCK='" + tokens.join('|') + "'";
    if (ready) { onChange(tokens); }
  }

  var p = geoParse(words.join('|'));
  st.sel = p.sel;
  st.loadedRegex = p.hadRegex;
  customTa.value = p.custom.join('\n');
  update();
  ready = true;
  return c;
}

function button(text, cls) {
  var b = el('button', cls || 'small', text);
  b.type = 'button';
  return b;
}

// Русское число с существительным: plural(3, 'подписка', 'подписки', 'подписок').
export function plural(n, one, few, many) {
  var m10 = n % 10, m100 = n % 100;
  var w = m10 === 1 && m100 !== 11 ? one : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? few : many);
  return n + ' ' + w;
}

// Раскладка конструктора: слева список модулей (название, краткая
// сводка, пометка «изменён»), справа содержимое выбранного модуля.
// add(num, title) добавляет модуль на место по номеру и возвращает
// {body, summary(текст), changed(bool), select()}.
export function createLayout(activeNum) {
  var root = el('div', 'cx-layout');
  var nav = el('nav', 'cx-nav');
  nav.setAttribute('aria-label', 'Модули конфига');
  var pane = el('div', 'cx-pane');
  root.appendChild(nav); root.appendChild(pane);
  var items = [];   // {num, btn, panel}
  var active = activeNum;

  function show() {
    items.forEach(function (it) {
      var on = it.num === active;
      it.panel.hidden = !on;
      it.btn.className = 'cx-nitem' + (on ? ' on' : '');
      it.btn.setAttribute('aria-current', on ? 'true' : 'false');
    });
  }

  function add(num, title) {
    var btn = el('button', 'cx-nitem');
    btn.type = 'button';
    var text = el('span', 'cx-ntext');
    var ttl = el('span', 'cx-btitle', title);
    var sum = el('span', 'cx-bsum', '');
    text.appendChild(ttl); text.appendChild(sum);
    var chg = el('span', 'cx-bchg', 'изменён'); chg.hidden = true;
    btn.appendChild(text); btn.appendChild(chg);
    var panel = el('section', 'cx-panel');
    panel.setAttribute('aria-label', title);
    panel.appendChild(el('h2', null, title));
    var body = el('div', 'cx-bbody');
    panel.appendChild(body);
    var it = { num: num, btn: btn, panel: panel };
    // место по номеру
    var at = 0;
    while (at < items.length && items[at].num < num) { at++; }
    items.splice(at, 0, it);
    nav.insertBefore(btn, nav.children[at] || null);
    pane.insertBefore(panel, pane.children[at] || null);
    function select() { active = num; show(); }
    btn.addEventListener('click', select);
    show();
    return {
      body: body,
      summary: function (t) { sum.textContent = t; },
      changed: function (on) { chg.hidden = !on; },
      select: select
    };
  }

  return { root: root, add: add };
}

function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }

function errText(err) {
  return err && err.data && err.data.message ? err.data.message : (err && err.message ? err.message : String(err));
}

// Адрес подписки содержит ключ доступа - в списке только домен.
function hostOf(url) {
  var m = /^https?:\/\/([^\/?#]+)/.exec(url || '');
  return m ? m[1] : '...';
}

var CUSTOM_UA = '__custom__';

// Выбор User-Agent: готовые значения, «без заголовка» и свой вариант.
// getUrl (необязательно) - откуда взять адрес подписки: тогда рядом кнопка
// «Определить», которая просит роутер перебрать типичные клиентские UA
// (/api/constructor/detect-ua, config-tools/detect_ua.sh) и подставляет
// первый, под которым панель отдаёт clash YAML или список нод.
export function uaField(value, getUrl) {
  var wrap = el('span', 'cx-ua');
  var sel = el('select');
  sel.setAttribute('aria-label', 'User-Agent');
  var opts = [['', 'без User-Agent']].concat(UA_PRESETS.map(function (u) { return [u, u]; })).concat([[CUSTOM_UA, 'другой...']]);
  opts.forEach(function (o) { var op = el('option', null, o[1]); op.value = o[0]; sel.appendChild(op); });
  var custom = el('input'); custom.type = 'text'; custom.placeholder = 'User-Agent';
  custom.setAttribute('aria-label', 'Свой User-Agent');
  function sync() { custom.hidden = sel.value !== CUSTOM_UA; }
  function set(v) {
    var known = opts.some(function (o) { return o[0] === v && o[0] !== CUSTOM_UA; });
    sel.value = known ? v : CUSTOM_UA;
    custom.value = known ? '' : v;
    sync();
  }
  sel.addEventListener('change', function () { sync(); if (!custom.hidden) { custom.focus(); } });
  set(value);
  wrap.appendChild(sel); wrap.appendChild(custom);
  wrap.value = function () { return sel.value === CUSTOM_UA ? custom.value.trim() : sel.value; };
  if (getUrl) { addDetect(wrap, getUrl, set); }
  return wrap;
}

// Кнопка «Определить» и строки результата под полем UA. Запросы идут на
// роутер: сначала перебор User-Agent (до нескольких минут), потом проверка,
// отвечают ли ноды выбранным UA (подписка качается ещё раз, ноды проверяет
// временное ядро); кнопка занята, пока идёт то и другое. Адрес уходит телом
// POST - ключ доступа не попадает в строку запроса и журналы.
function addDetect(wrap, getUrl, setUa) {
  var btn = button('Определить', 'small muted');
  btn.title = 'Проверить адрес под разными User-Agent, выбрать подходящий и проверить, отвечают ли ноды';
  var note = el('div', 'hint cx-ua-note');
  var probe = el('div', 'hint cx-ua-note');
  note.hidden = true; probe.hidden = true;
  wrap.appendChild(btn); wrap.appendChild(note); wrap.appendChild(probe);

  function put(node, text, kind) {
    clear(node);
    node.className = 'hint cx-ua-note' + (kind ? ' ' + kind : '');
    node.hidden = !text;
    if (text) { node.appendChild(document.createTextNode(text)); }
  }
  function say(text, kind) { put(note, text, kind); put(probe, '', ''); }
  function triedList(tried) {
    var d = el('details');
    d.appendChild(el('summary', null, 'Что вернула панель'));
    tried.forEach(function (t) { d.appendChild(el('div', null, t.ua + ' - HTTP ' + t.http + ', ' + t.bytes + ' байт, ' + t.kind)); });
    note.appendChild(d);
  }
  function post(route, body) {
    return fetchJson(route, { method: 'POST', body: body, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }

  // Итог проверки нод: отвечают, сервер отклоняет Reality-клиента Mihomo или не отвечают.
  function verdict(r) {
    if (r.verdict === 'alive') {
      put(probe, 'Ноды отвечают: ' + r.alive + ' из ' + r.tested + (r.total > r.tested ? ' проверенных (в подписке ' + r.total + ')' : '') + '.', 'msg-ok-text');
    } else if (r.verdict === 'reality_rejected') {
      put(probe, 'Подписка загружается, но ноды не отвечают: сервер отклоняет подключение Mihomo по REALITY' +
        (r.mlkem === 'false' ? ' (Mihomo не отправляет X25519MLKEM768, а новые версии Xray его требуют)' : '') +
        '. Другой User-Agent или отпечаток этого не исправят: те же ноды у клиентов на Xray (например Happ) могут работать, а в Mihomo нет. См. раздел про REALITY в документации.', 'msg-err-text');
    } else {
      put(probe, 'Подписка загружается, но ни одна из ' + r.tested + ' нод не ответила (сервер недоступен или режется сетью). Проверка могла попасть на временный сбой: повторите позже.', 'msg-err-text');
    }
  }

  btn.addEventListener('click', function () {
    var url = (getUrl() || '').trim();
    if (!url) { say('Сначала введите адрес подписки.', 'msg-err-text'); return; }
    btn.disabled = true; btn.textContent = 'Проверяю...';
    say('Перебираю User-Agent, это может занять до нескольких минут.', '');
    post('/api/constructor/detect-ua', url).then(function (d) {
      var tried = d.tried || [];
      if (!d.ua) {
        if (d.reason === 'unreachable') {
          say('Адрес не открылся: проверьте ссылку и доступ роутера в интернет.', 'msg-err-text');
        } else {
          say('Ни один из ' + tried.length + ' User-Agent не дал подходящий формат. Проверьте ссылку или выберите User-Agent вручную.', 'msg-err-text');
          if (tried.length) { triedList(tried); }
        }
        return null;
      }
      setUa(d.ua);
      say(d.quality === 'short'
        ? 'Выбран ' + d.ua + ': панель отдаёт только укороченный YAML, после применения сверьте набор нод.'
        : 'Выбран ' + d.ua + ': ' + d.kind + '.', d.quality === 'short' ? '' : 'msg-ok-text');
      put(probe, 'Проверяю, отвечают ли ноды...', '');
      // Сбой самой проверки нод не отменяет найденный User-Agent.
      return post('/api/constructor/probe-nodes', url + '\n' + d.ua).then(verdict, function (err) {
        put(probe, 'Проверить, отвечают ли ноды, не удалось: ' + errText(err), '');
      });
    }, function (err) {
      say('Не удалось определить: ' + errText(err), 'msg-err-text');
    }).then(function () { btn.disabled = false; btn.textContent = 'Определить'; });
  });
}

// ctx: {layout, mods, model, savedWords, edit(fn), msg(text, kind), redraw(), changed()}.
// Возвращает {cards, blocks, render, markChanged}: блоки созданы один раз,
// render() перерисовывает содержимое и сводки, markChanged(ch) - пометки
// «изменён» ({subs, proxies, filter}).
export function createModuleCards(ctx) {
  var mods = ctx.mods, model = ctx.model;

  // ----- подписки -----
  var subsBlk = ctx.layout.add(1, 'Подписки'), subsCard = subsBlk.body;
  subsCard.appendChild(el('p', 'hint', 'Ссылки на подписки с нодами. Адрес содержит ключ доступа, поэтому в списке виден только домен. ' +
    'User-Agent выбирает формат ответа панели: для Mihomo нужен clash-YAML. Не знаете, какой выбрать, - нажмите «Определить», роутер проверит адрес сам.'));
  var subsHost = el('div');
  subsCard.appendChild(subsHost);
  var editingSub = null;

  function subRow(s) {
    if (editingSub === s.name) { return subEditor(s); }
    var r = el('div', 'xk-row cx-row');
    r.appendChild(el('span', 'xk-val', s.name));
    r.appendChild(el('span', 'geo-code', hostOf(s.url) + (s.ua ? ' · ' + s.ua : '')));
    var ed = button('Изменить', 'small muted');
    ed.addEventListener('click', function () { editingSub = s.name; render(); });
    var rm = button('Убрать', 'small muted');
    rm.addEventListener('click', function () { ctx.edit(function () { mods.removeSub(s.name); }); });
    r.appendChild(ed); r.appendChild(rm);
    return r;
  }

  function subEditor(s) {
    var r = el('div', 'cx-editor');
    var url = el('input'); url.type = 'text'; url.value = s.url; url.setAttribute('aria-label', 'Адрес подписки');
    var name = el('input'); name.type = 'text'; name.value = s.name; name.setAttribute('aria-label', 'Имя подписки');
    var ua = uaField(s.ua, function () { return url.value; });
    var row = el('div', 'xk-add');
    var ok = button('Сохранить', 'submit'), cancel = button('Отмена', 'submit secondary');
    ok.addEventListener('click', function () {
      ctx.edit(function () { mods.editSub(s.name, { url: url.value, name: name.value, ua: ua.value() }); editingSub = null; });
    });
    cancel.addEventListener('click', function () { editingSub = null; render(); });
    r.appendChild(el('label', null, 'Адрес')); r.appendChild(url);
    r.appendChild(el('label', null, 'Имя (латиница, цифры, - и _)')); r.appendChild(name);
    r.appendChild(el('label', null, 'User-Agent')); r.appendChild(ua);
    row.appendChild(ok); row.appendChild(cancel);
    r.appendChild(row);
    return r;
  }

  function renderSubs() {
    clear(subsHost);
    var rows = el('div', 'xk-rows');
    var list = mods.subs();
    list.forEach(function (s) { rows.appendChild(subRow(s)); });
    if (!list.length) { rows.appendChild(el('div', 'xk-empty', 'Подписок нет.')); }
    subsHost.appendChild(rows);
    var add = el('div', 'cx-editor');
    var url = el('input'); url.type = 'text'; url.placeholder = 'https://...'; url.setAttribute('aria-label', 'Адрес новой подписки');
    var name = el('input'); name.type = 'text'; name.placeholder = 'имя (необязательно)'; name.setAttribute('aria-label', 'Имя подписки');
    var ua = uaField(UA_PRESETS[0], function () { return url.value; });
    var btn = button('Добавить подписку', 'submit');
    btn.addEventListener('click', function () {
      ctx.edit(function () { mods.addSub(url.value, ua.value(), name.value); });
    });
    url.addEventListener('keydown', function (e) { if (e.key === 'Enter') { btn.click(); } });
    add.appendChild(el('div', 'geo-group-title', 'Новая подписка'));
    add.appendChild(url);
    var row = el('div', 'xk-add');
    row.appendChild(name); row.appendChild(ua); row.appendChild(btn);
    add.appendChild(row);
    subsHost.appendChild(add);
  }

  // ----- свои прокси -----
  var proxBlk = ctx.layout.add(2, 'Свои прокси'), proxCard = proxBlk.body;
  proxCard.appendChild(el('p', 'hint', 'Свои ноды (Hysteria2, VLESS, Trojan, Shadowsocks, VMess, WireGuard/AmneziaWG). ' +
    'Они сами попадают в группы «Авто по пингу», Fallback и Manual. Пароли и ключи в списке не показываются.'));
  var proxHost = el('div');
  proxCard.appendChild(proxHost);

  function renameProxy(p) {
    var to = window.prompt('Новое имя ноды', p.name);
    if (to === null) { return; }
    ctx.edit(function () { mods.renameProxy(p.name, to); });
  }

  // Вставленный текст: ссылки по одной в строке или YAML нод. Возвращает
  // {added, errs, rest}: сколько нод добавлено, ошибки по строкам и строки,
  // которые не добавились (остаются в поле для правки).
  function addPasted(text) {
    var t = String(text || '');
    if (!t.trim()) { throw new Error('Вставьте ссылку на ноду (hy2://, vless://, trojan://, ss://, vmess://) или YAML'); }
    if (/^\s*-\s/m.test(t) || /^\s*name:/m.test(t)) {
      return { added: mods.addProxyYaml(t).length, errs: [], rest: [] };
    }
    var res = { added: 0, errs: [], rest: [] };
    t.split(/\r?\n/).forEach(function (l, i) {
      var line = l.trim();
      if (!line) { return; }
      try { mods.addProxyLink(line); res.added++; } catch (e) { res.errs.push('строка ' + (i + 1) + ': ' + e.message); res.rest.push(line); }
    });
    return res;
  }

  var proxDraft = '';

  function renderProxies() {
    clear(proxHost);
    var rows = el('div', 'xk-rows');
    var list = mods.proxies();
    list.forEach(function (p) {
      var r = el('div', 'xk-row cx-row');
      r.appendChild(el('span', 'xk-val', p.name));
      r.appendChild(el('span', 'geo-code', (p.type || '?') + (p.server ? ' · ' + p.server + (p.port ? ':' + p.port : '') : '')));
      var rn = button('Имя', 'small muted'); rn.setAttribute('aria-label', 'Переименовать ' + p.name);
      rn.addEventListener('click', function () { renameProxy(p); });
      var rm = button('Убрать', 'small muted');
      rm.addEventListener('click', function () { ctx.edit(function () { mods.removeProxy(p.name); }); });
      r.appendChild(rn); r.appendChild(rm);
      rows.appendChild(r);
    });
    if (!list.length) { rows.appendChild(el('div', 'xk-empty', 'Своих нод нет - работают только подписки.')); }
    proxHost.appendChild(rows);

    var area = el('textarea', 'xk-text');
    area.rows = 3;
    area.placeholder = 'Вставьте ссылку hy2:// vless:// trojan:// ss:// vmess:// (по одной в строке) или YAML ноды';
    area.setAttribute('aria-label', 'Ссылки или YAML нод');
    area.value = proxDraft;
    area.addEventListener('input', function () { proxDraft = area.value; });
    var row = el('div', 'btn-row');
    var add = button('Добавить', 'submit');
    add.addEventListener('click', function () {
      var res = null;
      try { res = addPasted(area.value); } catch (e) { ctx.msg(e.message, 'err'); return; }
      proxDraft = res.rest.join('\n');
      ctx.redraw();
      if (res.errs.length) { ctx.msg((res.added ? 'Добавлено нод: ' + res.added + '. ' : '') + 'Не добавлено - ' + res.errs.join('; '), 'err'); }
      else { ctx.msg('Добавлено нод: ' + res.added, 'ok'); }
    });
    var file = el('input'); file.type = 'file'; file.accept = '.conf'; file.multiple = true; file.hidden = true;
    file.setAttribute('aria-label', 'WireGuard .conf');
    var wg = button('из .conf файла', 'submit secondary');
    wg.title = 'WireGuard или AmneziaWG (формат wg-quick); имя ноды - по имени файла';
    wg.addEventListener('click', function () { file.click(); });
    file.addEventListener('change', function () {
      var files = Array.prototype.slice.call(file.files || []);
      file.value = '';
      importConf(files);
    });
    row.appendChild(add); row.appendChild(wg); row.appendChild(file);
    proxHost.appendChild(area);
    proxHost.appendChild(row);
  }

  // .conf файлы -> ноды (перевод на роутере: wg_import.awk), по одному запросу.
  function importConf(files) {
    if (!files.length) { return; }
    var done = [], errs = [];
    var chain = Promise.resolve();
    files.forEach(function (f) {
      chain = chain.then(function () { return f.text(); }).then(function (text) {
        var name = f.name.replace(/\.conf$/i, '');
        return fetchJson('/api/constructor/wgconf', { method: 'POST', body: '### MST-WG ' + name + '\n' + text,
          headers: { 'Content-Type': 'text/plain; charset=utf-8' } }).then(function (r) {
          try { mods.addProxyYaml(r.yaml || ''); done.push(name); } catch (e) { errs.push(f.name + ': ' + e.message); }
        }, function (e) { errs.push(f.name + ': ' + errText(e)); });
      });
    });
    chain.then(function () {
      render(); ctx.changed();
      if (errs.length) { ctx.msg((done.length ? 'Добавлено: ' + done.join(', ') + '. ' : '') + 'Не добавлено - ' + errs.join('; '), 'err'); }
      else { ctx.msg('Добавлено: ' + done.join(', '), 'ok'); }
    });
  }

  // ----- исключения нод -----
  var filtBlk = ctx.layout.add(5, 'Исключения нод'), filtCard = filtBlk.body;
  var filtHost = el('div');
  filtCard.appendChild(filtHost);

  function renderFilter() {
    clear(filtHost);
    filtHost.appendChild(buildFilterPanel(mods.words(), ctx.savedWords, function (tokens) {
      // правки идут в модель без перерисовки блока (иначе поле теряло бы фокус)
      try { mods.setWords(tokens); mods.setFilterError(''); } catch (e) { mods.setFilterError(e.message); }
      ctx.changed();
      filtBlk.summary(filterSummary());
      reset.disabled = mods.isDefaultWords();
    }));
    var row = el('div', 'btn-row');
    var reset = button('Вернуть слова шаблона', 'submit secondary');
    reset.disabled = mods.isDefaultWords();
    reset.addEventListener('click', function () { ctx.edit(function () { mods.resetWords(); mods.setFilterError(''); }); });
    row.appendChild(reset);
    filtHost.appendChild(row);
  }

  function filterSummary() {
    var countries = Object.keys(geoParse(mods.words().join('|')).sel).length;
    return plural(countries, 'страна', 'страны', 'стран') + ', слов: ' + mods.words().length;
  }

  // ----- базовые группы -----
  var baseBlk = ctx.layout.add(6, 'Базовые группы'), baseCard = baseBlk.body;
  baseCard.appendChild(el('p', 'hint', 'Автовыбор нод и общий режим для сервисов. interval - как часто проверять ноды (секунды), ' +
    'tolerance - на сколько мс текущая нода может отставать от лучшей, прежде чем группа переключится. ' +
    'Для групп со всеми нодами подписок interval ниже 300 не ставьте (при 100+ нодах - 600).'));
  var baseHost = el('div');
  baseCard.appendChild(baseHost);

  function numField(group, key, info) {
    var wrap = el('label', 'cx-num');
    wrap.appendChild(el('span', null, key));
    var inp = el('input'); inp.type = 'text'; inp.inputMode = 'numeric'; inp.value = String(info.value);
    inp.setAttribute('aria-label', key + ' группы ' + group);
    inp.title = 'в шаблоне: ' + info.def;
    inp.addEventListener('change', function () {
      var v = inp.value.trim();
      ctx.edit(function () { model.setBase(group, key, v === '' ? String(info.def) : v); });
    });
    wrap.appendChild(inp);
    if (info.value !== info.def) { wrap.appendChild(el('span', 'hint', 'шаблон: ' + info.def)); }
    return wrap;
  }

  function renderBase() {
    clear(baseHost);
    var groups = model.baseGroups();
    var rows = el('div', 'xk-rows');
    groups.forEach(function (g) {
      var r = el('div', 'xk-row cx-row');
      r.appendChild(el('span', 'xk-val', g.name));
      if (g.interval) { r.appendChild(numField(g.name, 'interval', g.interval)); }
      if (g.tolerance) { r.appendChild(numField(g.name, 'tolerance', g.tolerance)); }
      rows.appendChild(r);
    });
    if (groups.length) { baseHost.appendChild(rows); }
    var routes = model.routes();
    if (routes.length) {
      baseHost.appendChild(el('div', 'geo-group-title', 'Что выбрано по умолчанию'));
      routes.forEach(function (rt) {
        var r = el('div', 'xk-row cx-row');
        r.appendChild(el('span', 'xk-val', rt.label));
        var sel = el('select'); sel.setAttribute('aria-label', 'По умолчанию: ' + rt.label);
        rt.tokens.forEach(function (tk) { var o = el('option', null, tk); o.value = tk; sel.appendChild(o); });
        sel.value = rt.value;
        sel.addEventListener('change', function () { ctx.edit(function () { model.setRoute(rt.name, sel.value); }); });
        r.appendChild(sel);
        if (rt.value !== rt.def) { r.appendChild(el('span', 'hint', 'шаблон: ' + rt.def)); }
        baseHost.appendChild(r);
      });
      baseHost.appendChild(el('p', 'hint', 'Это значение до первого ручного выбора: в панели Mihomo группу по-прежнему можно переключить, ' +
        'выбор запоминается (store-selected).'));
    }
    if (!groups.length && !routes.length) { baseHost.appendChild(el('div', 'xk-empty', 'Шаблон не отдал базовые группы.')); }
  }

  function render() {
    renderSubs(); renderProxies(); renderFilter(); renderBase();
    subsBlk.summary(plural(mods.subs().length, 'подписка', 'подписки', 'подписок'));
    proxBlk.summary(plural(mods.proxies().length, 'нода', 'ноды', 'нод'));
    filtBlk.summary(filterSummary());
    baseBlk.summary(plural(model.baseGroups().length, 'группа', 'группы', 'групп'));
  }

  function markChanged(ch) {
    subsBlk.changed(ch.subs); proxBlk.changed(ch.proxies); filtBlk.changed(ch.filter);
  }

  return {
    blocks: { subs: subsBlk, proxies: proxBlk, filter: filtBlk, base: baseBlk },
    render: render,
    markChanged: markChanged
  };
}
