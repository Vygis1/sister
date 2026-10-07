"""rangeserve.py - serve a folder over HTTP with byte ranges (HEAD and Range: bytes=N-), which
the ESP32's disc fetch (/api/disc/fetch) needs to resume a long transfer.

    python tools/rangeserve.py DIR [PORT]      (default port 8090)
"""
import http.server
import os
import sys
import urllib.parse

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8090


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _file(self):
        p = os.path.join(ROOT, urllib.parse.unquote(self.path.lstrip('/')))
        return p if os.path.isfile(p) and os.path.abspath(p).startswith(ROOT) else None

    def do_HEAD(self):
        p = self._file()
        if not p:
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Length', str(os.path.getsize(p)))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()

    def do_GET(self):
        p = self._file()
        if not p:
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        size = os.path.getsize(p)
        start, end = 0, size - 1
        r = self.headers.get('Range')
        if r and r.startswith('bytes='):
            a, _, b = r[6:].partition('-')
            start = int(a) if a else 0
            end = int(b) if b else size - 1
            self.send_response(206)
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        else:
            self.send_response(200)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        with open(p, 'rb') as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    b = f.read(min(65536, left))
                    if not b:
                        break
                    self.wfile.write(b)
                    left -= len(b)
            except (ConnectionResetError, BrokenPipeError):
                pass

    def log_message(self, fmt, *a):
        sys.stderr.write('%s %s\n' % (self.address_string(), fmt % a))


http.server.ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
