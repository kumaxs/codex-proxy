"""Guard live relay startup and process verification against observed regressions."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).parents[1]
RELAY = (ROOT / "bin/start-relay.sh").read_text()
LAUNCHER = (ROOT / "bin/launch-codex-proxied.sh").read_text()
ANTIGRAVITY_LAUNCHER = (ROOT / "bin/launch-antigravity-proxied.sh").read_text()
ANTIGRAVITY_APP = (ROOT / "app/Antigravity-Proxy.js").read_text()
ANTIGRAVITY_BUILDER = (ROOT / "scripts/build-antigravity-app.sh").read_text()


class RelayRegressionTests(unittest.TestCase):
    def test_log_permission_octal_is_exact(self):
        self.assertIn("mode_decimal=$((8#$mode))", RELAY)
        self.assertIn("if (( mode_decimal != 8#600 )); then", RELAY)
        proc = subprocess.run(
            ["/bin/zsh", "-c",
             'set -u; for mode in 600 644 400; do '
             'mode_decimal=$((8#$mode)); '
             'if (( mode_decimal != 8#600 )); then print reject; else print accept; fi; '
             'done'],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(proc.stdout.splitlines(), ["accept", "reject", "reject"])

    def test_lsof_no_match_is_safe_under_zsh(self):
        self.assertIn('lsof -w -nP', RELAY)
        self.assertIn('if (( lsof_rc == 1 )) && [[ -z "$lsof_output" ]]; then', RELAY)
        self.assertNotIn('(( lsof_rc == 1 && -z "$lsof_output" ))', RELAY)
        proc = subprocess.run(
            ["/bin/zsh", "-c",
             'set -u; lsof_rc=1; lsof_output=""; '
             'if (( lsof_rc == 1 )) && [[ -z "$lsof_output" ]]; then '
             'print no-listener; else exit 7; fi'],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(proc.stdout.strip(), "no-listener")

    def test_build_verification_uses_existing_exact_env_check(self):
        self.assertIn(
            'command_has_exact_env "$env_command" "CODEX_PROXY_APP_BUILD" "$installed_build"',
            LAUNCHER,
        )
        self.assertNotIn("env_value", LAUNCHER)


class AntigravityProxyRegressionTests(unittest.TestCase):
    def test_launcher_routes_browser_and_node_background_traffic(self):
        self.assertIn('"--proxy-server=$UPSTREAM_URL"', ANTIGRAVITY_LAUNCHER)
        self.assertIn('HTTP_PROXY="$RELAY_URL"', ANTIGRAVITY_LAUNCHER)
        self.assertIn('HTTPS_PROXY="$RELAY_URL"', ANTIGRAVITY_LAUNCHER)
        self.assertIn("NODE_USE_ENV_PROXY=1", ANTIGRAVITY_LAUNCHER)
        self.assertIn('NODE_EXTRA_CA_CERTS="$RELAY_CA"', ANTIGRAVITY_LAUNCHER)
        self.assertIn('NO_PROXY="$NO_PROXY_VALUE"', ANTIGRAVITY_LAUNCHER)

    def test_launcher_fails_closed_if_proxy_or_app_is_unavailable(self):
        self.assertIn("check_listeners || exit 1", ANTIGRAVITY_LAUNCHER)
        self.assertIn("if is_running; then", ANTIGRAVITY_LAUNCHER)
        self.assertIn('[[ -x "$APP_EXECUTABLE" ]]', ANTIGRAVITY_LAUNCHER)
        self.assertIn("--status", ANTIGRAVITY_LAUNCHER)

    def test_antigravity_launcher_has_valid_zsh_syntax(self):
        subprocess.run(
            ["/bin/zsh", "-n", str(ROOT / "bin/launch-antigravity-proxied.sh")],
            capture_output=True, text=True, check=True,
        )

    def test_gui_wrapper_enables_shell_runner_and_pins_runtime_home(self):
        self.assertIn("shellRunner.includeStandardAdditions = true", ANTIGRAVITY_APP)
        self.assertIn("CODEX_PROXY_HOME=", ANTIGRAVITY_APP)
        self.assertIn("launch-antigravity-proxied.sh", ANTIGRAVITY_APP)

    def test_app_builder_syntax_and_replace_rollback_are_present(self):
        subprocess.run(
            ["/bin/zsh", "-n", str(ROOT / "scripts/build-antigravity-app.sh")],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("--replace", ANTIGRAVITY_BUILDER)
        self.assertIn("failed to restore the previous app bundle", ANTIGRAVITY_BUILDER)


if __name__ == "__main__":
    unittest.main()
