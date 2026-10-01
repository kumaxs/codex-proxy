# Space compatibility investigation

Investigated on the live macOS host with ChatGPT 26.928.21956.

## Confirmed behavior

- Space home opens and its file/content list loads.
- The `pages` pub/sub topic subscribes successfully and reconciliation starts.
- The “页面使用入门” flow is not an external help webpage. It creates a native Page, then opens that Page.
- The welcome-page implementation uses `POST /pages`, then reads `GET /pages/{page_id}` and navigates to `/space/{page_id}`.
- Team Space content uses `GET /spaces/{space_id}/pages`; Space creation/sharing also uses `/spaces/v2`.
- Therefore the failure domain is the shared Pages/Space request path, not one guide URL.

## Proxy findings

- Branch checkpoint `d96da9c` adds `NODE_USE_ENV_PROXY=1` so Electron main-process native Pages realtime honors process HTTP(S) proxy variables.
- Chromium/WebView also needs an explicit `--proxy-server`; environment variables alone do not cover that path reliably.
- Candidate design under validation sends Chromium/WebView, Node realtime, and Codex app-server to the same loopback relay.
- The relay tunnels standard TLS/WSS `:443` without local TLS interception, then forwards through the configured upstream.
- Verification now checks the Chromium NetworkService as a child of ChatGPT and requires it to connect to the loopback relay.

This is a checkpoint, not a release: full Space smoke coverage (welcome Page, new Page, templates, Sites and existing Page open) is still required before merge to main.
