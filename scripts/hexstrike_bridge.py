#!/usr/bin/env python3
"""Run the upstream HexStrike tools over stateless Streamable HTTP.

Copy next to hexstrike_mcp.py during installation; leave upstream source intact.
"""
import argparse

from hexstrike_mcp import HexStrikeClient, setup_mcp_server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default='http://127.0.0.1:8888')
    parser.add_argument('--port', type=int, default=8890)
    args = parser.parse_args()
    server = setup_mcp_server(HexStrikeClient(args.server, timeout=1800))
    server.settings.host = '127.0.0.1'
    server.settings.port = args.port
    server.settings.stateless_http = True
    server.settings.json_response = True
    server.run(transport='streamable-http')


if __name__ == '__main__':
    main()
