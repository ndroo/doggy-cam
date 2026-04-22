"""
Tiny static server for HLS: same as `python3 -m http.server`, but tells
Cloudflare/browsers NEVER to cache the .m3u8 playlist (it changes every 2s).
Segments (.ts) keep their default caching since they're immutable per-name.
"""
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class NoCacheHLSHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        path = self.path.split("?", 1)[0]
        if path.endswith(".m3u8") or path.endswith("/") or path.endswith("index.html"):
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        # CORS, in case hls.js loads from a different origin
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    bind = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    with ThreadingHTTPServer((bind, port), NoCacheHLSHandler) as srv:
        print(f"serving HLS on http://{bind}:{port}", flush=True)
        srv.serve_forever()
