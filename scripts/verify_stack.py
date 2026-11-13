#!/usr/bin/env python3
"""Check real API responses and MCP tools, without relying on agent prose."""
import argparse
import json
import re
import sys
import urllib.request

HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(url, payload=None):
    req = urllib.request.Request(
        url, data=None if payload is None else json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json',
                 'Accept': 'application/json, text/event-stream',
                 'MCP-Protocol-Version': '2025-03-26'})
    with HTTP.open(req, timeout=180 if payload else 10) as response:
        return json.load(response)


def rpc(method, params, mcp_url):
    result = request(mcp_url,
                     {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    if 'error' in result:
        raise ValueError(result['error'])
    return result['result']


def scan_output(result, port=8000):
    if result.get('isError'):
        raise ValueError(f'MCP tool failed: {result}')
    parts = []
    for item in result.get('content', []):
        text = item.get('text', '')
        try:
            parsed = json.loads(text)
        except ValueError:
            parts.append(text)
            continue
        if isinstance(parsed, dict):
            if parsed.get('success') is False or parsed.get('error'):
                raise ValueError(f'Nmap execution failed: {parsed}')
            parts.append(parsed.get('stdout', ''))
    output = '\n'.join(parts)
    if not re.search(rf'^{port}/tcp\s+open\b', output, re.MULTILINE):
        raise ValueError(f'Local scan did not confirm port {port}: {output}')
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model-port', type=int, default=8000)
    parser.add_argument('--model-alias', default='pharaoh-agent')
    parser.add_argument('--mcp-port', type=int, default=8890)
    args = parser.parse_args()
    model_base = f'http://127.0.0.1:{args.model_port}'
    mcp_url = f'http://127.0.0.1:{args.mcp_port}/mcp'

    models = request(f'{model_base}/v1/models')
    assert any(m['id'] == args.model_alias for m in models['data']), 'Missing model alias'
    reply = request(f'{model_base}/v1/chat/completions', {
        'model': args.model_alias, 'messages': [{'role': 'user', 'content': 'Say OK'}],
        'max_tokens': 32, 'chat_template_kwargs': {'enable_thinking': False}})
    assert (reply['choices'][0]['message'].get('content') or '').strip(), 'Empty completion'
    print('[OK] Model alias and actual chat inference')
    health = request('http://127.0.0.1:8888/health')
    for name in ('nmap', 'nuclei', 'sqlmap'):
        assert health.get('tools_status', {}).get(name) is True, f'{name} is unavailable'
    print('[OK] Required tools are installed (not just listed)')
    initialized = rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                    'clientInfo': {'name': 'pharaoh-verify', 'version': '1'}}, mcp_url)
    assert initialized['serverInfo']['name'] == 'hexstrike-ai-mcp'
    names, cursor = set(), None
    while True:
        result = rpc('tools/list', {} if cursor is None else {'cursor': cursor}, mcp_url)
        names.update(tool['name'] for tool in result['tools'])
        cursor = result.get('nextCursor')
        if not cursor:
            break
    for name in ('nmap_scan', 'nuclei_scan', 'sqlmap_scan'):
        assert name in names, f'Missing MCP tool: {name}'
    print(f'[OK] Stateless MCP handshake and {len(names)} registered tools')
    # Test the complete bridge -> tools API -> nmap path against this host only.
    result = rpc('tools/call', {'name': 'nmap_scan', 'arguments': {
        'target': '127.0.0.1', 'scan_type': '-sT', 'ports': str(args.model_port),
        'additional_args': '-Pn'}}, mcp_url)
    scan_output(result, args.model_port)
    print(f'[OK] Real nmap scan through MCP confirmed local port {args.model_port}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AssertionError) as exc:
        print(f'[FAIL] {exc}', file=sys.stderr)
        sys.exit(1)
