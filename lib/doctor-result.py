#!/usr/bin/env python3
"""Validate current Codex doctor WebSocket results without logging doctor JSON."""
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


def main():
    if len(sys.argv) != 2:
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            report = json.load(stream)
        return 0 if websocket_ok(report) else 1
    except (OSError, ValueError, TypeError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
