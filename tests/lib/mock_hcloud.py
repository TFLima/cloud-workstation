"""Servidor HTTP falso da API Hetzner para testes (somente leitura, local).

Uso: python3 -I mock_hcloud.py <dir_fixtures> <arquivo_porta>
Responde 401 se o cabeçalho Authorization estiver ausente; serve
<dir>/server_types-<nome>.json, <dir>/pricing.json e <dir>/servers-<id>.json.
"""
import http.server
import json
import os
import sys
import urllib.parse

FIXTURES = sys.argv[1]
PORT_FILE = sys.argv[2]
EXPECTED = "Bearer " + ("a" * 64)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.headers.get("Authorization") != EXPECTED:
            return self._send(401, {"error": {"code": "unauthorized"}})
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/v1/server_types":
            name = query.get("name", [""])[0]
            path = os.path.join(FIXTURES, f"server_types-{name}.json")
            if not os.path.exists(path):
                return self._send(200, {"server_types": []})
        elif url.path == "/v1/pricing":
            path = os.path.join(FIXTURES, "pricing.json")
        else:
            return self._send(404, {"error": {"code": "not_found"}})
        with open(path) as fh:
            self._send(200, json.load(fh))


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
