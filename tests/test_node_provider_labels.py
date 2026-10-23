"""Provider labels preserve sources without leaking subscription data."""
import builtins
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'web'))
import stats_httpd

try:
    import yaml  # noqa: F401
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


@unittest.skipUnless(HAVE_YAML, 'PyYAML не установлен')
class NodeProviderLabelsTest(unittest.TestCase):
    def setUp(self):
        stats_httpd._YAML_CACHE.clear()
        self._dir = patch.dict('os.environ', {'DIR': '/nonexistent-mst'})
        self._dir.start()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config' / 'config.yaml'

    def tearDown(self):
        self._dir.stop()
        self.tmp.cleanup()

    def test_sources_collisions_static_nodes_and_missing_cache(self):
        abs_cache = self.root / 'cache' / 'b.yaml'
        write(self.config, f"""
p: &p {{interval: 3600}}
proxy-providers:
  Provider A: {{<<: *p, path: cache/a.yaml, url: private-subscription}}
  Provider B: {{path: {abs_cache}}}
  Missing cache: {{path: cache/missing.yaml}}
  fast: {{path: fast.yaml}}
proxies:
  - {{name: awg_pl, type: wireguard, private-key: private-key, amnezia-wg-option: {{jc: 4}}}}
  - {{name: hy2-de, type: hysteria2}}
""")
        write(self.root / 'config' / 'cache' / 'a.yaml',
              "proxies:\n  - {name: shared, type: vless}\n  - {name: \"🇫🇮 Finland\", type: vmess}\n")
        write(abs_cache, "proxies:\n  - {name: shared, type: trojan}\n  - {name: \"🇩🇪 Germany\", type: vless}\n")
        write(self.root / 'config' / 'fast.yaml', "proxies:\n  - {name: winner-copy}\n")

        result = stats_httpd.node_provider_labels(str(self.config))
        details = stats_httpd.node_provider_labels(str(self.config), details=True)
        self.assertEqual(result, {
            'shared': ['Provider A · VLESS', 'Provider B · Trojan'],
            '🇫🇮 Finland': ['Provider A · VMess'],
            '🇩🇪 Germany': ['Provider B · VLESS'],
            'awg_pl': ['awg · AmneziaWG'],
            'hy2-de': ['Без провайдера · Hysteria2'],
        })
        self.assertNotIn('private-', json.dumps(result))
        self.assertEqual(details['shared'], [{'provider': 'Provider A', 'protocol': 'VLESS'},
                                             {'provider': 'Provider B', 'protocol': 'Trojan'}])
        self.assertNotIn('private-', json.dumps(details))

    def test_share_link_subscriptions(self):
        import base64
        links = "\n".join([
            "vless://secret-uuid@de.example.com:443?security=reality&pbk=secret-key#%F0%9F%87%A9%F0%9F%87%AA+Germany",
            "vless://secret-uuid@1.2.3.4:8443?security=tls",
            "trojan://secret-pass@nl.example.com:443#NL%201",
            "vmess://" + base64.b64encode(json.dumps({"ps": "VM node", "add": "x", "id": "secret-uuid"}).encode()).decode(),
            "hy2://secret-pass@fi.example.com:443#FI",
            "garbage line",
        ])
        write(self.config, "proxy-providers:\n  B64: {path: b64.txt}\n  Raw: {path: raw.txt}\n")
        write(self.root / 'config' / 'b64.txt', base64.b64encode(links.encode()).decode() + "\n")
        write(self.root / 'config' / 'raw.txt', "vless://secret-uuid@pl.example.com:443#PL\n")
        result = stats_httpd.node_provider_labels(str(self.config))
        self.assertEqual(result, {
            '🇩🇪 Germany': ['B64 · VLESS'],
            'vless-1.2.3.4-8443': ['B64 · VLESS'],
            'NL 1': ['B64 · Trojan'],
            'VM node': ['B64 · VMess'],
            'FI': ['B64 · Hysteria2'],
            'PL': ['Raw · VLESS'],
        })
        self.assertNotIn('secret', json.dumps(result))

    def test_static_node_provider_from_name_prefix(self):
        f = stats_httpd.static_node_provider
        self.assertEqual(f('Blanc_PL_WAW_1'), 'Blanc')
        self.assertEqual(f('🇩🇪 Hysteria2'), 'Без провайдера')
        self.assertEqual(f('_leading'), 'Без провайдера')
        self.assertEqual(f(None), 'Без провайдера')

    def test_manual_provider_overrides_prefix(self):
        write(self.config, "proxies:\n  - {name: Blanc_PL_1, type: wireguard}\n  - {name: solo, type: vless}\n")
        store = str(self.root / 'node_providers.json')
        stats_httpd.save_node_provider_override('solo', 'My VPN', store)
        stats_httpd.save_node_provider_override('Blanc_PL_1', 'Blanc Ltd', store)
        static = []
        overrides = stats_httpd.load_node_provider_overrides(store)
        result = stats_httpd.node_provider_labels(str(self.config), overrides=overrides, static_names=static)
        self.assertEqual(result, {'Blanc_PL_1': ['Blanc Ltd · WireGuard'], 'solo': ['My VPN · VLESS']})
        self.assertEqual(static, ['Blanc_PL_1', 'solo'])
        stats_httpd.save_node_provider_override('Blanc_PL_1', '', store)
        overrides = stats_httpd.load_node_provider_overrides(store)
        self.assertEqual(overrides, {'solo': 'My VPN'})
        self.assertEqual(stats_httpd.node_provider_labels(str(self.config), overrides=overrides)['Blanc_PL_1'],
                         ['Blanc · WireGuard'])

    def test_broken_override_file_is_ignored(self):
        store = self.root / 'node_providers.json'
        for text in ['not json', '[]', '{"a": 1, "b": ""}']:
            store.write_text(text, encoding='utf-8')
            self.assertEqual(stats_httpd.load_node_provider_overrides(str(store)), {})

    def test_changed_file_is_reread(self):
        write(self.config, "proxies:\n  - {name: n1, type: vless}\n")
        self.assertEqual(stats_httpd.node_provider_labels(str(self.config)), {'n1': ['Без провайдера · VLESS']})
        write(self.config, "proxies:\n  - {name: n1, type: trojan, extra: changed}\n")
        self.assertEqual(stats_httpd.node_provider_labels(str(self.config)), {'n1': ['Без провайдера · Trojan']})

    def test_invalid_documents_do_not_break_statistics(self):
        for document in ['not: [valid', '[]', '', 'proxy-providers: [invalid]', '!!python/object:os.system x']:
            with self.subTest(document=document):
                stats_httpd._YAML_CACHE.clear()
                write(self.config, document)
                self.assertEqual(stats_httpd.node_provider_labels(str(self.config)), {})

    def test_missing_config(self):
        self.assertEqual(stats_httpd.node_provider_labels(str(self.root / 'nope.yaml')), {})


class NodeProviderLabelsNoYamlTest(unittest.TestCase):
    def test_missing_pyyaml_does_not_break_statistics(self):
        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == 'yaml':
                raise ImportError('no yaml')
            return real_import(name, *args, **kwargs)
        with patch.object(builtins, '__import__', side_effect=fake_import):
            self.assertEqual(stats_httpd.node_provider_labels('/config/config.yaml'), {})


if __name__ == '__main__':
    unittest.main()
