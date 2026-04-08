#!/usr/bin/env python3
import argparse
import http.client
import os
import signal
import ssl
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOP_BY_HOP_HEADERS = {
    "connection",
    "content-length",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind-host", required=True)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()

    class ProxyHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self._forward()

        def do_POST(self):
            self._forward()

        def do_PUT(self):
            self._forward()

        def do_DELETE(self):
            self._forward()

        def do_PATCH(self):
            self._forward()

        def log_message(self, format, *args):
            return

        def _forward(self):
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(content_length) if content_length else b""

                headers = {k: v for (k, v) in self.headers.items() if k.lower() not in HOP_BY_HOP_HEADERS}
                headers["Host"] = f"{args.target_host}:{args.target_port}"

                conn = http.client.HTTPConnection(args.target_host, args.target_port, timeout=30)
                try:
                    conn.request(self.command, self.path, body=body, headers=headers)
                    response = conn.getresponse()
                    payload = response.read()
                    self.send_response(response.status, response.reason)
                    for key, value in response.getheaders():
                        if key.lower() in HOP_BY_HOP_HEADERS:
                            continue
                        self.send_header(key, value)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    if payload:
                        self.wfile.write(payload)
                finally:
                    conn.close()
            except Exception as exc:
                print(f"https_proxy forward failed: {exc}", file=sys.stderr, flush=True)
                traceback.print_exc(file=sys.stderr)
                payload = b'{"error":{"code":"upstream_unavailable","message":"Upstream service unavailable.","retryable":true}}'
                self.send_response(502, "Bad Gateway")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

    print(
        f"https_proxy listening on {args.bind_host}:{args.listen_port} -> {args.target_host}:{args.target_port}",
        file=sys.stderr,
        flush=True,
    )

    httpd = ThreadingHTTPServer((args.bind_host, args.listen_port), ProxyHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=args.cert, keyfile=args.key)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    with open(args.pid_file, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

    def shutdown(*_args):
        try:
            os.remove(args.pid_file)
        except FileNotFoundError:
            pass
        httpd.shutdown()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        httpd.serve_forever()
    finally:
        try:
            os.remove(args.pid_file)
        except FileNotFoundError:
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
