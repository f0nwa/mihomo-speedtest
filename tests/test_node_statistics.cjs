// Aggregates must not dilute measured speeds or match unrelated source pairs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../web/stats_app_stats.js'), 'utf8')
  .replace(/^import .*;\s*$/gm, '').replace(/^export /gm, '');
const c = vm.createContext({}); vm.runInContext(code, c);
c.nodeSources = {
  a: [{provider: 'A', protocol: 'VLESS'}],
  b: [{provider: 'A', protocol: 'VLESS'}],
  d: [{provider: 'B', protocol: 'Hysteria2'}],
  shared: [{provider: 'A', protocol: 'VLESS'}, {provider: 'B', protocol: 'Hysteria2'}, {provider: 'A', protocol: 'Hysteria2'}],
};
c.nodeProviders = Object.fromEntries(Object.entries(c.nodeSources).map(([name, sources]) => [name, sources.map(s => s.provider + ' · ' + s.protocol)]));
const rows = [
  {name: 'a', status: 'alive', last_speed_bytes: 100, avg_delay_ms: 10},
  {name: 'b', status: 'down', last_speed_bytes: null, avg_delay_ms: null},
  {name: 'd', status: 'skipped', last_speed_bytes: 0, avg_delay_ms: 30},
  {name: 'shared', status: 'alive', last_speed_bytes: 300, avg_delay_ms: 50},
];
const summary = c.summarizeNodes(rows, 'provider');
const a = summary.find(g => g.name === 'A');
assert.equal(a.total, 3); assert.equal(a.alive, 2); assert.equal(a.measured, 2);
assert.equal(a.avgSpeed, 200); assert.equal(a.avgPing, 30); assert.equal(a.bestSpeed, 300);
const b = summary.find(g => g.name === 'B');
assert.equal(b.total, 2); assert.equal(b.skipped, 1); assert.equal(b.measured, 2); assert.equal(b.avgSpeed, 150);
c.nodeSelection.provider = 'B'; c.nodeSelection.protocol = 'VLESS';
assert.equal(c.filteredNodeRows(rows).length, 0); // No cross product between sources of the same name.
c.nodeSelection.protocol = 'Hysteria2';
assert.equal(c.filteredNodeRows(rows).length, 2);
assert.equal(c.summarizeNodes(c.filteredNodeRows(rows), 'provider').length, 1);
c.stabilityFilter.other = false;
assert.equal(c.filteredNodeRows(rows).length, 1);
c.stabilityQuery = 'shared'; assert.equal(c.filteredNodeRows(rows).length, 1);
c.stabilityQuery = 'missing'; assert.equal(c.filteredNodeRows(rows).length, 0);
c.nodeSelection.provider = ''; c.nodeSelection.protocol = '';
const noData = c.summarizeNodes([{name: 'b', status: 'down', last_speed_bytes: null, avg_delay_ms: null}], 'provider')[0];
assert.equal(noData.avgSpeed, null); assert.equal(noData.avgPing, null);
console.log('test_node_statistics: OK (filters, pair identity, missing samples, zero speeds, deduplication)');
