"""The generated OpenCode profiles must be valid and keep MCP tools wired."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

PROFILES = {
    'qwen': {
        'HEXSTRIKE_MCP_BRIDGE_PORT': '8890', 'MODEL_PORT': '8000',
        'MODEL_ALIAS': 'pharaoh-agent', 'MODEL_NAME': 'Qwen3.8-27B Abliterated',
        'MODEL_CONTEXT': '262144', 'MODEL_OUTPUT': '32768',
        'PROVIDER_NAME': 'Pharaoh Local Qwen',
    },
    'deckard': {
        'HEXSTRIKE_MCP_BRIDGE_PORT': '8890', 'MODEL_PORT': '8002',
        'MODEL_ALIAS': 'pharaoh-deckard', 'MODEL_NAME': 'Qwen3.5-40B Deckard-Heretic',
        'MODEL_CONTEXT': '262144', 'MODEL_OUTPUT': '32768',
        'PROVIDER_NAME': 'Pharaoh Local Deckard',
    },
    'cyberstrike': {
        'HEXSTRIKE_MCP_BRIDGE_PORT': '8890', 'MODEL_PORT': '8001',
        'MODEL_ALIAS': 'pharaoh-review', 'MODEL_NAME': 'CyberStrike-OffSec-35B Abliterated',
        'MODEL_CONTEXT': '262144', 'MODEL_OUTPUT': '8192',
        'PROVIDER_NAME': 'Pharaoh Local CyberStrike',
    },
}


def render(template, values):
    text = template.read_text(encoding='utf-8')
    for key, value in values.items():
        text = text.replace(f'__{key}__', value)
    return text


class ConfigTemplateTests(unittest.TestCase):
    def profile(self, name):
        text = render(ROOT / 'config/opencode.json', PROFILES[name])
        self.assertNotIn('__', text)
        config = json.loads(text)
        model = PROFILES[name]['MODEL_ALIAS']
        provider = config['providers']['local']
        self.assertEqual(config['model'], f'local/{model}')
        self.assertEqual(provider['settings']['baseURL'],
                         f"http://127.0.0.1:{PROFILES[name]['MODEL_PORT']}/v1")
        self.assertTrue(provider['models'][model]['capabilities']['tools'])
        server = config['mcp']['servers']['hexstrike']
        self.assertEqual(server['type'], 'remote')
        self.assertEqual(server['url'], 'http://127.0.0.1:8890/mcp')
        self.assertFalse(server['oauth'])
        self.assertGreaterEqual(server['timeout']['execution'], 3_600_000)

    def test_qwen_profile(self):
        self.profile('qwen')

    def test_deckard_profile(self):
        self.profile('deckard')

    def test_cyberstrike_profile(self):
        self.profile('cyberstrike')

    def test_review_profile_permits_the_tool_executor_and_hexstrike(self):
        text = render(ROOT / 'config/opencode-review.json', PROFILES['cyberstrike'])
        self.assertNotIn('__', text)
        config = json.loads(text)
        self.assertTrue(config['providers']['pharaoh-local']['models']['pharaoh-review']
                        ['capabilities']['tools'])
        self.assertIn('hexstrike', config['mcp']['servers'])
        policies = {(p['action'], p['resource'], p['effect']) for p in config['policies']}
        self.assertIn(('mcp.use', 'hexstrike', 'allow'), policies)
        self.assertIn(('tool.use', 'execute:*', 'allow'), policies)
        self.assertIn(('tool.use', 'hexstrike_*:*', 'allow'), policies)


if __name__ == '__main__':
    unittest.main()
