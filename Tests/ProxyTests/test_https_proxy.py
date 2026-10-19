import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


PROXY = Path(__file__).resolve().parents[2] / "proxy"
sys.path.insert(0, str(PROXY))
from tls_certificates import TLSCertificates


class CertificateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.pairs = []
        config = Path(cls.fixtures.name) / "certificate.cnf"
        for number in range(2):
            config.write_text(f"[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=Fixture {number}\n[ext]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nsubjectKeyIdentifier=hash\nsubjectAltName=DNS:processor.example.ts.net\nextendedKeyUsage=serverAuth\n")
            certificate = Path(cls.fixtures.name) / f"{number}.crt"
            key = certificate.with_suffix(".key")
            subprocess.run([
                "/usr/bin/openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                "-days", "1", "-config", str(config),
                "-keyout", str(key), "-out", str(certificate),
            ], check=True, capture_output=True)
            cls.pairs.append((certificate.read_bytes(), key.read_bytes()))

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.cert = Path(self.root.name) / "server.crt"
        self.key = Path(self.root.name) / "server.key"
        self.cert.write_bytes(self.pairs[0][0])
        self.key.write_bytes(self.pairs[0][1])
        self.manager = TLSCertificates(self.cert, self.key, lambda _: None)
        self.pair = self.pairs[0]

    def command(self, arguments, **kwargs):
        self.assertEqual(kwargs["env"]["TAILSCALE_BE_CLI"], "1")
        if arguments[1] == "status":
            return subprocess.CompletedProcess(arguments, 0, json.dumps({
                "BackendState": "Running", "Self": {"DNSName": "processor.example.ts.net."},
                "CertDomains": ["processor.example.ts.net"],
            }).encode(), b"")
        self.assertIn("--min-validity=336h", arguments)
        Path(arguments[arguments.index("--cert-file") + 1]).write_bytes(self.pair[0])
        Path(arguments[arguments.index("--key-file") + 1]).write_bytes(self.pair[1])
        return subprocess.CompletedProcess(arguments, 0, b"", b"")

    def test_renewal_publishes_complete_pair_and_reuses_unchanged_certificate(self):
        with patch("tls_certificates.os.access", return_value=True), patch("tls_certificates.subprocess.run", side_effect=self.command):
            self.assertIsInstance(self.manager.initial_context(), ssl.SSLContext)
            first = self.manager.current.resolve()
            self.assertIsNone(self.manager.refresh())
            self.assertEqual(self.manager.current.resolve(), first)
            self.pair = self.pairs[1]
            self.assertIsInstance(self.manager.refresh(), ssl.SSLContext)
            self.assertNotEqual(self.manager.current.resolve(), first)
            self.assertEqual((self.manager.current / "server.crt").read_bytes(), self.pair[0])
            self.assertEqual((self.manager.current / "server.key").stat().st_mode & 0o777, 0o600)

    def test_bad_replacement_and_tailscale_outage_preserve_last_working_pair(self):
        with patch("tls_certificates.os.access", return_value=True), patch("tls_certificates.subprocess.run", side_effect=self.command):
            self.manager.initial_context()
            first = self.manager.current.resolve()
            self.pair = (self.pairs[1][0], self.pairs[0][1])
            with self.assertRaises(ssl.SSLError):
                self.manager.refresh()
            self.assertEqual(self.manager.current.resolve(), first)
        with patch("tls_certificates.subprocess.run", side_effect=subprocess.TimeoutExpired("tailscale", 15)):
            self.assertIsInstance(self.manager.initial_context(), ssl.SSLContext)

    def test_no_tailscale_keeps_manually_provisioned_certificate(self):
        with patch("tls_certificates.os.access", return_value=False):
            self.assertIsInstance(self.manager.initial_context(), ssl.SSLContext)
            self.assertFalse(self.manager.current.exists())

    def test_https_disabled_does_not_request_a_certificate(self):
        status = subprocess.CompletedProcess([], 0, json.dumps({
            "BackendState": "Running", "Self": {"DNSName": "processor.example.ts.net."},
            "CertDomains": [],
        }).encode(), b"")
        with patch("tls_certificates.os.access", return_value=True), patch("tls_certificates.subprocess.run", return_value=status) as run:
            self.assertIsInstance(self.manager.initial_context(), ssl.SSLContext)
            self.assertEqual(run.call_count, 1)
            self.assertFalse(self.manager.current.exists())

    def test_new_connections_use_renewed_context_without_restarting_listener(self):
        trust = self.cert.with_name("trusted.crt")
        trust.write_bytes(self.pairs[0][0] + self.pairs[1][0])
        client = ssl.create_default_context(cafile=str(trust))
        with socket.socket() as raw_listener:
            raw_listener.bind(("127.0.0.1", 0))
            raw_listener.listen(5)
            port = raw_listener.getsockname()[1]
            initial = self.manager.context(self.cert, self.key)
            active = [initial]
            initial.set_servername_callback(lambda connection, _name, _initial: setattr(connection, "context", active[0]))
            with initial.wrap_socket(raw_listener, server_side=True) as listener:
                def fingerprint():
                    def accept():
                        connection, _ = listener.accept()
                        connection.close()
                    thread = threading.Thread(target=accept)
                    thread.start()
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                        with client.wrap_socket(raw, server_hostname="processor.example.ts.net") as connection:
                            result = connection.getpeercert(binary_form=True)
                    thread.join(timeout=5)
                    return result
                first = fingerprint()
                self.cert.write_bytes(self.pairs[1][0])
                self.key.write_bytes(self.pairs[1][1])
                active[0] = self.manager.context(self.cert, self.key)
                self.assertNotEqual(fingerprint(), first)

    def test_tls_proxy_forwards_macos_headers_once(self):
        class Upstream(BaseHTTPRequestHandler):
            def do_GET(self):
                fields = [name.lower() for name in self.headers.keys()]
                payload = json.dumps(fields).encode()
                self.send_response(200 if len(fields) == len(set(fields)) else 400)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        # Run the actual proxy in a wrapper, without contacting this Mac's Tailscale.
        wrapper = "import runpy,sys; from unittest.mock import patch; sys.path.insert(0,sys.argv.pop(1)); from tls_certificates import TLSCertificates; p=patch.object(TLSCertificates,'refresh',return_value=None); p.start(); runpy.run_path(sys.argv.pop(1),run_name='__main__')"
        process = subprocess.Popen([
            sys.executable, "-c", wrapper, str(PROXY), str(PROXY / "https_proxy.py"),
            "--bind-host", "127.0.0.1", "--listen-port", str(port),
            "--target-host", "127.0.0.1", "--target-port", str(upstream.server_port),
            "--cert", str(self.cert), "--key", str(self.key),
            "--pid-file", str(Path(self.root.name) / "proxy.pid"), "--parent-pid", str(os.getpid()),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if (Path(self.root.name) / "proxy.pid").exists():
                    break
                if process.poll() is not None:
                    self.fail(process.stderr.read().decode())
                time.sleep(0.02)
            context = ssl.create_default_context(cafile=str(self.cert))
            # The fixture is for a generic DNS name, so connect with that SNI.
            with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname="processor.example.ts.net") as connection:
                    connection.sendall(b"GET /health HTTP/1.1\r\nHost: processor.example.ts.net\r\nAccept-Encoding: gzip, deflate, br\r\nConnection: close\r\n\r\n")
                    response = http.client.HTTPResponse(connection)
                    response.begin()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.loads(response.read()).count("accept-encoding"), 1)
        finally:
            process.terminate()
            process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
