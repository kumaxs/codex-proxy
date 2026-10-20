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

    def test_unknown_schema_fails_closed(self):
        self.assertFalse(module.websocket_ok({"checks": []}))
        self.assertFalse(module.websocket_ok({"result": "HTTP 101"}))
        self.assertFalse(module.websocket_ok(None))


if __name__ == "__main__":
    unittest.main()
