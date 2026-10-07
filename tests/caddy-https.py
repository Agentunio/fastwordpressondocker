#!/usr/bin/env python3
"""Run with Docker: python3 tests/caddy-https.py (no existing services are changed)."""

import http.client
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import time
import unittest
from urllib.parse import urlsplit
import uuid


ROOT = Path(__file__).resolve().parents[1]


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, text=True, capture_output=True, timeout=60
    ).stdout.strip()


class CaddyHttpsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="fwd-https-")
        cls.addClassCleanup(temporary.cleanup)
        directory = Path(temporary.name).resolve()
        fixture = "<?php echo $_SERVER['REQUEST_METHOD'] . ':' . file_get_contents('php://input');"
        (directory / "index.php").write_text(fixture)
        for path in ("wp-admin", "wp-includes", "wp-content/uploads"):
            target = directory / path
            target.mkdir(parents=True)
            (target / "index.php").write_text(fixture)

        network = "fwd-https-test-" + uuid.uuid4().hex[:12]
        cls.backend = network + "-wordpress"
        cls.proxy = network + "-caddy"
        docker("network", "create", network)
        cls.addClassCleanup(docker, "network", "rm", network)
        docker(
            "create", "--name", cls.backend, "--network", network,
            "--network-alias", "wordpress", "--entrypoint", "apache2-foreground",
            "-v", f"{directory}:/var/www/html:ro",
            os.environ.get("FWD_TEST_WORDPRESS_IMAGE", "wordpress:php8.4-apache"),
        )
        cls.addClassCleanup(docker, "rm", "-f", "-v", cls.backend)
        docker("start", cls.backend)
        docker(
            "create", "--name", cls.proxy, "--network", network,
            "--network-alias", "https", "-p", "127.0.0.1::443",
            "--tmpfs", "/data", "--tmpfs", "/config", "--tmpfs", "/ca",
            "-e", "WORDPRESS_HTTPS=1", "-e", "WORDPRESS_HTTP_VERSION=2",
            "-v", f"{ROOT / 'Caddyfile'}:/etc/caddy/Caddyfile:ro",
            "-v", f"{ROOT / 'scripts/caddy-entrypoint.sh'}:/entrypoint.sh:ro",
            "--entrypoint", "/bin/sh", "caddy:2.11.4-alpine", "/entrypoint.sh",
        )
        cls.addClassCleanup(docker, "rm", "-f", "-v", cls.proxy)
        docker("start", cls.proxy)
        cls.port = int(docker("port", cls.proxy, "443/tcp").rsplit(":", 1)[1])
        deadline = time.monotonic() + 30
        while True:
            try:
                certificate = docker("exec", cls.proxy, "cat", "/ca/root.crt")
                cls.context = ssl.create_default_context(cadata=certificate)
                if cls.request("https://localhost/")[0] == 200:
                    break
            except (subprocess.CalledProcessError, OSError, http.client.HTTPException):
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError(docker("logs", cls.proxy) + docker("logs", cls.backend))
            time.sleep(0.2)
        (directory / "root.crt").write_text(certificate)

    @classmethod
    def request(cls, url, method="GET", body=None):
        parts = urlsplit(url)
        if parts.scheme == "https":
            connection = http.client.HTTPSConnection(
                parts.hostname, cls.port, context=cls.context, timeout=5
            )
        else:
            connection = http.client.HTTPConnection(parts.hostname, cls.port, timeout=5)
        try:
            path = parts.path or "/"
            if parts.query:
                path += "?" + parts.query
            connection.request(method, path, body, {"Host": parts.netloc})
            response = connection.getresponse()
            return response.status, response.getheader("Location"), response.read()
        finally:
            connection.close()

    def test_directory_redirects_reach_https(self):
        for authority in ("localhost", "localhost:882"):
            for path in ("/wp-admin", "/wp-includes", "/wp-content/uploads"):
                with self.subTest(authority=authority, path=path):
                    url = f"https://{authority}{path}?value=a%2Fb"
                    for _ in range(4):
                        status, location, body = self.request(url)
                        if status == 200:
                            break
                        self.assertIn(status, (301, 302, 307, 308))
                        self.assertIsNotNone(location)
                        url = location
                    self.assertEqual(status, 200)
                    self.assertEqual(url, f"https://{authority}{path}/?value=a%2Fb")
                    self.assertEqual(body, b"GET:")

    def test_plain_http_preserves_authority_path_and_post(self):
        for authority in ("localhost:443", "localhost:882", "127.0.0.1:882"):
            with self.subTest(authority=authority):
                url = f"http://{authority}/index.php?value=a%2Fb"
                status, location, _ = self.request(url, "POST", "example=value")
                self.assertEqual(status, 308)
                self.assertEqual(location, url.replace("http://", "https://", 1))
                status, _, body = self.request(location, "POST", "example=value")
                self.assertEqual(status, 200)
                self.assertEqual(body, b"POST:example=value")

    def test_ip_without_sni_has_valid_certificate(self):
        self.assertEqual(self.request("https://127.0.0.1:882/")[0], 200)

    def test_http2_with_verified_certificate(self):
        version = docker(
            "exec", self.backend, "curl", "--fail", "--silent", "--show-error",
            "--max-time", "10", "--http2", "--cacert", "/var/www/html/root.crt",
            "--connect-to", "localhost:882:https:443", "--output", "/dev/null",
            "--write-out", "%{http_version}", "https://localhost:882/",
        )
        self.assertEqual(version, "2")


if __name__ == "__main__":
    unittest.main()
