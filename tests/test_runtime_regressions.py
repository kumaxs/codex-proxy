"""Guard live relay startup and process verification against observed regressions."""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).parents[1]
RELAY = (ROOT / "bin/start-relay.sh").read_text()
LAUNCHER = (ROOT / "bin/launch-codex-proxied.sh").read_text()


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


if __name__ == "__main__":
    unittest.main()
