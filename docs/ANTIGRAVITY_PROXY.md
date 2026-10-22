# Antigravity through Codex Proxy

Antigravity is an Electron application with browser traffic and separate Node-based background services. Launch it using **Antigravity Proxy.app** or **bin/launch-antigravity-proxied.sh**; opening the original Antigravity icon does not inherit this process-scoped setup.

## Routing

- Chromium/Electron browser traffic uses the configured upstream proxy directly with **--proxy-server** (currently **127.0.0.1:29758**).
- Node-based background clients inherit **HTTP_PROXY**/**HTTPS_PROXY** pointing at the existing Codex Proxy relay (currently **127.0.0.1:29760**) and **NODE_USE_ENV_PROXY=1**. Antigravity bundles Node 24, which supports this setting.
- **NODE_EXTRA_CA_CERTS**, **SSL_CERT_FILE**, and **CODEX_CA_CERTIFICATE** use the existing Codex Proxy effective trust bundle. **NO_PROXY** is limited to loopback addresses.
- The launcher clears unrelated global proxy variables, checks that both existing services are listening, and refuses to launch if Antigravity is already running. It does not modify the original app bundle, macOS system proxy, system trust store, or install a new daemon.

## Launch and status

Launch from Finder/Dock using **~/Applications/Antigravity Proxy.app**, or run:

    /bin/zsh "$HOME/Library/Application Support/Codex Proxy/bin/launch-antigravity-proxied.sh"

Check prerequisites and app state:

    /bin/zsh "$HOME/Library/Application Support/Codex Proxy/bin/launch-antigravity-proxied.sh" --status

Quit Antigravity completely before relaunching. Do not use the original Dock/Finder icon for proxied sessions. Launcher logs are stored at **~/Library/Application Support/Codex Proxy/antigravity-launcher.log**.

## Build and update

The installer copies all files from the repository's `bin/` directory into the existing runtime. For an isolated launcher update without reinstalling or restarting the relay, copy the launcher into the runtime and rebuild the Finder app:

    cp -p bin/launch-antigravity-proxied.sh "$HOME/Library/Application Support/Codex Proxy/bin/launch-antigravity-proxied.sh"
    chmod 700 "$HOME/Library/Application Support/Codex Proxy/bin/launch-antigravity-proxied.sh"
    /bin/zsh scripts/build-antigravity-app.sh --replace

The builder creates the app in `~/Applications`, uses the locally installed Antigravity icon, verifies the JXA launcher reference and ad-hoc signature, and restores the previous app bundle if replacement fails.

## Verified on 2026-10-23

- Antigravity 2.25.0 launched successfully from the new Finder app. Its main process included `--proxy-server=http://127.0.0.1:29758` and the expected `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:29760` plus `NODE_USE_ENV_PROXY=1` environment.
- A live socket snapshot showed Electron's NetworkService connected to port 29758 and the Language Server connected to port 29760. At that snapshot there were 1 app connection to the upstream, 7 to the relay, 0 direct external TCP connections on port 443, and 0 externally connected UDP sockets.
- Antigravity's bundled Node 24.21.0 successfully fetched the Google Generative Language API root through the relay and received HTTP 404 with successful TLS. That verifies transport only; a bare API root is not a valid API operation.
- The application launch and proxy path are verified. A signed-in real Agent prompt/response was not automated in this session and remains the final functional check.

## Acceptance boundary

The launcher checks the two listeners and verifies the main process carries the Chromium proxy argument and background Node proxy environment. These checks do not prove that every future Antigravity component honors proxy settings. After sign-in, run a real Agent request and inspect the process sockets/logs to confirm the request uses the relay rather than a direct external connection. A bare Google API root returning HTTP 404 is a transport check, not proof that an API operation succeeded.
