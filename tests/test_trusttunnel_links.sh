#!/bin/sh
# Бинарный импорт обычных серверных ссылок TrustTunnel, без DOM и сети.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP test_trusttunnel_links: нет node"; exit 0; }
node --input-type=module - "$ROOT/web/stats_app_constructor_modules_model.js" <<'JS'
import { pathToFileURL } from 'node:url';
const M = await import(pathToFileURL(process.argv[2]).href);

// Официальная спецификация версии 2:
// https://github.com/TrustTunnel/TrustTunnel/blob/8bdf9968ec63c97dec2e504acbb93b78176981d6/DEEP_LINK.md
const SPEC_COMMIT = '8bdf9968ec63c97dec2e504acbb93b78176981d6';
if (!/^[0-9a-f]{40}$/.test(SPEC_COMMIT)) { throw new Error('Нужен полный commit спецификации'); }
let failed = 0;
function eq(actual, expected, what) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) { console.error('FAIL: ' + what + '\n  ожидалось ' + e + '\n  получено  ' + a); failed = 1; }
}
function throws(fn, re, what, secrets = []) {
  try { fn(); console.error('FAIL: ' + what + ' - нет ошибки'); failed = 1; }
  catch (e) {
    if (re && !re.test(e.message)) { console.error('FAIL: ' + what + ' - не то сообщение: ' + e.message); failed = 1; }
    secrets.forEach(secret => {
      if (e.message.includes(secret)) { console.error('FAIL: ' + what + ' - сообщение раскрывает секрет'); failed = 1; }
    });
  }
}
function bytes(value) { return value instanceof Uint8Array ? value : Uint8Array.from(value); }
function vi(value) {
  const n = BigInt(value);
  if (n <= 63n) return [Number(n)];
  if (n <= 16383n) return Array.from(bytes([(Number(n >> 8n) & 0x3f) | 0x40, Number(n & 0xffn)]));
  if (n <= 1073741823n) {
    const b = Buffer.alloc(4); b.writeUInt32BE(Number(n | 0x80000000n)); return Array.from(b);
  }
  const b = Buffer.alloc(8); b.writeBigUInt64BE(n | 0xc000000000000000n); return Array.from(b);
}
function tlv(tag, value) { return [...vi(tag), ...vi(value.length), ...value]; }
function str(tag, value) { return tlv(tag, Array.from(Buffer.from(value, 'utf8'))); }
function b64(value) { return Buffer.from(bytes(value)).toString('base64url'); }
function link(value) { return 'tt://?' + b64(value); }
function raw(value) { return Buffer.from(value.slice(6), 'base64url'); }
function withField(base, field) { return link([...raw(base), ...field]); }

// Литеральные фикстуры собраны вручную по TLV из SPEC_COMMIT. Все адреса и
// реквизиты вымышленные; ожидаемый объект не вычисляется кодом проекта.
const BASE = 'tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgNwfngMB1RUIHRlc3Q';
const QUIC = 'tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgNwfngMB1RUIHRlc3QJAQI';
const SKIP = 'tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgNwfngMB1RUIHRlc3QHAQE';
const APOSTROPHE = "tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgRwJ354DAdUVCB0ZXN0";
const NO_NAME = 'tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgNwfng';
const CUSTOM_SNI = 'tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgNwfngMB1RUIHRlc3QDC3NuaS5leGFtcGxl';
const IPV6 = 'tt://?AQt0dDYuZXhhbXBsZQISWzIwMDE6ZGI4OjoxXTo4NDQzBQR0ZXN0BgNwfngMBVRUIHY2';
const SUBSCRIPTION = 'tt://?AQp0dC5leGFtcGxlAg0xOTIuMC4yLjE6NDQzBQR0ZXN0BgNwfngMB1RUIHRlc3QOMWh0dHBzOi8vdXNlcjpTVUJTQ1JJUFRJT04tU0VDUkVUQHN1Yi5leGFtcGxlL2ZlZWQ';
const BASIC = { name: 'TT test', server: '192.0.2.1', port: 443, username: 'test', password: 'p~x', sni: 'tt.example', quic: false, skipCertVerify: false };

eq(M.parseTrustTunnelLink(BASE), BASIC, 'базовая ссылка версии без явного version');
eq(M.parseTrustTunnelLink(BASE.replace('tt://?', 'tt://')), BASIC, 'старый префикс tt://BASE64URL');
eq(M.parseTrustTunnelLink(QUIC), { ...BASIC, quic: true }, 'upstream_protocol=2 -> QUIC');
eq(M.parseTrustTunnelLink(SKIP), { ...BASIC, skipCertVerify: true }, 'skip_verification=true');
eq(M.parseTrustTunnelLink(NO_NAME), { ...BASIC, name: 'tt.example' }, 'без name имя берётся из hostname');
eq(M.parseTrustTunnelLink(CUSTOM_SNI), { ...BASIC, sni: 'sni.example' }, 'custom_sni меняет только SNI');
eq(M.parseTrustTunnelLink(IPV6), { ...BASIC, name: 'TT v6', server: '2001:db8::1', port: 8443, sni: 'tt6.example' }, 'IPv6 с портом в квадратных скобках');
eq(M.parseTrustTunnelLink(APOSTROPHE).password, "p'~x", 'апостроф и тильда в пароле');

// Строгий Base64url: не позволять atob молча принять другой алфавит,
// padding, whitespace или длину, у которой нет однозначного декодирования.
[
  BASE + '=', BASE.replace('tt://?A', 'tt://?+'), BASE.replace('tt://?A', 'tt://?/'),
  BASE.replace('tt://?A', 'tt://? A'), 'tt://?A', 'tt://?', ' ' + BASE, BASE + '\n'
].forEach((value, i) => throws(() => M.parseTrustTunnelLink(value), /base64|ссылк|данн/i, 'строгий Base64url ' + i, ['p~x', 'test']));
throws(() => M.parseTrustTunnelLink('tt://?' + 'A'.repeat(87383)), /64|размер|велик/i, 'предел длины до декодирования');
{
  const filler = 65536 - raw(BASE).length - 2 - 4;
  const exact = [...raw(BASE), ...tlv(64, new Array(filler).fill(0))];
  eq(raw(link(exact)).length, 65536, 'фикстура ровно 64 КиБ');
  eq(M.parseTrustTunnelLink(link(exact)), BASIC, 'ровно 64 КиБ и неизвестный тег принимаются');
  throws(() => M.parseTrustTunnelLink(link([...exact, 0])), /64|размер|велик/i, 'больше 64 КиБ отклоняется');
}

// Обрезанные varint/TLV, небезопасные целые и неверные типы не должны
// превращаться в частично разобранную ноду.
[
  [[0x40], /varint|обрез|границ/i, 'обрезанный тег'],
  [[0x01, 0x40], /varint|обрез|границ/i, 'обрезанная длина'],
  [[0x01, 0x05, 0x61], /длин|обрез|границ/i, 'значение короче длины'],
  [[...raw(BASE), 0x7f], /varint|обрез|границ/i, 'хвост из неполного TLV'],
  [[...tlv(0, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), ...raw(BASE)], /безопас|цел|диапазон/i, 'version вне safe integer'],
  [[0x40, 0x40, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], /безопас|цел|диапазон/i, 'length вне safe integer'],
  [[...raw(BASE), ...tlv(4, [])], /bool|boolean|длин/i, 'bool нулевой длины'],
  [[...raw(BASE), ...tlv(4, [1, 0])], /bool|boolean|длин/i, 'bool длины 2'],
  [[...raw(BASE), ...tlv(7, [2])], /bool|boolean|0x00|0x01/i, 'bool со значением 2'],
  [[...raw(BASE), ...str(1, '\ufffd').slice(0, -1), 0xff], /utf|строк/i, 'повреждённый UTF-8'],
  [[...raw(BASE), ...tlv(0, vi(3))], /верси/i, 'version выше 2'],
  [[...raw(BASE), ...tlv(9, vi(0))], /транспорт|protocol/i, 'transport 0'],
  [[...raw(BASE), ...tlv(9, vi(3))], /транспорт|protocol/i, 'transport 3']
].forEach(([value, re, what]) => throws(() => M.parseTrustTunnelLink(link(value)), re, what, ['p~x', 'test']));

// Для String[] проверяются внутренние границы, даже если непустой список затем
// отклоняется как неподдерживаемый параметр.
throws(() => M.parseTrustTunnelLink(withField(BASE, tlv(13, [0x40]))), /varint|обрез|границ/i, 'обрезанный элемент dns_upstreams');

// Повторы одиночных тегов разрешает спецификация: побеждает последнее.
{
  const changed = link([
    ...raw(BASE), ...str(1, 'last.example'),
    ...str(5, 'last-user'), ...str(6, 'last-pass'), ...str(12, 'Last name'),
    ...tlv(9, vi(2)), ...tlv(9, vi(1)), ...tlv(7, [1]), ...tlv(7, [0])
  ]);
  eq(M.parseTrustTunnelLink(changed), {
    name: 'Last name', server: '192.0.2.1', port: 443, username: 'last-user',
    password: 'last-pass', sni: 'last.example', quic: false, skipCertVerify: false
  }, 'последнее значение повторных одиночных тегов');
  eq(M.parseTrustTunnelLink(link([...raw(BASE), ...tlv(63, [1, 2, 3])])), BASIC, 'неизвестный тег пропускается');
  eq(M.parseTrustTunnelLink(link([...tlv(0, vi(0)), ...raw(BASE)])), BASIC, 'version 0');
  eq(M.parseTrustTunnelLink(link([...tlv(0, vi(1)), ...raw(BASE)])), BASIC, 'version 1');
  eq(M.parseTrustTunnelLink(link([...tlv(0, vi(2)), ...raw(BASE)])), BASIC, 'version 2');
}

// Поддерживаемый профиль: один статический сервер. Неизвестные Mihomo
// параметры отклоняются, явные значения по умолчанию остаются допустимыми.
[
  [tlv(8, [1]), /сертификат/i, 'встроенный сертификат'],
  [tlv(10, [1]), /anti|dpi/i, 'anti-DPI=true'],
  [str(11, 'aa'), /client_random|prefix|рандом/i, 'client_random_prefix'],
  [str(15, 'bb'), /auth|ключ/i, 'client_random_auth_key'],
  [tlv(13, str(0, 'dns.example').slice(1)), /dns/i, 'непустой dns_upstreams'],
  [tlv(4, [0]), /ipv6/i, 'has_ipv6=false']
].forEach(([field, re, what]) => throws(() => M.parseTrustTunnelLink(withField(BASE, field)), re, what, ['p~x', 'test']));
[
  tlv(4, [1]), tlv(7, [0]), tlv(8, []), tlv(9, vi(1)), tlv(10, [0]),
  str(11, ''), tlv(13, []), str(15, '')
].forEach((field, i) => eq(M.parseTrustTunnelLink(withField(BASE, field)), BASIC, 'явное значение по умолчанию ' + i));

throws(() => M.parseTrustTunnelLink(SUBSCRIPTION), /подпис/i, 'subscription_url не превращается в статическую ноду', [
  'https://user:SUBSCRIPTION-SECRET@sub.example/feed', 'SUBSCRIPTION-SECRET', 'sub.example', 'p~x', 'test'
]);
throws(() => M.parseTrustTunnelLink(withField(BASE, str(2, '192.0.2.2:443'))), /ровно один|несколько|адрес/i, 'несколько адресов отклоняются');
[
  [str(1, ''), /hostname|обязат/i, 'пустой hostname'],
  [str(5, ''), /username|логин|обязат/i, 'пустой username'],
  [str(6, ''), /password|парол|обязат/i, 'пустой password']
].forEach(([field, re, what]) => throws(() => M.parseTrustTunnelLink(withField(BASE, field)), re, what, ['p~x', 'test']));
function baseWithAddress(address) {
  return link([...str(1, 'tt.example'), ...str(2, address), ...str(5, 'test'), ...str(6, 'p~x'), ...str(12, 'TT test')]);
}
[
  ['', /address|адрес|обязат/i, 'пустой address'],
  ['192.0.2.1', /порт|address|адрес/i, 'нет порта'],
  ['192.0.2.1:0', /порт/i, 'порт 0'],
  ['192.0.2.1:65536', /порт/i, 'порт 65536'],
  ['192.0.2.1:http', /порт/i, 'нечисловой порт'],
  ['2001:db8::1:443', /скоб|ipv6|адрес/i, 'IPv6 без скобок']
].forEach(([address, re, what]) => throws(() => M.parseTrustTunnelLink(baseWithAddress(address)), re, what, ['p~x', 'test']));

// linkToProxy и createModules сохраняют прежний интерфейс импорта ссылок.
const yaml = M.linkToProxy(BASE).yaml;
eq(yaml, "  - name: 'TT test'\n    type: trusttunnel\n    server: '192.0.2.1'\n    port: 443\n    username: 'test'\n    password: 'p~x'\n    sni: 'tt.example'\n    quic: false\n", 'TrustTunnel -> YAML без выдуманных настроек');
eq(M.linkToProxy(QUIC).yaml.includes('    quic: true\n'), true, 'QUIC попадает в YAML');
eq(M.linkToProxy(SKIP).yaml.endsWith('    skip-cert-verify: true\n'), true, 'skip-cert-verify только при true');
eq(M.linkToProxy(BASE).yaml.includes('skip-cert-verify'), false, 'нет skip-cert-verify по умолчанию');
eq(M.linkToProxy(APOSTROPHE).yaml.includes("password: 'p''~x'"), true, 'апостроф экранируется в YAML');
['client-fingerprint', 'health-check', 'alpn', 'udp:'].forEach(field => eq(yaml.includes(field), false, 'не добавляется ' + field));
{
  const model = M.createModules({ subscriptions: '', proxies: '', geofilter: null, geofilter_default: '' });
  eq(model.addProxyLink(BASE), 'TT test', 'первая нода');
  eq(model.addProxyLink(BASE), 'TT test 192.0.2.1', 'дубль получает адрес сервера');
  eq(model.addProxyLink(BASE), 'TT test-2', 'следующий дубль получает номер');
  eq(model.proxies().map(p => [p.name, p.type, p.server, p.port]), [
    ['TT test', 'trusttunnel', '192.0.2.1', '443'],
    ['TT test 192.0.2.1', 'trusttunnel', '192.0.2.1', '443'],
    ['TT test-2', 'trusttunnel', '192.0.2.1', '443']
  ], 'дубли добавлены через uniqueProxyName');
}

if (failed) { process.exit(1); }
console.log('OK test_trusttunnel_links; spec ' + SPEC_COMMIT);
JS
