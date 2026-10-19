#!/usr/bin/env python3
"""ACK Lab API v1: minimal HTTP server exposing /healthz and /db-check."""
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, "/app/vendor")
import pymysql

DB_HOST = os.environ.get("DB_HOST", "mysql")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "demo")
PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    server_version = "ack-api/1.0"

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"status": "ok", "service": "ack-api", "version": "v1", "hostname": socket.gethostname()})
        elif self.path == "/db-check":
            try:
                conn = pymysql.connect(host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD, database=DB_NAME, connect_timeout=5)
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT VERSION()")
                        row = cur.fetchone()
                finally:
                    conn.close()
                self._send(200, {"status": "ok", "mysql": row[0], "db_host": DB_HOST, "db_name": DB_NAME})
            except Exception as exc:
                self._send(503, {"status": "error", "error": str(exc)})
        else:
            self._send(200, {"service": "ack-api", "version": "v1", "endpoints": ["/healthz", "/db-check"]})

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main():
    print("ack-api v1 listening on 0.0.0.0:%d" % PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()