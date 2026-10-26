#!/bin/zsh
set -euo pipefail
task_dir="${0:A:h}"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/campus-redirect-tests.XXXXXX")"
python3 -u - "$task_temp/port" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import sys
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/entry':
            step = int(parse_qs(url.query).get('step', ['0'])[0])
            if step < 12:
                host = '127.0.0.1' if step % 2 == 0 else 'localhost'
                self.send_response(302)
                self.send_header('Location', f'http://{host}:{self.server.server_port}/entry?step={step+1}')
                self.end_headers()
                return
            body = f'<script>location.replace("http://127.0.0.1:{self.server.server_port}/final?ticket=fixture")</script>'
        elif url.path == '/final':
            # A dependency from another host renders the actual login form.
            body = f'<body><script src="http://localhost:{self.server.server_port}/portal.js"></script></body>'
        elif url.path == '/portal.js':
            body = "document.body.innerHTML='<input name=username><input type=password><button id=login type=button>连接</button>';window.loginClicks=0;login.onclick=()=>{window.observed=[document.querySelector('[name=username]').value,document.querySelector('[type=password]').value];loginClicks++}"
        else:
            body = ''
        content = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript' if url.path.endswith('.js') else 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)
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
export CAMPUS_PROXY_REDIRECT_URL="http://localhost:$(cat "$task_temp/port")/entry"
xcrun swiftc -swift-version 5 "$task_dir/source/Core.swift" "$task_dir/source/CampusProxy.swift" \
  "$task_dir/source/ProxyRedirectTests.swift" -framework AppKit -framework WebKit -framework Network -o "$task_temp/redirect-tests"
"$task_temp/redirect-tests"
