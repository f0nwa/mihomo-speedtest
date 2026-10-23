"""Provider labels preserve sources without leaking subscription data."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'web'))
import stats_httpd

class NodeProviderLabelsTest(unittest.TestCase):
    def test_sources_collisions_static_nodes_and_missing_cache(self):
        documents = {
            '/config/config.yaml': {
                'proxy-providers': {
                    'Provider A': {'path': 'cache/a.yaml', 'url': 'private-subscription'},
                    'Provider B': {'path': '/cache/b.yaml'},
                    'Missing cache': {'path': 'cache/missing.yaml'},
                    'fast': {'path': 'fast.yaml'},
                },
                'proxies': [{'name': 'awg-pl', 'type': 'wireguard', 'amnezia-wg-option': {'jc': 4}, 'private-key': 'private-key'}, {'name': 'hy2-de', 'type': 'hysteria2'}],
            },
            '/config/cache/a.yaml': {'proxies': [{'name': 'shared', 'type': 'vless'}, {'name': '🇫🇮 Finland', 'type': 'vmess'}]},
            '/cache/b.yaml': {'proxies': [{'name': 'shared', 'type': 'trojan'}, {'name': '🇩🇪 Germany', 'type': 'vless'}]},
            '/config/fast.yaml': {'proxies': [{'name': 'winner-copy'}]},
        }
        def read(args, **kwargs):
            self.assertEqual(args[:3], ['yq', '-o=json', '.'])
            if args[3] not in documents:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, json.dumps(documents[args[3]]).encode())
        with patch.object(stats_httpd.subprocess, 'run', side_effect=read):
            result = stats_httpd.node_provider_labels('/config/config.yaml')
            details = stats_httpd.node_provider_labels('/config/config.yaml', details=True)
        self.assertEqual(result, {
            'shared': ['Provider A · VLESS', 'Provider B · Trojan'],
            '🇫🇮 Finland': ['Provider A · VMess'],
            '🇩🇪 Germany': ['Provider B · VLESS'],
            'awg-pl': ['Своя нода · AmneziaWG'],
            'hy2-de': ['Своя нода · Hysteria2'],
        })
        self.assertNotIn('private-', json.dumps(result))
        self.assertEqual(details['shared'], [{'provider': 'Provider A', 'protocol': 'VLESS'}, {'provider': 'Provider B', 'protocol': 'Trojan'}])
        self.assertNotIn('private-', json.dumps(details))

    def test_unavailable_parser_does_not_break_statistics(self):
        with patch.object(stats_httpd.subprocess, 'run', side_effect=FileNotFoundError):
            self.assertEqual(stats_httpd.node_provider_labels('/config/config.yaml'), {})

    def test_invalid_documents_do_not_break_statistics(self):
        for document in ['not-json', '[]', 'null', '{"proxy-providers": ["invalid"]}']:
            with self.subTest(document=document), patch.object(
                stats_httpd.subprocess, 'run',
                return_value=subprocess.CompletedProcess([], 0, document.encode()),
            ):
                self.assertEqual(stats_httpd.node_provider_labels('/config/config.yaml'), {})

if __name__ == '__main__':
    unittest.main()
