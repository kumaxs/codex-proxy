# Space compatibility investigation

Validated on the live macOS host with ChatGPT 26.928.21956.

## What changed in Space

- Space home, Pages, Sites, Images, recent/library content and template cards are separate UI surfaces.
- “页面使用入门” is not an external help URL. It creates a native Page with `POST /pages`, reads `GET /pages/{page_id}`, then navigates to `/space/{page_id}`.
- Team Space content uses `GET /spaces/{space_id}/pages`; Space creation/sharing also uses `/spaces/v2`.
- The `pages` pub/sub subscription can succeed even while the durable app-server transport is unhealthy, so pub/sub success alone is not a sufficient Space health signal.

## Root cause

The current desktop bundle defines the durable endpoint as:

`wss://codex-cloud-backend.chatgpt.com/`

The app's WebSocket transport only installs its built-in SOCKS proxy for selected internal hostnames; the production `codex-cloud-backend.chatgpt.com` durable endpoint receives no proxy agent. In the affected network this caused repeated WebSocket close 1006 before connection establishment. Space Page creation/opening then remained at “正在打开…”.

The desktop app also provides a supported environment switch:

`CODEX_APP_SERVER_FORCE_CLI=1`

With this enabled, the durable host changes from `transport=websocket` to `transport=stdio`, reports the bundled app-server version, initializes successfully and reaches `state=connected`.

## Final proxy layout

- Chromium/WebView: explicit `--proxy-server=<UPSTREAM_PROXY_URL>` directly to the configured HTTP(S) upstream.
- Durable Space/Page host: `CODEX_APP_SERVER_FORCE_CLI=1` -> bundled CLI/stdio.
- Bundled CLI/app-server network traffic: process-scoped HTTP(S) proxy -> loopback relay -> configured upstream.
- Relay standard TLS/WSS `:443`: passthrough, preserving origin certificates for Rust/CLI WebSocket clients.

The current app may create multiple direct-child Codex app-server processes when the durable CLI fallback is active, so verification accepts one or more and checks each child rather than assuming exactly one.

## Live smoke validation

Passed on the live host:

- Space home loads without an error state.
- “页面使用入门” successfully creates/opens “页面使用指南”; it no longer remains stuck at “正在打开…”.
- Pages view loads and lists the created guide.
- Sites view loads and shows its empty/create state.
- Images view loads.
- Template cards (待办清单、项目跟踪表、每周更新、反馈跟踪表、更新日志) load and are actionable.
- The durable host reports `transport=stdio`, `initialized=true`, `state=connected`.

Template generation that invokes Codex/Work could not be completed because the account was showing a Codex/Work usage-limit message during validation; that is distinct from proxy reachability.
