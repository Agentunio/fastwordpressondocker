#!/usr/bin/env python3
"""Exercise launcher choices and rollback without Docker or system trust changes."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
OLD_ENV = "PHP_VERSION=8.4\nWORDPRESS_PORT=89\nWORDPRESS_URL=http://localhost:89\nWORDPRESS_OBJECT_CACHE=redis\nCOMPOSE_PROFILES=redis\n"
TLS_ENV = OLD_ENV.replace("http://localhost:89", "https://localhost:8443") + "WORDPRESS_HTTPS=1\nWORDPRESS_HTTP_VERSION=2\nWORDPRESS_HTTPS_PORT=8443\n"
TLS_ENV = TLS_ENV.replace("COMPOSE_PROFILES=redis\n", "COMPOSE_PROFILES=redis,https\n")


class LauncherTests(unittest.TestCase):
    def launch(self, answers, initial=None, fail_trust=False, fail_up=False, environment=None,
               interrupt_at=None, interrupt_signal=signal.SIGINT, fail_before_compose=False,
               fail_rollback=False, existing_storage=False, fail_storage=None, engine_os="Linux",
               missing_image=False, missing_tag=False, manual_restore=False):
        with tempfile.TemporaryDirectory(prefix="fwd-launcher-test-") as directory:
            project = Path(directory)
            shutil.copy2(ROOT / "start.sh", project / "start.sh")
            (project / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/check-wordpress-storage.php", project / "scripts")
            (project / "bin").mkdir()
            (project / "scripts/trust-local-ca.sh").write_text(
                """#!/bin/bash
echo TRUST >> calls
if [ "$FWD_TEST_INTERRUPT_AT" = trust ]; then
    touch interrupt-ready
    exec sleep 30
fi
exit """ + ("7" if fail_trust else "0") + "\n"
            )
            docker = project / "bin/docker"
            docker.write_text("""#!/bin/bash
printf '%s|https=%s|profiles=%s\n' "$*" "$WORDPRESS_HTTPS" "$COMPOSE_PROFILES" >> calls
if [[ "$*" == 'compose ps --all --quiet wordpress' ]]; then
    if [ "$FWD_TEST_FAIL_STORAGE" = ps ]; then exit 5; fi
    if [ "$FWD_TEST_EXISTING_STORAGE" = 1 ]; then echo wordpress-container; fi
    exit 0
fi
if [[ "$*" == 'compose config --format json' ]]; then
    if [ "$FWD_TEST_FAIL_STORAGE" = config ]; then exit 5; fi
    echo '{}'
    exit 0
fi
if [[ "$*" == 'info --format '* ]]; then
    if [ "$FWD_TEST_FAIL_STORAGE" = info ]; then exit 5; fi
    echo "$FWD_TEST_ENGINE_OS"
    exit 0
fi
if [[ "$*" == 'inspect --format '* ]]; then
    if [ "$FWD_TEST_FAIL_STORAGE" = inspect ]; then exit 5; fi
    if [[ "$*" == *'.Mounts'* ]]; then echo '[]'
    elif [[ "$*" == *'.Config.Image'* ]]; then
        if [ "$FWD_TEST_FAIL_STORAGE" = image-reference ]; then exit 5; fi
        echo test-wordpress
    elif [ "$FWD_TEST_FAIL_STORAGE" = image ]; then echo invalid-image
    else printf 'sha256:%064d\n' 0
    fi
    exit 0
fi
if [[ "$*" == 'image inspect '* ]]; then
    if [[ "$*" == *'sha256:'* ]]; then
        [ "$FWD_TEST_MISSING_IMAGE" != 1 ]
        exit $?
    fi
    if [ "$FWD_TEST_MISSING_TAG" = 1 ] && [ ! -f rebuilt ]; then exit 5; fi
    if [ "$FWD_TEST_FAIL_STORAGE" = rebuilt-image ]; then exit 5; fi
    if [ "$FWD_TEST_FAIL_STORAGE" = fallback-id ]; then echo invalid-image
    else printf 'sha256:%064d\n' 1
    fi
    exit 0
fi
if [[ "$*" == 'compose build wordpress' ]]; then
    printf 'build-php=%s\n' "$PHP_VERSION" >> calls
    if [ "$FWD_TEST_FAIL_STORAGE" = build ]; then exit 5; fi
    touch rebuilt
    exit 0
fi
if [[ "$*" == 'run '* ]]; then
    cat >/dev/null
    if [ "$FWD_TEST_MISSING_IMAGE" = 1 ] && [[ "$*" == *"sha256:$(printf '%064d' 0)"* ]]; then
        echo 'No such image' >&2
        exit 5
    fi
    if [ "$FWD_TEST_FAIL_STORAGE" = validator ]; then exit 5; fi
    exit 0
fi
if [[ "$*" == *' up '* ]] && [ "$FWD_TEST_INTERRUPT_AT" = up ] && [ ! -f interrupted ]; then
    touch interrupted interrupt-ready
    exec sleep 30
fi
if [[ "$*" == *' up '* ]] && [ -f fail-up ]; then
    rm fail-up
    exit 6
fi
if [[ "$*" == *' up '* ]] && [ -f fail-rollback ]; then
    exit 9
fi
if [[ "$*" == *' exec '*curl* ]]; then
    printf '%s' "$WORDPRESS_HTTP_VERSION"
fi
""")
            docker.chmod(0o755)
            chmod = project / "bin/chmod"
            chmod.write_text("""#!/bin/bash
if [ "$*" = '600 .env' ]; then
    if [ "$FWD_TEST_INTERRUPT_AT" = before-compose ]; then
        touch interrupt-ready
        exec sleep 30
    fi
    if [ -f fail-before-compose ]; then exit 8; fi
fi
exec """ + shutil.which("chmod") + ' "$@"\n')
            chmod.chmod(0o755)
            if initial is not None:
                (project / ".env").write_text(initial)
            if fail_up:
                (project / "fail-up").touch()
            if fail_before_compose:
                (project / "fail-before-compose").touch()
            if fail_rollback:
                (project / "fail-rollback").touch()
            env = os.environ.copy()
            for key in list(env):
                if key.startswith(("WORDPRESS_", "COMPOSE_")):
                    del env[key]
            env.update(environment or {})
            env["FWD_TEST_INTERRUPT_AT"] = interrupt_at or ""
            env["FWD_TEST_EXISTING_STORAGE"] = "1" if existing_storage else "0"
            env["FWD_TEST_FAIL_STORAGE"] = fail_storage or ""
            env["FWD_TEST_ENGINE_OS"] = engine_os
            env["FWD_TEST_MISSING_IMAGE"] = "1" if missing_image else "0"
            env["FWD_TEST_MISSING_TAG"] = "1" if missing_tag else "0"
            env["PATH"] = str(project / "bin") + os.pathsep + env["PATH"]
            command = ["bash", "./start.sh"]
            if manual_restore:
                command.append("--manual-restore")
            if interrupt_at:
                with subprocess.Popen(command, cwd=project, env=env, stdin=subprocess.PIPE,
                                      text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      start_new_session=True) as process:
                    try:
                        process.stdin.write(answers)
                        process.stdin.flush()
                        deadline = time.monotonic() + 10
                        while not (project / "interrupt-ready").exists():
                            if process.poll() is not None or time.monotonic() >= deadline:
                                self.fail("Launcher did not reach the interrupt checkpoint")
                            time.sleep(0.01)
                        os.killpg(process.pid, interrupt_signal)
                        output, _ = process.communicate(timeout=10)
                        result = subprocess.CompletedProcess(command, process.returncode, output)
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.communicate()
            else:
                result = subprocess.run(
                    command, cwd=project, env=env,
                    input=answers, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    start_new_session=True, timeout=15,
                )
            saved = (project / ".env").read_text() if (project / ".env").exists() else None
            calls = (project / "calls").read_text() if (project / "calls").exists() else ""
            return result, saved, calls

    def test_fresh_defaults_keep_http(self):
        result, saved, calls = self.launch("1\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WORDPRESS_HTTPS=0\n", saved)
        self.assertIn("WORDPRESS_HTTP_VERSION=1.1\n", saved)
        self.assertIn("WORDPRESS_URL=http://localhost\n", saved)
        self.assertIn("COMPOSE_PROFILES=none\n", saved)
        self.assertNotIn("TRUST", calls)

    def test_existing_env_without_transport_keys(self):
        result, saved, calls = self.launch("1\n", OLD_ENV)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WORDPRESS_URL=http://localhost:89\n", saved)
        self.assertIn("COMPOSE_PROFILES=redis\n", saved)
        self.assertNotIn("TRUST", calls)

    def test_custom_https_http2_and_port(self):
        result, saved, calls = self.launch("2\n1\n1\n1\n1\n2\n2\n1\n2\n8443\n1\n1\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WORDPRESS_URL=https://localhost:8443\n", saved)
        self.assertIn("WORDPRESS_HTTP_VERSION=2\n", saved)
        self.assertIn("COMPOSE_PROFILES=none,https\n", saved)
        self.assertIn("--http2", calls)
        self.assertIn("TRUST", calls)

    def test_custom_https_http1(self):
        result, saved, calls = self.launch("2\n1\n1\n1\n1\n2\n1\n1\n1\n1\n1\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WORDPRESS_URL=https://localhost\n", saved)
        self.assertIn("WORDPRESS_HTTP_VERSION=1.1\n", saved)
        self.assertIn("--http1.1", calls)

    def test_current_https_and_cache_override_exported_values(self):
        result, saved, calls = self.launch("1\n", TLS_ENV, environment={"WORDPRESS_HTTPS": "0", "COMPOSE_PROFILES": "none"})
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WORDPRESS_URL=https://localhost:8443\n", saved)
        self.assertIn("https=1|profiles=redis,https", calls)
        self.assertIn("TRUST", calls)

    def test_disabling_https_restores_http_and_stops_proxy(self):
        result, saved, calls = self.launch("2\n1\n1\n1\n1\n1\n1\n1\n1\n", TLS_ENV)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WORDPRESS_URL=http://localhost:89\n", saved)
        self.assertIn("WORDPRESS_HTTP_VERSION=1.1\n", saved)
        self.assertIn("COMPOSE_PROFILES=redis\n", saved)
        self.assertLess(calls.index("stop https"), calls.index(" up "))
        self.assertNotIn("TRUST", calls)

    def test_http2_without_https_is_rejected_before_docker(self):
        initial = OLD_ENV + "WORDPRESS_HTTP_VERSION=2\n"
        result, saved, calls = self.launch("1\n", initial)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(saved, initial)
        self.assertEqual(calls, "")

    def test_https_port_collision_handles_leading_zero(self):
        initial = TLS_ENV.replace("WORDPRESS_HTTPS_PORT=8443", "WORDPRESS_HTTPS_PORT=0089")
        result, saved, calls = self.launch("1\n", initial)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(saved, initial)
        self.assertEqual(calls, "")

    def test_failed_enable_restores_previous_runtime_and_env(self):
        # Existing settings: current PHP/plugins/cache/admin, then enable HTTP/2.
        result, saved, calls = self.launch("2\n1\n1\n1\n1\n2\n2\n1\n1\n1\n1\n", OLD_ENV, fail_trust=True)
        self.assertEqual(result.returncode, 7, result.stdout)
        self.assertEqual(saved, OLD_ENV)
        self.assertIn("TRUST", calls)
        self.assertIn("stop https|https=0|profiles=redis", calls)
        self.assertEqual(calls.count(" up "), 2)

    def test_failed_disable_restores_previous_https_profile(self):
        result, saved, calls = self.launch("2\n1\n1\n1\n1\n1\n1\n1\n1\n", TLS_ENV, fail_up=True)
        self.assertEqual(result.returncode, 6, result.stdout)
        self.assertEqual(saved, TLS_ENV)
        self.assertIn("up -d --wait --wait-timeout 360|https=1|profiles=redis,https", calls)

    def test_interrupted_enable_restores_previous_runtime_once(self):
        for checkpoint in ("up", "trust"):
            for interrupt in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(checkpoint=checkpoint, signal=interrupt):
                    result, saved, calls = self.launch(
                        "2\n1\n1\n1\n1\n2\n2\n1\n1\n1\n1\n", OLD_ENV,
                        interrupt_at=checkpoint, interrupt_signal=interrupt,
                    )
                    self.assertEqual(result.returncode, 128 + interrupt, result.stdout)
                    self.assertEqual(saved, OLD_ENV)
                    self.assertEqual(calls.count(" up "), 2, calls)
                    self.assertEqual(calls.count("stop https|https=0|profiles=redis"), 1, calls)
                    self.assertIn("up -d --wait --wait-timeout 360|https=0|profiles=redis", calls)

    def test_interrupted_disable_restores_previous_https(self):
        result, saved, calls = self.launch(
            "2\n1\n1\n1\n1\n1\n1\n1\n1\n", TLS_ENV, interrupt_at="up",
        )
        self.assertEqual(result.returncode, 130, result.stdout)
        self.assertEqual(saved, TLS_ENV)
        self.assertEqual(calls.count(" up "), 2, calls)
        self.assertIn("up -d --wait --wait-timeout 360|https=1|profiles=redis,https", calls)

    def test_interrupted_first_start_stops_all_attempted_services(self):
        for checkpoint in ("up", "trust"):
            for interrupt in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(checkpoint=checkpoint, signal=interrupt):
                    result, saved, calls = self.launch(
                        "2\n1\n1\n1\n1\n2\n2\n1\n1\n1\n1\n",
                        interrupt_at=checkpoint, interrupt_signal=interrupt,
                    )
                    self.assertEqual(result.returncode, 128 + interrupt, result.stdout)
                    self.assertIsNone(saved)
                    self.assertEqual(calls.count(" up "), 1, calls)
                    self.assertEqual(calls.count("compose stop|https=1|profiles=none,https"), 1, calls)
                    self.assertNotIn("down", calls)

    def test_failed_first_start_stops_all_attempted_services(self):
        result, saved, calls = self.launch("1\n", fail_up=True)
        self.assertEqual(result.returncode, 6, result.stdout)
        self.assertIsNone(saved)
        self.assertEqual(calls.count(" up "), 1, calls)
        self.assertEqual(calls.count("compose stop|https=0|profiles=none"), 1, calls)

    def test_failure_before_compose_restores_only_env(self):
        for initial in (None, OLD_ENV):
            with self.subTest(initial=initial):
                result, saved, calls = self.launch("1\n", initial, fail_before_compose=True)
                self.assertEqual(result.returncode, 8, result.stdout)
                self.assertEqual(saved, initial)
                self.assertEqual(calls, "")

    def test_interrupt_before_compose_restores_only_env(self):
        for initial in (None, OLD_ENV):
            for interrupt in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(initial=initial, signal=interrupt):
                    result, saved, calls = self.launch(
                        "1\n", initial, interrupt_at="before-compose", interrupt_signal=interrupt,
                    )
                    self.assertEqual(result.returncode, 128 + interrupt, result.stdout)
                    self.assertEqual(saved, initial)
                    self.assertEqual(calls, "")

    def test_failed_rollback_preserves_original_error_without_retrying(self):
        result, saved, calls = self.launch("1\n", OLD_ENV, fail_up=True, fail_rollback=True)
        self.assertEqual(result.returncode, 6, result.stdout)
        self.assertEqual(saved, OLD_ENV)
        self.assertEqual(calls.count(" up "), 2, calls)
        self.assertIn("previous configuration could not be restarted", result.stdout)

    def test_storage_check_precedes_proxy_stop_and_start(self):
        result, saved, calls = self.launch("2\n1\n1\n1\n1\n1\n1\n1\n1\n", TLS_ENV, existing_storage=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--network none --read-only --cap-drop ALL", calls)
        self.assertLess(calls.index("compose config --format json"), calls.index("run --rm"))
        self.assertLess(calls.index("run --rm"), calls.index("stop https"))
        self.assertLess(calls.index("stop https"), calls.index(" up "))

    def test_storage_preflight_failure_restores_env_without_runtime_rollback(self):
        for initial in (None, OLD_ENV, TLS_ENV):
            for stage in ("ps", "config", "info", "inspect", "image", "validator"):
                with self.subTest(initial=initial, stage=stage):
                    result, saved, calls = self.launch("1\n", initial, existing_storage=True, fail_storage=stage)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(saved, initial)
                    self.assertNotIn(" up ", calls)
                    self.assertNotIn(" stop", calls)
                    self.assertNotIn("TRUST", calls)

    def test_storage_alias_mode_requires_verified_desktop_engine(self):
        for engine, mode in (("Docker Desktop", "1"), ("Linux", "0"), ("docker desktop", "0"), ("", "0")):
            with self.subTest(engine=engine):
                result, _, calls = self.launch("1\n", OLD_ENV, existing_storage=True, engine_os=engine)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("--env FAST_WORDPRESS_DOCKER_DESKTOP=" + mode, calls)

    def test_storage_uses_cached_tag_when_original_image_is_missing(self):
        result, _, calls = self.launch("1\n", OLD_ENV, existing_storage=True, missing_image=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--entrypoint php sha256:" + "0" * 63 + "1", calls)
        self.assertNotIn("compose build wordpress", calls)

    def test_storage_rebuilds_missing_tag_before_validation(self):
        result, _, calls = self.launch("1\n", OLD_ENV, existing_storage=True,
                                       missing_image=True, missing_tag=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(calls.count("compose build wordpress"), 1)
        self.assertLess(calls.index("compose build wordpress"), calls.index("run --rm"))
        self.assertLess(calls.index("run --rm"), calls.index("stop https"))
        self.assertIn("--entrypoint php sha256:" + "0" * 63 + "1", calls)

    def test_storage_recovery_failure_preserves_existing_configuration(self):
        for stage in ("image-reference", "build", "rebuilt-image", "fallback-id", "validator"):
            with self.subTest(stage=stage):
                result, saved, calls = self.launch("1\n", TLS_ENV, existing_storage=True,
                                                  missing_image=True, missing_tag=True, fail_storage=stage)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(saved, TLS_ENV)
                self.assertNotIn(" up ", calls)
                self.assertNotIn(" stop", calls)
                self.assertNotIn("TRUST", calls)

    def test_manual_restore_with_custom_ports_and_missing_image(self):
        result, saved, calls = self.launch("2\n4\n1\n1\n1\n1\n2\n81\n2\n8181\n2\n8111\n",
                                          existing_storage=True, missing_image=True,
                                          missing_tag=True, manual_restore=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        for setting in ("PHP_VERSION=8.4", "WORDPRESS_PORT=81", "PHPMYADMIN_PORT=8181",
                        "MAILPIT_PORT=8111", "WORDPRESS_HTTPS=0", "WORDPRESS_OBJECT_CACHE=none"):
            self.assertIn(setting + "\n", saved)
        self.assertLess(calls.index("run --rm"), calls.index(" up "))
        self.assertLess(calls.index(" up "), calls.index("bash /scripts/restore-manual.sh"))

    def test_storage_rebuild_preserves_previous_php_when_new_settings_are_rejected(self):
        result, saved, calls = self.launch("2\n2\n1\n1\n1\n1\n1\n1\n1\n", OLD_ENV,
                                          existing_storage=True, missing_image=True,
                                          missing_tag=True, fail_storage="validator")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Starting WordPress with PHP 8.3", result.stdout)
        self.assertIn("build-php=8.4\n", calls)
        self.assertEqual(saved, OLD_ENV)
        self.assertNotIn(" up ", calls)
        self.assertNotIn(" stop", calls)


if __name__ == "__main__":
    unittest.main()
