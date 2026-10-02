#!/usr/bin/env python3
"""Serves one file on 127.0.0.1, slowly, so a screenshot run can catch a download in progress.

Usage: slow-serve.py <file> <port> <bytes per second>

GET /<file name> answers with the file (and its Content-Length) in 64 KB chunks at about that
rate; anything else is a 404. Used by shoot-own-php.sh for Runlet's PHP archive.
"""
import http.server
import os
import sys
import time

path, port, rate = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
name = os.path.basename(path)
CHUNK = 64 * 1024


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.lstrip("/") != name:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(os.path.getsize(path)))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                while chunk := f.read(CHUNK):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    time.sleep(len(chunk) / rate)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        sys.stderr.write("slow-serve: " + format % args + "\n")


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
