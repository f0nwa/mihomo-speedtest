#!/bin/sh
# Модель блоков «Подписки», «Свои прокси», «Исключения нод»
# (web/stats_app_constructor_modules_model.js) - без DOM, проверяется node.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_constructor_modules_model: нет node"; exit 0; }
node --input-type=module - "$ROOT/web/stats_app_constructor_modules_model.js" <<'JS'
import { pathToFileURL } from 'node:url';
const M = await import(pathToFileURL(process.argv[2]).href);
let failed = 0;
function eq(a, b, what) { const A = JSON.stringify(a), B = JSON.stringify(b); if (A !== B) { console.error('FAIL: ' + what + '\n  ожидалось ' + B + '\n  получено  ' + A); failed = 1; } }
function throws(fn, re, what) { try { fn(); console.error('FAIL: ' + what + ' - нет ошибки'); failed = 1; } catch (e) { if (re && !re.test(e.message)) { console.error('FAIL: ' + what + ' - не то сообщение: ' + e.message); failed = 1; } } }
const T = '\t';

// ----- подписки -----
const SUBS = ['https://a.example/T1' + T + 'v2rayNG/1.8.0' + T + 'a', 'https://b.example/T2' + T + T + 'b'].join('\n') + '\n';
const PROX = "  - name: '🇩🇪 Hysteria2'\n    type: hysteria2\n    server: de.example\n    port: 443\n";
let m = M.createModules({ subscriptions: SUBS, proxies: PROX, geofilter: null, geofilter_default: 'RU\nMoscow\n' });
eq(m.serialize(), { subscriptions: SUBS, proxies: PROX, geofilter: '' }, 'без правок - как было');
eq(m.summary(m.serialize()), [], 'без правок - пустая сводка');
eq(m.subs().map(s => s.name), ['a', 'b'], 'список подписок');
eq(m.addSub('https://www.my-panel.example.com/sub?x=1', '', ''), 'my-panel-example', 'имя подписки по адресу');
eq(m.addSub('https://www.my-panel.example.com/other', 'clash.meta', ''), 'my-panel-example-2', 'имя занято - номер');
throws(() => m.addSub('ftp://x', '', 'n1'), /http/, 'адрес не http');
throws(() => m.addSub('https://x"y', '', 'n1'), /кавычек/, 'кавычка в адресе');
throws(() => m.addSub('https://x/y', 'u"a', 'n1'), /User-Agent/, 'кавычка в UA');
throws(() => m.addSub('https://x/y', '', 'bad name'), /Имя подписки/, 'имя с пробелом');
throws(() => m.addSub('https://x/y', '', 'fast'), /fast/, 'имя fast');
throws(() => m.addSub('https://x/y', '', 'a'), /уже есть/, 'повтор имени');
m.removeSub('my-panel-example-2');
m.editSub('a', { url: 'https://a.example/NEW', name: 'a2' });
eq(m.subs().map(s => s.name + '=' + s.url), ['a2=https://a.example/NEW', 'b=https://b.example/T2', 'my-panel-example=https://www.my-panel.example.com/sub?x=1'], 'правка подписки');
throws(() => m.editSub('b', { name: 'a2' }), /уже есть/, 'переименование в занятое');
const sum = m.summary({ subscriptions: SUBS, proxies: PROX, geofilter: '' });
eq(sum, ['+ подписка a2', '+ подписка my-panel-example', 'Убрать подписку a'], 'сводка подписок');
eq(sum.join(' ').includes('T2') || sum.join(' ').includes('NEW'), false, 'адреса подписок не попадают в сводку');
eq(M.parseSubs('bad line\n\nu\tua\tn\n').length, 1, 'битая строка пропускается');

// ----- свои прокси -----
eq(m.proxies().map(p => [p.name, p.type, p.server, p.port]), [['🇩🇪 Hysteria2', 'hysteria2', 'de.example', '443']], 'список нод');
m.addProxyLink('hy2://p%40ss@nl.example:8443?sni=nl.example&obfs=salamander&obfs-password=ob&insecure=1&alpn=h3,h2#%F0%9F%87%B3%F0%9F%87%B1%20NL');
let nl = m.serialize().proxies;
eq(nl.includes("  - name: '🇳🇱 NL'\n    type: hysteria2\n    server: 'nl.example'\n    port: 8443\n    password: 'p@ss'\n    obfs: 'salamander'\n    obfs-password: 'ob'\n    sni: 'nl.example'\n    alpn: ['h3', 'h2']\n    skip-cert-verify: true\n    udp: true\n"), true, 'hy2 -> YAML');
// Имя занято (одинаковый #фрагмент у разных серверов, например "hy2"): вместо
// отказа к имени добавляется адрес сервера, а если и оно занято - номер.
eq(m.addProxyLink('hy2://p@nl2.example:8443#🇳🇱 NL'), '🇳🇱 NL nl2.example', 'повтор имени: добавлен адрес сервера');
eq(m.addProxyLink('hy2://p@nl2.example:9443#🇳🇱 NL'), '🇳🇱 NL-2', 'повтор имени и адреса: номер');
eq(m.addProxyLink('hy2://p@nl2.example:9444#🇳🇱 NL'), '🇳🇱 NL-3', 'третий повтор: следующий номер');
eq(m.addProxyLink('hy2://p@a.example:443#hy2'), 'hy2', 'первое hy2 без изменений');
eq(m.addProxyLink('hy2://p@b.example:443#hy2'), 'hy2 b.example', 'второе hy2 получает адрес сервера');
eq(m.addProxyLink('hy2://p@c.example:443'), 'c.example:443', 'без #фрагмента имя - адрес:порт');
eq(m.addProxyLink('hy2://p@c.example:443'), 'c.example:443-2', 'повтор адреса:порта - номер (адрес в имени уже есть)');
eq(m.proxies().filter(p => p.name === 'hy2 b.example')[0].server, 'b.example', 'нода записана под новым именем');
eq(m.serialize().proxies.includes("  - name: 'hy2 b.example'\n    type: hysteria2"), true, 'YAML ноды с новым именем');
// Длинное имя укладывается в 64 символа и после переименования
const longName = 'я'.repeat(64);
m.addProxyLink('hy2://p@l1.example:443#' + longName);
const longRes = m.addProxyLink('hy2://p@l2.example:443#' + longName);
eq(Array.from(longRes).length <= 64 && longRes.endsWith('l2.example') && longRes !== longName, true, 'длинное имя при повторе укладывается в 64');
['🇳🇱 NL nl2.example', '🇳🇱 NL-2', '🇳🇱 NL-3', 'hy2', 'hy2 b.example', 'c.example:443', 'c.example:443-2', longName, longRes].forEach(n => m.removeProxy(n));
// vless reality
let r = M.linkToProxy('vless://11111111-2222-3333-4444-555555555555@v.example:443?type=tcp&security=reality&sni=sni.example&fp=chrome&pbk=PUB&sid=ab&flow=xtls-rprx-vision#R1');
eq(r.yaml, "  - name: 'R1'\n    type: vless\n    server: 'v.example'\n    port: 443\n    uuid: '11111111-2222-3333-4444-555555555555'\n    flow: 'xtls-rprx-vision'\n    udp: true\n    tls: true\n    servername: 'sni.example'\n    client-fingerprint: 'chrome'\n    reality-opts: { public-key: 'PUB', short-id: 'ab' }\n    network: tcp\n", 'vless reality');
r = M.linkToProxy('vless://u@v.example:443?type=ws&security=tls&sni=s&path=%2Fws&host=h.example#W');
eq(r.yaml.includes("    network: ws\n    ws-opts: { path: '/ws', headers: { Host: 'h.example' } }\n"), true, 'vless ws');
r = M.linkToProxy('vless://u@v.example:443?type=grpc&security=tls&serviceName=svc#G');
eq(r.yaml.includes("grpc-opts: { grpc-service-name: 'svc' }"), true, 'vless grpc');
throws(() => M.linkToProxy('vless://u@v.example:443?security=reality#x'), /pbk/, 'reality без pbk');
throws(() => M.linkToProxy('vless://u@v.example:443?type=xhttp#x'), /не поддерживается/, 'xhttp');
// trojan
r = M.linkToProxy('trojan://pw@t.example:443?sni=t.example&type=ws&path=/p#T');
eq(r.yaml.startsWith("  - name: 'T'\n    type: trojan\n    server: 't.example'\n    port: 443\n    password: 'pw'\n    udp: true\n    tls: true\n    sni: 't.example'\n"), true, 'trojan');
// ss: SIP002 и старый формат
const cred = Buffer.from('aes-256-gcm:pass').toString('base64');
r = M.linkToProxy('ss://' + cred + '@s.example:8388#S1');
eq(r.yaml, "  - name: 'S1'\n    type: ss\n    server: 's.example'\n    port: 8388\n    cipher: 'aes-256-gcm'\n    password: 'pass'\n    udp: true\n", 'ss SIP002');
r = M.linkToProxy('ss://' + Buffer.from('aes-256-gcm:pass@s2.example:8389').toString('base64') + '#S2');
eq(r.yaml.includes("server: 's2.example'") && r.yaml.includes('port: 8389'), true, 'ss старый формат');
throws(() => M.linkToProxy('ss://' + cred + '@s.example:8388?plugin=obfs-local#S'), /плагин/, 'ss plugin');
// vmess
const vm = Buffer.from(JSON.stringify({ ps: 'VM', add: 'vm.example', port: '443', id: 'uuid-1', aid: '0', net: 'ws', tls: 'tls', host: 'h.example', path: '/v', sni: 'vm.example' })).toString('base64');
r = M.linkToProxy('vmess://' + vm);
eq(r.name, 'VM', 'vmess имя');
eq(r.yaml.includes("type: vmess") && r.yaml.includes("ws-opts: { path: '/v', headers: { Host: 'h.example' } }") && r.yaml.includes("servername: 'vm.example'"), true, 'vmess ws tls');
// безопасность ввода
throws(() => M.linkToProxy('hy2://p@bad host:1#x'), /адрес/i, 'пробел в адресе');
throws(() => M.linkToProxy('hy2://p@h.example:99999#x'), /порт/, 'порт вне диапазона');
throws(() => M.linkToProxy('hy2://p@h.example:443?sni=a%0Ab#x'), /управляющие/, 'перевод строки в параметре');
throws(() => M.linkToProxy('wireguard://x'), /не поддерживается/, 'чужая схема');
throws(() => M.linkToProxy('просто текст'), /Ссылка/, 'не ссылка');
// кавычка в пароле удваивается
eq(M.linkToProxy("hy2://it's@h.example:443#q").yaml.includes("password: 'it''s'"), true, 'кавычка в пароле');
// YAML
m.addProxyYaml("- name: Own\n  type: hysteria2\n  server: o.example\n  port: 443\n");
eq(m.proxies().map(p => p.name).includes('Own'), true, 'YAML без отступа');
eq(m.serialize().proxies.includes("  - name: Own\n    type: hysteria2\n"), true, 'YAML сдвинут на 2 пробела');
throws(() => m.addProxyYaml('type: x'), /Нужны записи/, 'YAML без нод');
throws(() => m.addProxyYaml("- type: x\n  name: y\n"), /name/, 'name не первым');
throws(() => m.addProxyYaml("- name: z\n\tport: 1\n"), /Табуляция/, 'табуляция');
// Повтор имени в YAML тоже переименовывается, а не отклоняется
eq(m.addProxyYaml("- name: Own\n  type: ss\n"), ['Own-2'], 'повтор имени в YAML: номер (адреса у ноды нет)');
eq(m.addProxyYaml("- name: Own\n  type: ss\n  server: srv.example\n"), ['Own srv.example'], 'повтор имени в YAML: адрес сервера');
m.removeProxy('Own-2'); m.removeProxy('Own srv.example');
throws(() => m.addProxyYaml("- name: Own\n  type: ss\n", true), /уже есть/, 'strict (WireGuard-импорт): повтор имени отклоняется');
m.renameProxy('Own', 'Own2');
eq(m.proxies().map(p => p.name).includes('Own2') && !m.proxies().map(p => p.name).includes('Own'), true, 'переименование');
throws(() => m.renameProxy('Own2', '🇩🇪 Hysteria2'), /уже есть/, 'переименование в занятое');
throws(() => m.renameProxy('Own2', 'a|b'), /Имя ноды/, 'имя с |');
m.removeProxy('Own2');
eq(m.proxies().map(p => p.name).includes('Own2'), false, 'удаление ноды');
const sum2 = m.summary({ subscriptions: SUBS, proxies: PROX, geofilter: '' });
eq(sum2.includes('+ нода 🇳🇱 NL'), true, 'сводка нод');
eq(sum2.join('\n').includes('p@ss') || sum2.join('\n').includes('password'), false, 'пароли не попадают в сводку');

// ----- исключения нод -----
eq(m.words(), ['RU', 'Moscow'], 'слова по умолчанию - из шаблона');
eq(m.isDefaultWords(), true, 'по умолчанию');
m.setWords(['RU', 'Moscow']);
eq(m.serialize().geofilter, '', 'те же слова - состояние пустое');
m.setWords(['RU', 'Moscow', 'Berlin', 'RU']);
eq(m.serialize().geofilter, 'RU\nMoscow\nBerlin\n', 'свои слова, без повторов');
eq(m.summary({ subscriptions: SUBS, proxies: PROX, geofilter: '' }).includes('Исключения нод изменены'), true, 'сводка фильтра');
throws(() => m.setWords([]), /пуст/, 'пустой фильтр');
throws(() => m.setWords(["a'b"]), /апостроф/, 'апостроф');
throws(() => m.setWords(['a|b']), /апостроф|\|/, 'вертикальная черта');
m.resetWords();
eq(m.serialize().geofilter, '', 'сброс к шаблону');
eq(M.createModules({ subscriptions: SUBS, proxies: PROX, geofilter: 'X\n', geofilter_default: 'RU\n' }).words(), ['X'], 'слова из состояния');

// ----- BLOCK спидтеста как исходный фильтр -----
const base = { subscriptions: SUBS, proxies: PROX, geofilter_default: 'RU\nMoscow\n' };
let mb = M.createModules({ ...base, geofilter: null, block: 'Russia|Berlin| rU ' });
eq(mb.fromBlock(), true, 'BLOCK отличается от шаблона - берётся');
eq(mb.words(), ['Russia', 'Berlin', 'rU'], 'слова из BLOCK');
eq(mb.serialize().geofilter, 'Russia\nBerlin\nrU\n', 'BLOCK уходит в состояние');
eq(mb.summary({ ...base, geofilter: mb.serialize().geofilter }), [], 'исходное состояние - без изменений');
mb.resetWords();
eq(mb.serialize().geofilter, '', 'сброс к шаблону после BLOCK');
eq(M.createModules({ ...base, geofilter: null, block: 'moscow|ru' }).fromBlock(), false, 'BLOCK = слова шаблона - не берётся');
eq(M.createModules({ ...base, geofilter: null, block: '' }).fromBlock(), false, 'BLOCK пуст');
eq(M.createModules({ ...base, geofilter: null }).fromBlock(), false, 'BLOCK не передан');
let ms = M.createModules({ ...base, geofilter: 'Own\n', block: 'Russia|Berlin' });
eq([ms.fromBlock(), ms.words()], [false, ['Own']], 'фильтр конструктора важнее BLOCK');

// ----- прочее -----
eq(M.createModules({ subscriptions: '', proxies: '', geofilter: null, geofilter_default: '' }).problems(), ['Нужна хотя бы одна подписка или своя нода'], 'ни подписок, ни нод');
eq(m.problems(), [], 'есть подписки - всё в порядке');
const none = M.createModules({ subscriptions: null, proxies: null, geofilter: null, geofilter_default: '' });
eq(none.serialize(), { subscriptions: null, proxies: null, geofilter: '' }, 'сервер не отдал подписки - блоки не передаются');
eq(none.problems(), [], 'нет данных - нет ошибок');

if (failed) process.exit(1);
console.log('OK test_constructor_modules_model');
JS
