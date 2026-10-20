# 2026-10-20 — ChatGPT desktop 26.1013.40934 production acceptance

## Scoped deployment

- Official application: ChatGPT 26.1013.40934, bundle build 20770, unchanged and validly signed.
- Active installer entry: `$HOME/Applications/Codex Proxy.app` (project's own signed launcher).
- Active runtime: `$HOME/Library/Application Support/Codex Proxy`.
- Chromium/WebView upstream: existing local HTTP proxy `127.0.0.1:29758`.
- Bundled Codex app-server: `127.0.0.1:29760` via `io.github.kumaxs.codex-proxy-relay`, then the same upstream.
- TLS 443: `--ignore-hosts '.*:443$'`, preserving origin certificates and macOS system CA. No system-wide CA, network proxy, or official application modifications.
- Legacy service on port 29759 was retired after proving that it had no established client sockets. Its runtime/config and the pre-migration rollback checkpoint are retained under the prior runtime's backups.

## Confirmed checks

1. Origin-TLS relay returned valid, system-verified responses for ChatGPT backend, WebSocket and image-file hosts; the old MITM relay required its private CA.
2. Updated Codex `doctor --json` and all three WebSocket-surface probes passed through the active relay. The 2026-10-20 test run passed 19 Python assertions and all nine project test suites.
3. `--verify-current` confirmed actual main process build marker, Chromium upstream, Codex child proxy environments and socket policy; the build's native Page WebSocket asset fingerprint matched.
4. Opened an existing ChatGPT conversation and saw its history. Three back/forward cycles opened both the existing conversation and a new test conversation by title.
5. Pasted a generated PNG into the new test conversation, sent it, and received an image-aware model answer that accurately described its colored gradient. This validates a real authenticated image upload, not just HTTP connectivity.
6. Opening the installed Codex Proxy app with the already running ChatGPT app did not create a duplicate main process. The old listener remained stopped, while the new listener remained healthy.
7. GitHub main was read back after both compatibility and startup-check commits; local main was clean and matched origin/main.

## Boundaries and installation lesson

- An authenticated Space/Page *document* was not opened in this acceptance. The asset fingerprint and process checks establish transport compatibility, not end-to-end Page editing.
- An idle WebSocket with no heartbeat is not guaranteed to survive the upstream's idle limits; synthetic heartbeat and upload results do not prove arbitrarily long real ChatGPT tasks.
- The installer currently has a `--start` sequencing defect: its transaction lock blocks the newly bootstrapped relay. Production installation therefore used `--no-start`, followed by `bin/start-relay.sh --config ...` after the transaction had completed. This two-step procedure passed. Do not interpret that acceptance as validation of `install.sh --start`.
