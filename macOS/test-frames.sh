#!/bin/zsh
set -euo pipefail
task_dir="${0:A:h}"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/campus-frames.XXXXXX")"
python3 -u - "$task_temp/port" "$task_dir/../Windows/tests/fixtures/cmcc-union.html" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
fixture = Path(sys.argv[2]).read_bytes()
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = fixture if self.path == '/login' else b'<html><frameset rows="*"><frame src="/login"></frameset></html>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
task_server=$!
trap 'kill "$task_server" 2>/dev/null || true; rm -rf "$task_temp"' EXIT
for task_attempt in {1..50}; do
  [[ -s "$task_temp/port" ]] && break
  sleep 0.1
done
export CAMPUS_FRAME_TEST_URL="http://127.0.0.1:$(cat "$task_temp/port")/"
zsh "$task_dir/test-webkit.sh"
