#!/bin/sh
# Модель блоков «Подписки», «Прокси», «Исключения нод»
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
// HWID устройства: четвёртое поле "1" сохраняется при правках и в сводке
{
  const H = 'https://h.example/T' + T + 'FlClashX/0.3.2' + T + 'h' + T + '1\n';
  eq(M.parseSubs(H)[0].hwid, true, 'hwid из 4-го поля');
  eq(M.parseSubs('u' + T + 'ua' + T + 'n\n')[0].hwid, false, 'без 4-го поля - без hwid');
  const mh = M.createModules({ subscriptions: H, proxies: null, geofilter: null, geofilter_default: '' });
  eq(mh.serialize().subscriptions, H, 'hwid: без правок - как было');
  mh.editSub('h', { name: 'h2' });
  eq(mh.serialize().subscriptions, H.replace(T + 'h' + T, T + 'h2' + T), 'hwid: переименование сохраняет признак');
  mh.editSub('h2', { name: 'h', hwid: false });
  eq(mh.serialize().subscriptions, H.replace(T + '1\n', '\n'), 'hwid: снят');
  eq(mh.summary({ subscriptions: H }), ['Подписка h: выключен HWID устройства'], 'hwid: сводка');
  mh.addSub('https://n.example/T', 'Happ/4.11.0', 'n', true);
  eq(mh.subs().filter(x => x.name === 'n')[0].hwid, true, 'hwid: новая подписка');
}

// ----- свои прокси -----
eq(m.proxies().map(p => [p.name, p.type, p.server, p.port]), [['🇩🇪 Hysteria2', 'hysteria2', 'de.example', '443']], 'список нод');
const pendingProxies = "  - name: First\n    type: ss\n  - name: Middle\n    type: ss\n  - name: Last\n    type: ss\n";
const pending = M.createModules({ subscriptions: '', proxies: pendingProxies, geofilter: null, geofilter_default: '' });
pending.removeProxy('Middle');
eq(pending.proxyRows().map(p => [p.name, p.removed]), [['First', false], ['Middle', true], ['Last', false]], 'убранная нода остаётся на своём месте');
eq(pending.serialize().proxies, "  - name: First\n    type: ss\n  - name: Last\n    type: ss\n", 'убранная нода не попадает в проверяемый конфиг');
eq(pending.summary({ proxies: pendingProxies, subscriptions: '', geofilter: '' }), ['Убрать ноду Middle'], 'убранная нода указана в изменениях');
pending.restoreProxy('Middle');
eq(pending.proxyRows().map(p => [p.name, p.removed]), [['First', false], ['Middle', false], ['Last', false]], 'возвращённая нода остаётся на своём месте');
eq(pending.serialize().proxies, pendingProxies, 'возвращённая нода снова входит в конфиг');
eq(pending.summary({ proxies: pendingProxies, subscriptions: '', geofilter: '' }), [], 'возврат снимает изменение');
const lastOnly = M.createModules({ subscriptions: '', proxies: "  - name: Last\n    type: ss\n", geofilter: null, geofilter_default: '' });
lastOnly.removeProxy('Last');
eq(lastOnly.problems(), ['Нужна хотя бы одна подписка или своя нода'], 'последняя убранная нода не считается действующей');
lastOnly.restoreProxy('Last');
eq(lastOnly.problems(), [], 'возврат последней ноды снова разрешает применение');
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

// ----- редактор собственных AWG/TrustTunnel -----
// Ломающие изменения: пересборка всей ноды из известных полей, добавление
// defaults при правке одного поля, потеря комментариев и вложенных AWG-полей.
const EDITOR_PROX = "  - name: 'WG test'\n" +
  "    type: wireguard\n" +
  "    server: 192.0.2.1\n" +
  "    port: 51820\n" +
  "    ip: 10.0.0.2\n" +
  "    private-key: 'SECRET-WG-PRIVATE'\n" +
  "    mtu: 1400\n" +
  "    # параметры провайдера не трогаем\n\n" +
  "    persistent-keepalive: 0\n" +
  "    amnezia-wg-option:\n" +
  "      jc: 3\n" +
  "      I1: |\n" +
  "        <b 0x01>\n" +
  "  - name: 'TT test'\n" +
  "    type: trusttunnel\n" +
  "    server: 192.0.2.2\n" +
  "    port: 443\n" +
  "    username: test\n" +
  "    password: 'SECRET-TT-PASSWORD'\n" +
  "    sni: tt.example\n" +
  "    quic: false\n" +
  "    client-fingerprint: firefox\n" +
  "    alpn: ['h2', 'h3']\n" +
  "  - name: Neighbor\n" +
  "    type: ss\n" +
  "    server: neighbor.example\n" +
  "    password: 'NEIGHBOR-SECRET'\n";
const WG_BLOCK = EDITOR_PROX.slice(0, EDITOR_PROX.indexOf("  - name: 'TT test'"));
function editorModel(source) { return M.createModules({ subscriptions: '', proxies: source || EDITOR_PROX, geofilter: null, geofilter_default: '' }); }
const em = editorModel();
eq(em.serialize().proxies, EDITOR_PROX, 'редактор: no-op сохраняет комментарии и пустые строки');
eq(em.getProxyYaml('WG test'), WG_BLOCK, 'getProxyYaml возвращает полный исходный блок одной ноды');
eq(em.proxyOptions('WG test'), {
  ipv6: false,
  mtu: { present: true, supported: true, value: '1400' },
  keepalive: { present: true, supported: true, value: '0' },
  quic: { present: false, supported: true, value: false },
  fingerprint: { present: false, supported: true, value: '' },
  alpn: { present: false, supported: true, values: [] }
}, 'состояние формы AWG');
eq(em.proxyOptions('TT test'), {
  ipv6: false,
  mtu: { present: false, supported: true, value: '' },
  keepalive: { present: false, supported: true, value: '' },
  quic: { present: true, supported: true, value: false },
  fingerprint: { present: true, supported: true, value: 'firefox' },
  alpn: { present: true, supported: true, values: ['h2', 'h3'] }
}, 'состояние формы TrustTunnel');
em.updateProxyOptions('WG test', {});
eq(em.getProxyYaml('WG test'), WG_BLOCK, 'пустой patch не меняет блок побайтно');
em.updateProxyOptions('WG test', { mtu: 1280 });
eq(em.getProxyYaml('WG test'), WG_BLOCK.replace('mtu: 1400', 'mtu: 1280'), 'меняется только mtu');
eq(em.getProxyYaml('WG test').includes('quic:') || em.getProxyYaml('WG test').includes('client-fingerprint:'), false, 'форма AWG не добавляет defaults TrustTunnel');
em.updateProxyOptions('WG test', { mtu: null });
eq(em.getProxyYaml('WG test'), WG_BLOCK.replace('    mtu: 1400\n', ''), 'явное удаление mtu не подставляет 1408');
const emKeep = editorModel();
emKeep.updateProxyOptions('WG test', { 'persistent-keepalive': 25 });
eq(emKeep.getProxyYaml('WG test'), WG_BLOCK.replace('persistent-keepalive: 0', 'persistent-keepalive: 25'), 'keepalive меняется на месте');
emKeep.updateProxyOptions('WG test', { 'persistent-keepalive': null });
eq(emKeep.getProxyYaml('WG test').includes('persistent-keepalive:'), false, 'keepalive выключается удалением поля');
emKeep.updateProxyOptions('WG test', { 'persistent-keepalive': 30 });
eq(emKeep.getProxyYaml('WG test').endsWith('    persistent-keepalive: 30\n'), true, 'отсутствующий keepalive добавляется верхнеуровневым полем');
eq(em.getProxyYaml('Neighbor'), "  - name: Neighbor\n    type: ss\n    server: neighbor.example\n    password: 'NEIGHBOR-SECRET'\n", 'соседняя нода не меняется');
eq(em.getProxyYaml('WG test').includes("private-key: 'SECRET-WG-PRIVATE'") && em.getProxyYaml('WG test').includes('      I1: |\n        <b 0x01>'), true, 'секрет и вложенные AWG-поля сохранены');
em.updateProxyOptions('TT test', { quic: true });
eq(em.getProxyYaml('TT test').includes('    quic: true\n    client-fingerprint: firefox\n'), true, 'QUIC не удаляет сохранённый fingerprint');
em.updateProxyOptions('TT test', { 'client-fingerprint': 'chrome' });
eq(em.getProxyYaml('TT test').includes('client-fingerprint: chrome'), true, 'fingerprint меняется отдельно');
em.updateProxyOptions('TT test', { 'client-fingerprint': null });
eq(em.getProxyYaml('TT test').includes('client-fingerprint:'), false, 'fingerprint можно удалить');

[576, 1279, 1280, 65535].forEach(value => { const x = editorModel(); x.updateProxyOptions('WG test', { mtu: value }); eq(x.proxyOptions('WG test').mtu.value, String(value), 'допустимый MTU ' + value); });
[0, 575.5, 65536, -1, '1280', NaN].forEach(value => { const x = editorModel(); const before = x.serialize().proxies; throws(() => x.updateProxyOptions('WG test', { mtu: value }), /MTU/, 'недопустимый MTU ' + value); eq(x.serialize().proxies, before, 'ошибка MTU не меняет модель'); });
const em6 = editorModel(EDITOR_PROX.replace('    ip: 10.0.0.2\n', '    ip: 10.0.0.2\n    ipv6: fd00::2\n'));
eq(em6.proxyOptions('WG test').ipv6, true, 'форма видит локальный IPv6');
[1279, 1280].forEach(value => { const x = editorModel(EDITOR_PROX.replace('    ip: 10.0.0.2\n', '    ip: 10.0.0.2\n    ipv6: fd00::2\n')); if (value < 1280) { throws(() => x.updateProxyOptions('WG test', { mtu: value }), /1280/, 'IPv6 поднимает нижнюю границу MTU'); } else { x.updateProxyOptions('WG test', { mtu: value }); eq(x.proxyOptions('WG test').mtu.value, '1280', 'MTU 1280 с IPv6 допустим'); } });
[1, 65535].forEach(value => { const x = editorModel(); x.updateProxyOptions('WG test', { 'persistent-keepalive': value }); eq(x.proxyOptions('WG test').keepalive.value, String(value), 'допустимый keepalive ' + value); });
[0, 1.5, 65536, -2, '25'].forEach(value => { const x = editorModel(); throws(() => x.updateProxyOptions('WG test', { 'persistent-keepalive': value }), /keepalive/i, 'недопустимый keepalive ' + value); });
['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random', 'randomized'].forEach(value => { const x = editorModel(); x.updateProxyOptions('TT test', { 'client-fingerprint': value }); eq(x.proxyOptions('TT test').fingerprint.value, value, 'fingerprint ' + value); });
{ const x = editorModel(); throws(() => x.updateProxyOptions('TT test', { 'client-fingerprint': 'unknown-new' }), /fingerprint/i, 'новый произвольный fingerprint не подставляется'); }
{ const source = EDITOR_PROX.replace('client-fingerprint: firefox', 'client-fingerprint: provider-custom'); const x = editorModel(source); x.updateProxyOptions('TT test', {}); eq(x.getProxyYaml('TT test').includes('provider-custom'), true, 'пользовательский сохранённый fingerprint не заменяется'); }
{ const x = editorModel(EDITOR_PROX.replace("alpn: ['h2', 'h3']", "alpn: ['h2']")); const before = x.serialize().proxies; throws(() => x.updateProxyOptions('TT test', { quic: true }), /ALPN.*h3|h3.*ALPN/, 'QUIC запрещён при ALPN только h2'); eq(x.serialize().proxies, before, 'несовместимый ALPN не меняет модель'); x.updateProxyOptions('TT test', { quic: false }); eq(x.serialize().proxies, before, 'no-op транспорта не трогает несовместимый с новым режимом ALPN'); }
{ const x = editorModel(EDITOR_PROX.replace("alpn: ['h2', 'h3']", "alpn: ['h3']").replace('quic: false', 'quic: true')); throws(() => x.updateProxyOptions('TT test', { quic: false }), /ALPN.*h2|h2.*ALPN/, 'HTTP/2 запрещён при ALPN только h3'); }
{ const x = editorModel(EDITOR_PROX.replace("    alpn: ['h2', 'h3']\n", '')); x.updateProxyOptions('TT test', { quic: true }); eq(x.proxyOptions('TT test').quic.value, true, 'отсутствие ALPN не превращается в список'); eq(x.getProxyYaml('TT test').includes('alpn:'), false, 'форма не добавляет ALPN'); }
{ const x = editorModel(EDITOR_PROX.replace("    alpn: ['h2', 'h3']\n", "    alpn:\n      - h2\n      - h3\n")); eq(x.proxyOptions('TT test').alpn.values, ['h2', 'h3'], 'блочный список ALPN'); x.updateProxyOptions('TT test', { quic: true }); eq(x.proxyOptions('TT test').quic.value, true, 'блочный ALPN с h3 совместим с QUIC'); }
{ const x = editorModel(EDITOR_PROX.replace('    mtu: 1400', '    mtu: { value: 1400 }')); eq(x.proxyOptions('WG test').mtu.supported, false, 'сложный MTU недоступен обычной форме'); throws(() => x.updateProxyOptions('WG test', { mtu: 1280 }), /MTU/, 'сложный MTU не переписывается'); }
{ const x = editorModel(EDITOR_PROX.replace('    quic: false', '    quic: { enabled: false }')); eq(x.proxyOptions('TT test').quic.supported, false, 'сложный QUIC недоступен форме'); throws(() => x.updateProxyOptions('TT test', { quic: true }), /QUIC|quic/, 'сложный QUIC не переписывается'); }
{ const x = editorModel(); const before = x.serialize().proxies; throws(() => x.updateProxyOptions('WG test', { server: '192.0.2.99' }), /поле|поддерж/, 'обычная форма не меняет сервер'); throws(() => x.updateProxyOptions('Missing', { mtu: 1280 }), /Нет ноды/, 'редактор отсутствующей ноды'); x.removeProxy('WG test'); throws(() => x.getProxyYaml('WG test'), /Нет ноды/, 'убранная нода недоступна редактору'); throws(() => x.updateProxyOptions('WG test', { mtu: 1280 }), /Нет ноды/, 'убранную ноду нельзя менять'); eq(x.serialize().proxies.includes('SECRET-WG-PRIVATE'), false, 'ошибки редактора не возвращают убранную ноду'); eq(before.includes('SECRET-WG-PRIVATE'), true, 'исходная фикстура содержит контрольный секрет'); }
{ const source = "  - name: Same\n    type: wireguard\n  - name: Same\n    type: wireguard\n"; const x = editorModel(source); throws(() => x.getProxyYaml('Same'), /несколько|уникаль/, 'неуникальная запись не редактируется'); }

// ----- расширенный YAML одной ноды -----
// Ломающие изменения: замена без полной проверки, потеря вложенных строк,
// принятие второй записи или смены протокола, значения секретов в сводке.
{
  const x = editorModel(), before = x.serialize().proxies;
  throws(() => x.replaceProxyYaml('WG test', WG_BLOCK), /advanced|расширен/i, 'замена разрешена только из расширенного редактора');
  throws(() => x.replaceProxyYaml('WG test', WG_BLOCK, { advanced: false }), /advanced|расширен/i, 'advanced:false не разрешает замену');
  eq(x.serialize().proxies, before, 'отсутствие advanced не меняет модель');
  x.replaceProxyYaml('WG test', WG_BLOCK, { advanced: true });
  eq(x.serialize().proxies, before, 'полностью неизменный YAML возвращается побайтно');
  eq(x.summary({ subscriptions: '', proxies: before, geofilter: '' }), [], 'no-op расширенного YAML не попадает в сводку');
  x.replaceProxyYaml('WG test', WG_BLOCK.replace("  - name: 'WG test'", '  - name: "WG test"').replace('    type: wireguard', "    type: 'wireguard'"), { advanced: true });
  eq(x.getProxyYaml('WG test'), WG_BLOCK.replace("  - name: 'WG test'", '  - name: "WG test"').replace('    type: wireguard', "    type: 'wireguard'"), 'эквивалентная смена кавычек name/type допустима');
}
{
  const source = WG_BLOCK.replace('    # параметры провайдера не трогаем\n\n', '# provider comment\n   \n');
  const x = editorModel(source), before = x.getProxyYaml('WG test');
  x.replaceProxyYaml('WG test', before, { advanced: true });
  eq(x.getProxyYaml('WG test'), before, 'no-op не меняет комментарий без отступа и whitespace-only строку');
}
{
  const x = editorModel();
  const changed = WG_BLOCK + String.raw`    option: ["a\\", "b"]
    escaped: ["a\"b", 'c'] # комментарий после flow
`;
  x.replaceProxyYaml('WG test', changed, { advanced: true });
  eq(x.getProxyYaml('WG test'), changed, 'double-quoted flow учитывает чётность слэшей и escaped-кавычки');
}
{
  const x = editorModel();
  const changed = WG_BLOCK
    .replace('server: 192.0.2.1', 'server: 192.0.2.99')
    .replace('mtu: 1400', 'mtu: 1280')
    .replace('      jc: 3', '      jc: 4')
    .replace('        <b 0x01>', '        <b 0x01>\n        ---\n        &anchor *alias !tag\n        - name: содержимое, не вторая нода') +
    "    note: '--- &anchor *alias !tag {flow: [1, 2]}'\n" +
    "    provider-option: { mode: new, list: [one, 'two'] }\n";
  x.replaceProxyYaml('WG test', changed, { advanced: true });
  eq(x.getProxyYaml('WG test'), changed, 'расширенный YAML сохраняет вложенные поля, flow, комментарии и block scalar');
  eq(x.proxyRows().filter(p => p.name === 'WG test')[0].server, '192.0.2.99', 'после замены обновляется адрес в списке нод');
  eq(x.getProxyYaml('Neighbor'), "  - name: Neighbor\n    type: ss\n    server: neighbor.example\n    password: 'NEIGHBOR-SECRET'\n", 'расширенная замена не трогает соседнюю ноду');
  eq(x.serialize().proxies.startsWith(changed + "  - name: 'TT test'\n"), true, 'порядок нод и границы записи сохранены');
  eq(x.summary({ subscriptions: '', proxies: EDITOR_PROX, geofilter: '' }), ['Нода WG test: изменены server, mtu, amnezia-wg-option, note, provider-option'], 'сводка перечисляет только изменённые верхнеуровневые поля');
  const summary = x.summary({ subscriptions: '', proxies: EDITOR_PROX, geofilter: '' }).join('\n');
  ['192.0.2.99', '1280', 'SECRET-WG-PRIVATE', 'содержимое, не вторая нода', "mode: new"].forEach(secret => eq(summary.includes(secret), false, 'в сводку не попадает значение: ' + secret));
}
{
  const source = EDITOR_PROX.replace("    private-key: 'SECRET-WG-PRIVATE'\n", "    private-key: 'SECRET-WG-PRIVATE'\n    header-protection-key: 'OLD-HEADER-SECRET'\n");
  const x = editorModel(source);
  const changed = x.getProxyYaml('WG test')
    .replace("    private-key: 'SECRET-WG-PRIVATE'\n", "    private-key: 'NEW-WG-SECRET'\n    password: 'NEW-PASSWORD-SECRET'\n")
    .replace("    header-protection-key: 'OLD-HEADER-SECRET'\n", '');
  x.replaceProxyYaml('WG test', changed, { advanced: true });
  const summary = x.summary({ subscriptions: '', proxies: source, geofilter: '' }).join('\n');
  eq(summary, 'Нода WG test: изменены private-key, header-protection-key, password', 'сводка называет добавленные, изменённые и удалённые секретные поля');
  ['SECRET-WG-PRIVATE', 'OLD-HEADER-SECRET', 'NEW-WG-SECRET', 'NEW-PASSWORD-SECRET'].forEach(secret => eq(summary.includes(secret), false, 'сводка не раскрывает секрет ' + secret));
}
{
  const x = editorModel();
  x.updateProxyOptions('WG test', { mtu: 1280 });
  eq(x.summary({ subscriptions: '', proxies: EDITOR_PROX, geofilter: '' }), ['Нода WG test: изменены mtu'], 'обычная форма использует ту же безопасную сводку полей');
}
{
  const x = editorModel();
  const changed = WG_BLOCK +
    "    allowed-ips:\n      - '0.0.0.0/0'\n      - ::/0\n" +
    "    nested:\n      - key: one\n        value: two\n      - key: three\n        value: { flow: [one, two] }\n";
  x.replaceProxyYaml('WG test', changed, { advanced: true });
  eq(x.getProxyYaml('WG test'), changed, 'вложенные блочные последовательности и их отображения сохраняются');
}
{
  const invalid = [
    ['смена name', WG_BLOCK.replace("name: 'WG test'", "name: 'Other'"), /name|имя/i],
    ['смена type', WG_BLOCK.replace('type: wireguard', 'type: trusttunnel'), /type|протокол/i],
    ['name не первым', WG_BLOCK.replace("  - name: 'WG test'\n    type: wireguard", "  - type: wireguard\n    name: 'WG test'"), /name|перв/i],
    ['две записи', WG_BLOCK + "  - name: Other\n    type: ss\n", /одн|несколько|запис/i],
    ['верхнеуровневый раздел', 'proxies:\n' + WG_BLOCK, /раздел|одн|запис|name/i],
    ['директива', '%YAML 1.2\n' + WG_BLOCK, /директив|документ|%YAML/i],
    ['начало документа', '---\n' + WG_BLOCK, /документ|---/i],
    ['конец документа', WG_BLOCK + '...\n', /документ|\.\.\./i],
    ['flow-запись всей ноды', "  - { name: 'WG test', type: wireguard }\n", /flow|запис|name/i],
    ['многострочная flow-коллекция', WG_BLOCK + "    allowed-ips: [\n      '10.0.0.0/8',\n      '192.168.0.0/16'\n    ]\n", /flow|многостроч|скоб/i],
    ['незакрытая flow-коллекция', WG_BLOCK + "    allowed-ips: ['10.0.0.0/8'\n", /flow|скоб/i],
    ['вложенная скобка в plain flow-последовательности', WG_BLOCK + '    option: [a[b]\n', /flow|скоб/i],
    ['вложенная скобка в plain flow-отображении', WG_BLOCK + '    option: {one: a{b}\n', /flow|скоб/i],
    ['повтор в flow-отображении', WG_BLOCK + "    custom: { one: 1, two: 2, one: 3 }\n", /повтор|дубликат|one/i],
    ['повтор в отображении последовательности', WG_BLOCK + "    nested:\n      - key: one\n        key: two\n", /повтор|дубликат|key/i],
    ['табуляция', WG_BLOCK.replace('    mtu: 1400', '\tmtu: 1400'), /табуляц/i],
    ['anchor', WG_BLOCK.replace('mtu: 1400', 'mtu: &mtu 1400'), /anchor|якор|&/i],
    ['alias', WG_BLOCK + '    copy: *mtu\n', /alias|псевдоним|\*/i],
    ['merge', WG_BLOCK + '    <<: *defaults\n', /merge|<<|alias/i],
    ['явный тег', WG_BLOCK.replace('mtu: 1400', 'mtu: !!int 1400'), /тег|!!/i],
    ['повтор верхнеуровневого ключа', WG_BLOCK + '    mtu: 1500\n', /повтор|дубликат|mtu/i],
    ['повтор вложенного ключа', WG_BLOCK.replace('      jc: 3', '      jc: 3\n      jc: 4'), /повтор|дубликат|jc/i],
    ['неверный отступ', WG_BLOCK.replace('      jc: 3', '     jc: 3'), /отступ/i],
    ['базовый отступ один пробел', WG_BLOCK.replace(/^ /gm, ''), /отступ/i],
    ['многострочный name', WG_BLOCK.replace("  - name: 'WG test'", '  - name: |\n      WG test'), /name|одностроч/i],
    ['многострочный type', WG_BLOCK.replace('    type: wireguard', '    type: >-\n      wireguard'), /type|одностроч/i],
    ['нескалярная строка', WG_BLOCK + '      просто продолжение\n', /строк|отступ|скаляр/i]
  ];
  invalid.forEach(([what, text, re]) => {
    const x = editorModel(), before = x.serialize().proxies;
    throws(() => x.replaceProxyYaml('WG test', text, { advanced: true }), re, 'отклонён: ' + what);
    eq(x.serialize().proxies, before, 'атомарность после ошибки: ' + what);
  });
  const x = editorModel(), before = x.serialize().proxies;
  throws(() => x.replaceProxyYaml('Missing', WG_BLOCK, { advanced: true }), /Нет ноды/, 'расширенный редактор отсутствующей ноды');
  x.removeProxy('WG test');
  throws(() => x.replaceProxyYaml('WG test', WG_BLOCK, { advanced: true }), /Нет ноды/, 'расширенный редактор убранной ноды');
  eq(before.includes('SECRET-WG-PRIVATE'), true, 'контрольная фикстура не потеряна до проверок ошибок');
}

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
