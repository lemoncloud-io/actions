"""Mock DoU webhook: /ok stores the request body and answers like the real endpoint, /fail answers 500."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PORT = int(sys.argv[1])
OUT = Path(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/ok":
            self._reply(500, {"error": "boom"})
            return
        (OUT / "request.json").write_bytes(body)
        channel = json.loads(body).get("channelId")
        self._reply(200, {"id": f"{channel}:1", "chatNo": 1, "stereo": "webhook"})

    def _reply(self, code, payload):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
