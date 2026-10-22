# CodexProxy deployment and acceptance — 2026-10-22

## Target

- Host: Hermes-1.local (macOS)
- ChatGPT app: 26.1016.61520, CFBundleVersion=21421
- Repository: kumaxs/codex-proxy
- Deployed main commit: f04befb
- Runtime: ~/Library/Application Support/Codex Proxy
- Upstream proxy: existing configured endpoint at 127.0.0.1:29758
- Relay: 127.0.0.1:29760

The official ChatGPT application bundle was not modified or re-signed. The existing upstream URL, relay port, TLS passthrough setting, and mitmdump environment were retained.

## Changes

- Added an exact native Page WebSocket asset fingerprint for ChatGPT build 21421, retaining build 20770 support. The new asset is webview/assets/app-initial-c95ddb62696e.js, SHA-256 6f063d287dbd012293d866f6578bc2703ab11d75b53a00273c45e36df32ce75c.
- Unknown builds remain fail-closed for Page-specific adaptation; no legacy Node WebSocket adapter is injected into the native Chromium transport.
- Corrected the test source inventory to use Git's tracked/untracked-but-not-ignored file list, so local ignored runtime evidence cannot fail the static scan.
- Updated compatibility and troubleshooting documentation.

## Deployment record

1. Fetched and fast-forwarded the local repository to the latest GitHub main before changes.
2. Ran the installer's dry-run using the existing runtime configuration.
3. The installer correctly refused to overwrite an already-loaded relay job. After confirming ChatGPT was closed, the matching relay LaunchAgent was unloaded, the updated runtime was installed with --no-start, and the relay was started using the repository's guarded start-relay.sh path.
4. The relay returned healthy at 127.0.0.1:29760.
5. Full proxy health checks passed. Unauthenticated probes reached the expected HTTP/WebSocket surfaces (403, 404, and 400); these are reachability probes, not authenticated feature acceptance.
6. SHA-256 parity between repository and installed runtime passed for launch-codex-proxied.sh, pages-realtime-proxy.py, proxy-health.sh, and start-relay.sh.
7. Strict preflight passed and reported: native Chromium Page WebSocket call site verified for build 21421.
8. Launched ChatGPT through the proxy launcher. The ChatGPT main process and stable app-server processes were verified with the expected proxy environment. One startup sample emitted a transient app-server PID identity warning; the subsequent stable --verify-current check passed and showed the main process and two app-server processes with env-ok.

## Acceptance results

| Check | Result | Evidence |
|---|---|---|
| Repository test suite | PASS | tests/run.sh --suite all: 9 suites passed, 0 failed |
| Page helper focused tests | PASS | python3 -m unittest discover -s tests -p 'test_pages_proxy.py' -v: 13 tests passed |
| Strict preflight | PASS | Build 21421 asset fingerprint and launcher preflight accepted |
| Relay and upstream listeners | PASS | Both configured loopback listeners remained active |
| Codex app-server initialization | PASS | initialize_handshake_result ... outcome=success transportKind=stdio and Codex CLI initialized |
| Real ordinary chat | PASS | Sent CodexProxy Chat transport test. Reply with exactly: OK.; app returned OK |
| Real image upload and visual understanding | PASS | Uploaded a generated 96×64 gradient image; app returned IMAGE_OK after being asked to inspect it |
| Existing conversation load | RECOVERED | An initial conversation fetch returned HTTP 429 (Too many requests); the conversation subsequently rendered after retry. Treat this as a transient upstream/API response, not proof of a proxy transport defect |
| Space open on build 21421 | PASS (user-confirmed) | After deployment, the user independently confirmed that Space opens successfully in the updated ChatGPT app. Individual Page editing was not separately reported as tested |

## Current conclusion

The updated runtime is deployed, the relay is healthy, ordinary chat works, image upload plus model access to the uploaded image work, and the user independently confirmed that Space opens successfully on ChatGPT build 21421. Repository tests and the stable launcher environment checks pass.

The Space-open acceptance item is closed based on the user's real-app verification. Individual Page editing was not separately reported as tested. A transient HTTP 429 was observed during an earlier conversation fetch and recovered on retry; if it recurs, distinguish the upstream rate-limit response from proxy transport failures.
