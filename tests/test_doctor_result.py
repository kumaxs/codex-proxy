import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).parents[1] / "lib/doctor-result.py"
spec = importlib.util.spec_from_file_location("doctor_result", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DoctorSchemaTests(unittest.TestCase):
    def test_current_schema_accepts_websocket_ok_even_with_other_warnings(self):
        report = {"schemaVersion": 2, "overallStatus": "warning",
                  "checks": {"network.websocket_reachability": {"status": "ok"},
                             "network.provider_reachability": {"status": "warning"}}}
        self.assertTrue(module.websocket_ok(report))

    def test_current_schema_rejects_failed_websocket(self):
        for status in ("warning", "error", "fail", "unknown", None):
            report = {"overallStatus": "warning",
                      "checks": {"network.websocket_reachability": {"status": status}}}
            self.assertFalse(module.websocket_ok(report))

    def test_current_schema_rejects_overall_failure(self):
        for status in ("failed", "error"):
            report = {"overallStatus": status,
                      "checks": {"network.websocket_reachability": {"status": "ok"}}}
            self.assertFalse(module.websocket_ok(report))

    def first_login_report(self):
        return {
            "overallStatus": "fail",
            "checks": {
                "auth.credentials": {
                    "status": "fail",
                    "summary": "no Codex credentials were found",
                },
                "network.websocket_reachability": {
                    "status": "warning",
                    "details": {
                        "auth mode": "none",
                        "handshake transport error": "http 401 Unauthorized: Missing bearer or basic authentication in header",
                    },
                },
                "network.provider_reachability": {"status": "ok"},
                "network.env": {"status": "ok"},
            },
        }

    def test_first_login_allows_only_unauthenticated_401(self):
        self.assertTrue(module.first_login_ok(self.first_login_report()))
        self.assertFalse(module.websocket_ok(self.first_login_report()))

    def test_first_login_fails_closed_for_transport_or_other_failure(self):
        report = self.first_login_report()
        report["checks"]["network.websocket_reachability"]["details"]["handshake transport error"] = "connection refused"
        self.assertFalse(module.first_login_ok(report))
        report = self.first_login_report()
        report["checks"]["network.provider_reachability"]["status"] = "warning"
        self.assertFalse(module.first_login_ok(report))
        report = self.first_login_report()
        report["checks"]["security.endpoint"] = {"status": "fail"}
        self.assertFalse(module.first_login_ok(report))
        report = self.first_login_report()
        report["checks"]["auth.credentials"]["summary"] = "token expired"
        self.assertFalse(module.first_login_ok(report))

    def test_unknown_schema_fails_closed(self):
        self.assertFalse(module.websocket_ok({"checks": []}))
        self.assertFalse(module.websocket_ok({"result": "HTTP 101"}))
        self.assertFalse(module.websocket_ok(None))


if __name__ == "__main__":
    unittest.main()
