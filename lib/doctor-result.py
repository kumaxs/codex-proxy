#!/usr/bin/env python3
"""Validate Codex doctor WebSocket checks without logging sensitive doctor JSON."""
import json
import sys


def websocket_ok(report):
    if not isinstance(report, dict):
        return False
    checks = report.get("checks")
    if not isinstance(checks, dict):
        return False
    websocket = checks.get("network.websocket_reachability")
    if not isinstance(websocket, dict) or websocket.get("status") != "ok":
        return False
    return report.get("overallStatus") not in ("failed", "error")


def _first_login_provider_ok(checks):
    """Optional desktop CDN timeouts must not block an otherwise reachable login."""
    provider = checks.get("network.provider_reachability")
    if not isinstance(provider, dict):
        return False
    if provider.get("status") == "ok":
        return True
    if (provider.get("status") != "warning"
            or provider.get("summary") != "desktop update and runtime CDN is unreachable"):
        return False
    details = provider.get("details")
    if not isinstance(details, dict):
        return False
    inference = details.get("ChatGPT inference URL")
    cdn = details.get("desktop assets CDN")
    return (isinstance(inference, str) and " reachable (HTTP " in inference
            and isinstance(cdn, str) and cdn.endswith(" request timed out (optional)"))


def first_login_ok(report):
    """Allow only a missing-credential 401 with reachable inference and no hard failures."""
    if not isinstance(report, dict) or report.get("overallStatus") != "fail":
        return False
    checks = report.get("checks")
    if not isinstance(checks, dict):
        return False
    auth = checks.get("auth.credentials")
    ws = checks.get("network.websocket_reachability")
    if not isinstance(auth, dict) or not isinstance(ws, dict):
        return False
    details = ws.get("details")
    if not isinstance(details, dict):
        return False
    failure = details.get("handshake transport error")
    if not isinstance(failure, str):
        return False
    return (
        auth.get("status") == "fail"
        and auth.get("summary") == "no Codex credentials were found"
        and ws.get("status") == "warning"
        and details.get("auth mode") == "none"
        and "http 401 Unauthorized" in failure
        and "Missing bearer or basic authentication" in failure
        and _first_login_provider_ok(checks)
        and checks.get("network.env", {}).get("status") == "ok"
        and all(
            isinstance(v, dict) and v.get("status") not in ("fail", "failed", "error")
            for key, v in checks.items() if key != "auth.credentials"
        )
    )


def main():
    if len(sys.argv) == 2:
        mode, path = "normal", sys.argv[1]
    elif len(sys.argv) == 3 and sys.argv[1] == "--allow-first-login":
        mode, path = "first_login", sys.argv[2]
    else:
        return 2
    try:
        with open(path, encoding="utf-8") as stream:
            report = json.load(stream)
        valid = first_login_ok(report) if mode == "first_login" else websocket_ok(report)
        return 0 if valid else 1
    except (OSError, ValueError, TypeError, AttributeError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
