# Space Page realtime repair — 2026-10-03

## Corrected diagnosis

The earlier checkpoint/HTTP-200 checks did **not** establish that a Page document opened. The reported resolution on 26.930.21537 was incomplete. Space metadata, the durable CLI host and the Page document's realtime socket are different paths.

On ChatGPT 26.930.21537 (build 12776), the Page host's Node WebSocket does not use the existing Chromium/CLI proxy configuration. A separate test using the same authorized Page connection through the HTTP upstream established a WebSocket connection and delivered the document. Forcing the browser transport instead returned 404 with its browser Origin; that is not the delivered fix.

The official bundle disables Node-options and main-process inspector support. The previously attempted Node preload/environment switches were ineffective and have been removed from the deployed launcher. The official application bundle, its fuses/signature, system proxy and system certificate store remain unchanged.

## Implemented transport

`bin/pages-realtime-proxy.py` supplies a process-scoped Page transport adapter through renderer CDP. It forwards only the supported official Page realtime endpoints through the configured HTTP upstream, with origin TLS certificate verification enabled. Tokens and document frames stay in memory; logs contain only connection/error counts and types.

Normal launcher starts use **a private CDP pipe**, not a debug TCP listener. The helper exits with that ChatGPT process, attaches to relevant new renderer windows and reinstalls the adapter after renderer navigation. It does not supervise or restart ChatGPT. HTTP metadata, ordinary chats and CLI traffic retain their existing paths.

The adapter is deliberately restricted to the validated build and renderer call site. After an unsupported application update, the launcher retains the ordinary Chromium/CLI proxy, warns that Pages are unverified, and does not inject at an unknown location.

The helper uses `python3` beside the configured `mitmdump` executable. Install `requirements.txt` into that same environment; it now includes `websocket-client==1.9.0`.

## Verification so far

- Temporary end-to-end test: upstream WebSocket 101, real Page document editor containing 834 characters, repeated observations without the two reported error states.
- Companion test: the existing guide reopened successfully, including a subsequent opening in about one second; the real Page editor remained populated during an additional 45-second observation. The first transition out of the old temporary adapter did not complete within 35 seconds, so it is not counted as a successful trial.
- Private-pipe lifecycle test: a separate empty-profile ChatGPT instance acquired its renderer adapter; closing only that test instance stopped its helper. The user's existing application stayed running.
- Nine focused Python tests cover endpoint restrictions, authenticated URL construction, TLS policy, cancellation, retry after failure and sanitized errors.
- Existing launcher process/environment/socket fixture suite passed.

## Deployment and remaining acceptance

The legacy live runtime is `~/.codex/proxy`, whereas fresh repository installs use `~/Library/Application Support/Codex Proxy`. Do not copy the configuration-driven repository launcher over a legacy launcher without adapting its paths. The same Page helper is used by both layouts.

Hot deployment attaches to the already-running app's existing loopback debug session so the current conversation is not terminated. That old listener disappears only after a normal full app exit. Subsequent launches use the private pipe.

The authenticated account's complete quit/relaunch acceptance remains separate from the empty-profile pipe test. Do not claim that this user-controlled restart has occurred until it actually has. Likewise, the retry unit test does not establish recovery from every real network interruption.

Rollback: restore the backed-up legacy launcher and stop only the matching Page helper; the existing relay and official app are not replaced. A normal app restart discards all renderer-side adapter state.

Focused tests: `python3 -m unittest discover -s tests -p 'test_pages_proxy.py' -v`.
