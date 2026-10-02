# Space compatibility investigation

**2026-10-03 correction:** the earlier HTTP/checkpoint recovery was not end-to-end Page acceptance. See [the Page realtime repair](PAGES_REALTIME_FIX_20261003.md) for the separately confirmed Node WebSocket proxy failure and working document test.

Validated on the live macOS host with ChatGPT 26.928.21956. Re-investigated after the 26.928.31416 desktop update and revalidated on 26.930.21537.

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

## ChatGPT 26.928.31416 Page checkpoint regression

After the desktop app updated to 26.928.31416, Space itself still loaded through the proxy but Pages could remain on “正在加载页面…” and “页面使用指南” could show “无法连接到 ChatGPT / 无法打开此页面”.

This was distinct from the durable-transport failure above. With the same proxy layout and a healthy CLI/stdio app-server:

- the Page metadata request with `include_checkpoint=true&include_checkpoint_cdn=true&prefer_lite_checkpoint=true` returned HTTP 200;
- the desktop client rejected the returned `metadata.checkpoint` locally with checkpoint trace `reason=schema`;
- the ordinary non-checkpoint Page request was also reachable.

The evidence points to a client/backend checkpoint-schema rollout mismatch in 26.928.31416, not a Codex Proxy routing failure. Do not mutate or re-sign `ChatGPT.app` to work around this class of version-specific client regression.

## Checkpoint-only recovery on ChatGPT 26.930.21537 (not full Page acceptance)

The same Page was revalidated after the app auto-updated to 26.930.21537, using the normal production proxy path (`Chromium -> 29758`, CLI/app-server -> `29759 -> 29758`). The previous checkpoint-schema failure no longer reproduced:

- `GET /pages/{page_id}` with checkpoint flags returned HTTP 200;
- the response no longer contained the incompatible `metadata.checkpoint`;
- `POST /pages/{page_id}/realtime-token` returned HTTP 200;
- access requests, automation attachments and shares returned HTTP 200;
- the fallback `GET /pages/{page_id}?include_document_bootstrap=true&include_checkpoint=false` returned HTTP 200;
- the app log showed the `/space/{page_id}` route without `Space Page load timed out`, `invalid_page`, or Page realtime errors.

No additional route patch was needed for the checkpoint response itself, but the separate Page realtime transport still required repair. A full app quit/relaunch is required after an in-place ChatGPT update: the bundle version on disk can advance while the already-running process still has the previous frontend bundle loaded. The launcher now stamps the installed `CFBundleVersion` into `CODEX_PROXY_APP_BUILD` at launch and `--verify-current` rejects a running process whose marker is missing or differs from the installed build. Do not infer the running client version from `Info.plist` alone.

If the proxy verification passes but a future desktop version shows a similar Page-only failure, first distinguish an HTTP/WSS reachability failure from a client-side Page schema/rollout failure before changing proxy topology.
