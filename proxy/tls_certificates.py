"""Obtain and renew Tailscale HTTPS certificates without interrupting uploads."""

import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile


class TLSCertificates:
    def __init__(self, certificate, key, log):
        self.certificate = Path(certificate)
        self.key = Path(key)
        self.directory = self.certificate.parent / "tailscale-certificates"
        self.current = self.directory / "current"
        self.log = log

    @staticmethod
    def context(certificate, key):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=str(certificate), keyfile=str(key))
        return context

    def initial_context(self):
        try:
            context = self.refresh()
            if context is not None:
                return context
        except Exception as error:
            self.log(f"Tailscale certificate provisioning failed: {error}; retaining existing certificate.")
        if self.current.is_dir():
            return self.context(self.current / "server.crt", self.current / "server.key")
        return self.context(self.certificate, self.key)

    def refresh(self):
        binary = next((path for path in (
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ) if os.access(path, os.X_OK)), None)
        if binary is None:
            return None
        result = subprocess.run([binary, "status", "--json"], capture_output=True, timeout=15)
        if result.returncode:
            raise RuntimeError("Tailscale status is unavailable")
        status = json.loads(result.stdout)
        domain = (status.get("Self") or {}).get("DNSName", "").rstrip(".")
        if status.get("BackendState") != "Running":
            return None
        domains = [name.rstrip(".") for name in status.get("CertDomains", [])]
        if domain not in domains:
            self.log("Tailscale HTTPS certificates are not enabled for this machine; using existing certificate.")
            return None
        if not re.fullmatch(r"[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.ts\.net", domain):
            raise RuntimeError("Unexpected Tailscale certificate domain")

        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        staged = Path(tempfile.mkdtemp(prefix="issued-", dir=str(self.directory)))
        temporary_link = self.directory / "next"
        published = False
        try:
            certificate, key = staged / "server.crt", staged / "server.key"
            # The daemon caches certificates. Requiring two weeks of validity
            # triggers renewal before expiry without issuing a new cert each poll.
            result = subprocess.run([
                binary, "cert", "--min-validity=336h",
                "--cert-file", str(certificate), "--key-file", str(key), domain,
            ], capture_output=True, timeout=120)
            if result.returncode:
                raise RuntimeError(f"Tailscale certificate request failed (exit {result.returncode})")
            os.chmod(key, 0o600)
            context = self.context(certificate, key)  # Validate the pair before publishing it.
            if self.current.is_dir() and all(
                (staged / name).read_bytes() == (self.current / name).read_bytes()
                for name in ("server.crt", "server.key")
            ):
                return None
            previous = self.current.resolve() if self.current.is_dir() else None
            temporary_link.unlink(missing_ok=True)
            temporary_link.symlink_to(staged.name, target_is_directory=True)
            os.replace(temporary_link, self.current)  # Publish the complete pair atomically.
            published = True
            for old in self.directory.glob("issued-*"):
                if old != staged and old != previous and old.is_dir():
                    shutil.rmtree(old, ignore_errors=True)
            self.log(f"Loaded trusted HTTPS certificate for {domain}.")
            return context
        finally:
            temporary_link.unlink(missing_ok=True)
            if not published:
                shutil.rmtree(staged, ignore_errors=True)
