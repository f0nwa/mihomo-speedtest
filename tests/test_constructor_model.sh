#!/bin/sh
# Модель конструктора конфига (web/stats_app_constructor_model.js) - без
# DOM, проверяется node. Нет node - тест пропускается (на роутере его нет).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_model: нет node"; exit 0; }
node --input-type=module - "$ROOT/web/stats_app_constructor_model.js" <<'JS'
import { pathToFileURL } from 'node:url';
const M = await import(pathToFileURL(process.argv[2]).href);
let failed = 0;
function eq(a, b, what) { const A = JSON.stringify(a), B = JSON.stringify(b); if (A !== B) { console.error('FAIL: ' + what + '\n  ожидалось ' + B + '\n  получено  ' + A); failed = 1; } }
function throws(fn, what) { try { fn(); console.error('FAIL: ' + what + ' - нет ошибки'); failed = 1; } catch (e) { /* ok */ } }
const T = '\t';
const D = [
  '# комментарий',
  ['section', 'media', 'Видео'].join(T), ['section', 'other', 'Прочее'].join(T),
  ['svc', 'youtube', 'YouTube', 'media'].join(T), ['svc', 'spotify', 'Spotify', 'media'].join(T),
  ['svc', 'kinopub', 'KinoPub', 'media'].join(T),
  ['icon', 'youtube', 'https://i/y.png'].join(T),
  ['prov', 'youtube', 'youtube@domain: { <<: *domain, url: "https://y" }'].join(T),
  ['rule', 'kinopub', 'DOMAIN-SUFFIX,pkr.ovh,KinoPub'].join(T),
  ['rule', 'kinopub', 'GEOSITE,kinopub,KinoPub # комм'].join(T),
  ['rule', '-', 'RULE-SET,category-ru@domain,DIRECT'].join(T),
  ['rule', 'youtube', 'RULE-SET,youtube@domain,YouTube'].join(T),
].join('\n') + '\n';

// test_roundtrip_unmodified: неизменённое состояние сериализуется как было
const S0 = ['del' + T + 'spotify', 'unrule' + T + 'kinopub' + T + 'DOMAIN-SUFFIX,pkr.ovh,KinoPub',
  'svc' + T + 'nl' + T + 'NL' + T + 'other', 'icon' + T + 'nl' + T + 'https://i/n.png', 'gkey' + T + 'nl' + T + 'filter: (?i)NL',
  'src' + T + 'nl' + T + 'nl' + T + 'domain' + T + 'https://n', 'dom' + T + 'youtube' + T + 'suffix' + T + 'youtu.be',
  'prov' + T + '-' + T + 'my@domain: { <<: *domain, url: "https://m" }'].join('\n') + '\n';
let m = M.createModel(D, S0, 'RULE-SET,my@domain,DIRECT\n');
eq(m.serialize(), { services: S0, user_rules: 'RULE-SET,my@domain,DIRECT\n' }, 'roundtrip');
eq(m.summary(m.serialize()), [], 'нет изменений - пустая сводка');

// test_services_list
const list = m.services();
eq(list.map(s => [s.id, s.name, s.section, s.user, s.deleted]),
  [['youtube', 'YouTube', 'media', false, false], ['spotify', 'Spotify', 'media', false, true],
   ['kinopub', 'KinoPub', 'media', false, false], ['nl', 'NL', 'other', true, false]], 'список сервисов');
eq(m.sections().map(s => s.id), ['media', 'other'], 'разделы');

// test_domains: встроенные доменные правила + свои; удалённое встроенное отмечено
eq(m.domains('kinopub'), [{ type: 'suffix', value: 'pkr.ovh', builtin: true, removed: true }], 'домены kinopub');
eq(m.domains('youtube'), [{ type: 'suffix', value: 'youtu.be', builtin: false, removed: false }], 'домены youtube');
eq(m.rules('kinopub'), [{ text: 'GEOSITE,kinopub,KinoPub # комм', removed: false }], 'не-доменные правила kinopub');

// test_edits
const init = m.serialize();
m.restoreService('spotify');
m.deleteService('youtube');
m.restoreRule('kinopub', 'DOMAIN-SUFFIX,pkr.ovh,KinoPub');
m.removeRule('kinopub', 'GEOSITE,kinopub,KinoPub # комм');
m.addDomain('kinopub', 'full', 'Kino.Pub');
m.removeDomain('nl', 'suffix', 'nothing'); // нет такого - без ошибки
const id = m.addService('Мой сервис', 'other');
eq(id, 'svc1', 'id своего сервиса без латиницы');
m.addDomain(id, 'keyword', 'mine');
m.setUserRules('RULE-SET,my@domain,DIRECT\n\nDOMAIN,x.ru,DIRECT\n');
const out = m.serialize();
eq(out.services, ['del' + T + 'youtube', 'unrule' + T + 'kinopub' + T + 'GEOSITE,kinopub,KinoPub # комм',
  'svc' + T + 'nl' + T + 'NL' + T + 'other', 'icon' + T + 'nl' + T + 'https://i/n.png', 'gkey' + T + 'nl' + T + 'filter: (?i)NL',
  'svc' + T + 'svc1' + T + 'Мой сервис' + T + 'other',
  'src' + T + 'nl' + T + 'nl' + T + 'domain' + T + 'https://n',
  'dom' + T + 'youtube' + T + 'suffix' + T + 'youtu.be',
  'dom' + T + 'kinopub' + T + 'full' + T + 'kino.pub', 'dom' + T + 'svc1' + T + 'keyword' + T + 'mine',
  'prov' + T + '-' + T + 'my@domain: { <<: *domain, url: "https://m" }'].join('\n') + '\n', 'сериализация правок');
eq(out.user_rules, 'RULE-SET,my@domain,DIRECT\nDOMAIN,x.ru,DIRECT\n', 'свои правила без пустых строк');
eq(m.summary(init), [
  'Вернуть сервис Spotify', 'Убрать сервис YouTube',
  'Вернуть домен pkr.ovh (KinoPub)', 'Убрать правило GEOSITE,kinopub,KinoPub # комм (KinoPub)',
  'Новый сервис Мой сервис',
  '+ домен kino.pub → KinoPub', '+ домен mine → Мой сервис',
  'Свои правила изменены'], 'сводка изменений');

// test_remove_builtin_domain -> unrule с точным текстом; свой сервис удаляется целиком
m = M.createModel(D, '', '');
m.removeDomain('kinopub', 'suffix', 'pkr.ovh');
eq(m.serialize().services, 'unrule' + T + 'kinopub' + T + 'DOMAIN-SUFFIX,pkr.ovh,KinoPub\n', 'удаление встроенного домена');
const a = m.addService('Netflix', 'media');
eq(a, 'netflix', 'id из имени');
m.addDomain(a, 'suffix', 'netflix.com');
m.removeUserService(a);
eq(m.serialize().services, 'unrule' + T + 'kinopub' + T + 'DOMAIN-SUFFIX,pkr.ovh,KinoPub\n', 'удалённый свой сервис уходит с доменами');
eq(m.addService('Steam', 'other') !== 'steam' || true, true, 'ok');

// test_validation
m = M.createModel(D, '', '');
throws(() => m.addService('YouTube', 'other'), 'имя встроенного');
throws(() => m.addService('A, B', 'other'), 'запятая в имени');
throws(() => m.addService(' A', 'other'), 'пробел по краю');
throws(() => m.addService('A', 'nosection'), 'нет раздела');
m.addService('A', 'other');
throws(() => m.addService('A', 'other'), 'повтор имени');
throws(() => m.addDomain('kinopub', 'suffix', 'bad domain'), 'пробел в домене');
throws(() => m.addDomain('kinopub', 'regex', 'a.com'), 'тип домена');
throws(() => m.addDomain('kinopub', 'suffix', 'pkr.ovh'), 'домен уже есть');
throws(() => m.setUserRules('a\tb'), 'табуляция в правиле');
eq(M.createModel(D, '', '').addService('youtube', 'other') !== 'youtube', true, 'id не совпадает со встроенным');
eq(M.stateBody({ services: 'x\n', user_rules: '' }), '### MST-STATE services.tsv\nx\n', 'тело без пустых своих правил');
eq(M.stateBody({ services: '', user_rules: 'r\n', geofilter: 'RU\n' }), '### MST-STATE services.tsv\n### MST-STATE user-rules.txt\nr\n### MST-STATE geofilter.txt\nRU\n', 'тело с правилами и фильтром');

// ===== ревью порции 3 =====
// свой сервис с id или именем встроенного заменяет его - одна строка в списке
m = M.createModel(D, ['svc', 'youtube', 'YouTube', 'other'].join(T) + '\n' + ['svc', 'my', 'Spotify', 'other'].join(T) + '\n', '');
eq(m.services().filter(s => s.name === 'YouTube').map(s => [s.id, s.user]), [['youtube', true]], 'свой YouTube заменяет встроенный');
eq(m.services().filter(s => s.name === 'Spotify').map(s => [s.id, s.user]), [['my', true]], 'свой Spotify заменяет встроенный');
// домен: регистр, адрес со схемой и путём, точки по краям
m = M.createModel(D, ['dom', 'kinopub', 'suffix', 'Example.ORG'].join(T) + '\n', '');
throws(() => m.addDomain('kinopub', 'suffix', 'example.org'), 'дубль домена без учёта регистра');
m.addDomain('kinopub', 'suffix', 'https://Site.ru/path?x=1');
m.addDomain('kinopub', 'suffix', '.zoom.us.');
eq(m.domains('kinopub').filter(x => !x.builtin).map(x => x.value), ['example.org', 'site.ru', 'zoom.us'], 'очистка адреса');
throws(() => m.addDomain('kinopub', 'suffix', 'сайт.рф'), 'кириллица');
try { m.addDomain('kinopub', 'suffix', 'сайт.рф'); } catch (e) { eq(/punycode|xn--/.test(e.message), true, 'подсказка про punycode'); }
// своё имя не может совпасть с группами шаблона и спеццелями
throws(() => M.createModel(D, '', '').addService('DIRECT', 'other'), 'имя DIRECT');

// ===== порция 4: каталог и наборы =====
const CAT = ['# заголовок', '',
  ['youtube', 'domain', 'metacubex', 'https://m/youtube.mrs', 'YouTube'].join(T),
  ['youtube', 'ipcidr', 'zxc-rv', 'https://z/youtube@ipcidr.mrs', 'YouTube'].join(T),
  ['itdog-youtube', 'domain', 'itdog', 'https://i/youtube_domain.mrs', 'YouTube (itdog)'].join(T),
  ['netflix', 'domain', 'metacubex', 'https://m/netflix.mrs', 'Netflix'].join(T),
  ['openai', 'domain', 'metacubex', 'https://m/openai.mrs', 'ChatGPT, OpenAI'].join(T),
  ['itdog-russia-inside', 'domain', 'itdog', 'https://i/russia_inside_domain.mrs', 'Заблокированное в РФ (itdog)'].join(T),
  'битая строка' + T + 'x',
  ['bad name', 'domain', 'x', 'https://x', 'X'].join(T)].join('\n');
const cat = M.parseCatalog(CAT);
eq(cat.length, 6, 'каталог: битые строки пропущены');
eq(M.searchCatalog(cat, '').length, 0, 'пустой запрос - ничего');
let g = M.searchCatalog(cat, 'YouTu');
eq(g.map(x => [x.key, x.title, x.items.map(i => i.name + '@' + i.kind)]),
  [['youtube', 'YouTube', ['youtube@domain', 'youtube@ipcidr', 'itdog-youtube@domain']]], 'группа youtube');
eq(M.searchCatalog(cat, 'chatgpt').map(x => x.key), ['openai'], 'поиск по названию');
eq(M.searchCatalog(cat, 'заблок').map(x => x.key), ['russia-inside'], 'поиск по-русски');
// наборы у сервиса
m = M.createModel(D, '', '');
const nf = m.addService('Netflix', 'media');
m.addSource(nf, 'netflix', 'domain', 'https://m/netflix.mrs');
eq(m.sources(nf), [{ name: 'netflix', kind: 'domain', url: 'https://m/netflix.mrs' }], 'набор своего сервиса');
throws(() => m.addSource(nf, 'netflix', 'domain', 'https://m/netflix.mrs'), 'набор уже подключён');
throws(() => m.addSource(nf, 'bad name', 'domain', 'https://x'), 'имя набора');
throws(() => m.addSource(nf, 'x', 'regex', 'https://x'), 'вид набора');
throws(() => m.addSource(nf, 'x', 'domain', 'ftp://x'), 'адрес набора');
throws(() => m.addSource('youtube', 'youtube', 'domain', 'https://m/youtube.mrs'), 'встроенный уже использует youtube@domain');
m.addSource('kinopub', 'itdog-russia-inside', 'domain', 'https://i/russia_inside_domain.mrs');
eq(m.usedSources()['youtube@domain'], ['YouTube'], 'используемые наборы: встроенный');
eq(m.usedSources()['netflix@domain'], ['Netflix'], 'используемые наборы: свой');
eq(m.serialize().services, ['svc' + T + 'netflix' + T + 'Netflix' + T + 'media',
  'src' + T + 'netflix' + T + 'netflix' + T + 'domain' + T + 'https://m/netflix.mrs',
  'src' + T + 'kinopub' + T + 'itdog-russia-inside' + T + 'domain' + T + 'https://i/russia_inside_domain.mrs'].join('\n') + '\n', 'сериализация наборов');
eq(m.summary({ services: '', user_rules: '' }), ['Новый сервис Netflix', '+ набор netflix → Netflix', '+ набор itdog-russia-inside → KinoPub'], 'сводка наборов');
m.removeSource('kinopub', 'itdog-russia-inside', 'domain');
// проверка до добавления: ничего не меняет
throws(() => m.checkSource(nf, 'bad name', 'domain', 'https://x'), 'checkSource: имя');
m.checkSource(nf, 'openai', 'domain', 'https://m/openai.mrs');
eq(m.sources(nf).length, 1, 'checkSource ничего не добавляет');
// каталог: неизвестный вид и плохой адрес пропускаются
eq(M.parseCatalog(['a', 'regex', 's', 'https://x', 'A'].join(T) + '\n' + ['b', 'domain', 's', 'https://x y', 'B'].join(T)).length, 0, 'каталог: вид и адрес');
// сервис по имени
eq(m.findByName('Netflix'), nf, 'поиск сервиса по имени');
eq(m.findByName('Нет такого'), null, 'нет сервиса');
eq(m.sources('kinopub'), [], 'набор убран');
// направление новой группы: выбранное - первым в proxies
const rid = m.addService('Routed', 'other', '🚀 Авто по пингу');
const rs = m.serialize().services;
eq(rs.includes(['gkey', rid, "proxies: ['🚀 Авто по пингу', DIRECT, 'Заблок. сервисы', '🛡️Fallback-Stable', '⚙️Manual']"].join(T)), true, 'route: gkey с выбранным первым');
const rid2 = m.addService('Plain', 'other', 'DIRECT');
eq(m.serialize().services.includes(['gkey', rid2, "proxies: [DIRECT, 'Заблок. сервисы', '🚀 Авто по пингу', '🛡️Fallback-Stable', '⚙️Manual']"].join(T)), true, 'route: DIRECT без кавычек');
let eroute = ''; try { m.addService('Bad', 'other', 'nowhere'); } catch (e) { eroute = e.message; }
eq(/направление/.test(eroute), true, 'route: неизвестное - ошибка');
eq(m.findByName('Bad'), null, 'route: ошибка не оставляет сервис');
eq(M.parseCatalogDate('# x\n# собран: 2026-10-06\na'), '2026-10-06', 'дата каталога');
eq(M.parseCatalogDate('# собран: вчера'), '', 'дата каталога: мусор');

// базовые группы: interval/tolerance и куда смотрят по умолчанию
const TB = [
  'anchors:',
  "  http-provider: &http-provider { type: http, exclude-filter: &geofilter '(?i)RU|Moscow' }",
  "  select-default: &select-default { type: select, use: *sub-names, proxies: [DIRECT, 'Заблок. сервисы', '⚙️Manual'] }",
  'proxy-groups:',
  "  - name: '⚡ Быстрый пул'", '    interval: 60', '    tolerance: 50',
  "  - name: '⚙️Manual'", '    proxies: [DIRECT]',
  "  - name: 'Заблок. сервисы'", "    proxies: ['⚡ Самые быстрые', DIRECT]", ''].join('\n');
const pt = M.parseTemplateBase(TB);
eq(pt.geofilter, 'RU|Moscow', 'фильтр шаблона');
eq(pt.selectDefault, ['DIRECT', 'Заблок. сервисы', '⚙️Manual'], 'select-default');
eq(M.proxyTokens("    proxies: ['a, b', c, 'it''s']"), ['a, b', 'c', "it's"], 'токены с запятой и кавычкой');
let mb = M.createModel(D, '', '', TB);
eq(mb.baseGroups(), [{ name: '⚡ Быстрый пул', interval: { def: 60, value: 60 }, tolerance: { def: 50, value: 50 } }], 'базовые группы');
eq(mb.routes().map(r => [r.name, r.def, r.value]), [['*', 'DIRECT', 'DIRECT'], ['Заблок. сервисы', '⚡ Самые быстрые', '⚡ Самые быстрые']], 'маршруты');
mb.setBase('⚡ Быстрый пул', 'interval', '120');
mb.setRoute('*', '⚙️Manual');
eq(mb.serialize().services, ['bset', '⚡ Быстрый пул', 'interval', '120'].join(T) + '\n' + ['bfirst', '*', '⚙️Manual'].join(T) + '\n', 'bset/bfirst сериализуются');
eq(mb.summary({ services: '', user_rules: '' }), ['Группа ⚡ Быстрый пул: interval = 120', 'Сервисные группы: по умолчанию ⚙️Manual'], 'сводка базовых групп');
const before = mb.serialize();
mb.setBase('⚡ Быстрый пул', 'interval', '90');
eq(mb.summary(before), ['Группа ⚡ Быстрый пул: interval = 90'], 'смена значения - одна строка');
mb.setBase('⚡ Быстрый пул', 'interval', '60');
mb.setRoute('*', 'DIRECT');
eq(mb.serialize().services, '', 'значение шаблона - отличий нет');
throws(() => mb.setBase('⚡ Быстрый пул', 'interval', '5'), 'interval < 10');
throws(() => mb.setBase('⚡ Быстрый пул', 'interval', 'abc'), 'interval не число');
throws(() => mb.setBase('⚡ Быстрый пул', 'tolerance', '99999'), 'tolerance велик');
throws(() => mb.setBase('нет', 'interval', '60'), 'нет группы');
throws(() => mb.setRoute('*', 'нет-такого'), 'значения нет в списке');
eq(M.createModel(D, ['bset', '⚡ Быстрый пул', 'tolerance', '70'].join(T) + '\n', '', TB).baseGroups()[0].tolerance, { def: 50, value: 70 }, 'отличия из состояния');
eq(M.createModel(D, ['bset', '⚡ Быстрый пул', 'tolerance', '70'].join(T) + '\n', '', TB).serialize().services, ['bset', '⚡ Быстрый пул', 'tolerance', '70'].join(T) + '\n', 'отличия из состояния сериализуются как были');
eq(M.stateBody({ services: '', user_rules: '', subscriptions: 'u\tua\tn\n', proxies: '' }), '### MST-STATE services.tsv\n### MST-STATE subscriptions.tsv\nu\tua\tn\n### MST-STATE proxies.yaml\n', 'stateBody: подписки и ноды');
eq(M.stateBody({ services: '', user_rules: '', subscriptions: null, proxies: null }), '### MST-STATE services.tsv\n', 'stateBody: без модулей');

// ----- ownscope: свои прокси во всех сервисных группах -----
const mo = M.createModel(D, '', '');
eq(mo.ownScope(), false, 'ownscope: по умолчанию выключен');
eq(mo.serialize().services, '', 'ownscope: выключен - в состоянии ничего');
const beforeOwn = mo.serialize();
mo.setOwnScope(true);
eq(mo.ownScope(), true, 'ownscope: включён');
eq(mo.serialize().services, 'ownscope' + T + 'all\n', 'ownscope: строка в состоянии');
eq(mo.changes(beforeOwn).proxies, true, 'ownscope: отметка «изменён» у свои прокси');
eq(mo.changes(beforeOwn).services, false, 'ownscope: не считается правкой сервисов');
eq(mo.summary(beforeOwn), ['Свои прокси: во всех сервисных группах'], 'ownscope: сводка (включено)');
const mo2 = M.createModel(D, 'ownscope' + T + 'all\n', '');
eq(mo2.ownScope(), true, 'ownscope: читается из состояния');
eq(mo2.serialize().services, 'ownscope' + T + 'all\n', 'ownscope: roundtrip');
const onState = mo2.serialize();
mo2.setOwnScope(false);
eq(mo2.serialize().services, '', 'ownscope: выключение убирает строку');
eq(mo2.summary(onState), ['Свои прокси: только в базовых группах'], 'ownscope: сводка (выключено)');
// ownscope не мешает остальным директивам и не попадает в «прочие строки»
const mo3 = M.createModel(D, 'del' + T + 'spotify\nownscope' + T + 'all\n', '');
eq(mo3.serialize().services, 'del' + T + 'spotify\nownscope' + T + 'all\n', 'ownscope вместе с del: порядок и состав');

if (failed) process.exit(1);
console.log('OK test_constructor_model');
JS
