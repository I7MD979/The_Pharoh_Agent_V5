"""Exercise the official SDK transport with a local fixture tool, without scans."""
import importlib.util
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request


@unittest.skipUnless(importlib.util.find_spec('mcp'), 'Install mcp>=1.12,<2 for bridge integration')
class BridgeIntegrationTests(unittest.TestCase):
    def test_fresh_clients_can_list_and_call_tools_without_session_state(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            shutil.copy(Path(__file__).resolve().parents[1] / 'scripts/hexstrike_bridge.py', directory)
            (directory / 'hexstrike_mcp.py').write_text('''from mcp.server.fastmcp import FastMCP
class HexStrikeClient:
    def __init__(self, server, timeout):
        assert timeout == 1800
def setup_mcp_server(client):
    server = FastMCP("hexstrike-ai-mcp")
    @server.tool()
    def echo(value: str) -> str:
        return value
    return server
''')
            with (directory / 'server.log').open('w') as log:
                proc = subprocess.Popen([sys.executable, str(directory / 'hexstrike_bridge.py'),
                                         '--port', str(port)], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=1):
                                break
                        except OSError:
                            if time.monotonic() >= deadline or proc.poll() is not None:
                                self.fail((directory / 'server.log').read_text())
                            time.sleep(0.1)
                    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    def rpc(method, params):
                        req = urllib.request.Request(f'http://127.0.0.1:{port}/mcp',
                            data=json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method,
                                             'params': params}).encode(), headers={
                                'Content-Type': 'application/json',
                                'Accept': 'application/json, text/event-stream',
                                'MCP-Protocol-Version': '2025-03-26'})
                        with http.open(req, timeout=10) as response:
                            self.assertIsNone(response.headers.get('Mcp-Session-Id'))
                            body = json.load(response)
                        self.assertNotIn('error', body)
                        return body['result']
                    for _ in range(3):
                        self.assertEqual(rpc('initialize', {'protocolVersion': '2025-03-26',
                            'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}})
                            ['serverInfo']['name'], 'hexstrike-ai-mcp')
                        self.assertEqual(rpc('tools/list', {})['tools'][0]['name'], 'echo')
                        result = rpc('tools/call', {'name': 'echo', 'arguments': {'value': 'OK'}})
                        self.assertFalse(result.get('isError'))
                        self.assertEqual(result['content'][0]['text'], 'OK')
                finally:
                    proc.terminate()
                    proc.wait(timeout=15)


if __name__ == '__main__':
    unittest.main()
