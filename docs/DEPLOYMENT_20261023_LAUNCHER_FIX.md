# 2026-10-23 — Codex Proxy click-to-launch repair acceptance

## Root cause

The JXA applet's `run(argv)` argument was assumed to be a JavaScript array. On a normal Finder/LaunchServices launch, the observed value was a plain object with no array entries. `resolveAction()` therefore selected the help branch and displayed `Codex Proxy actions:` instead of launching ChatGPT. A separate launcher issue also showed successful command output in a modal dialog, taking focus away from ChatGPT.

## Fix deployed

- Normalize JXA launch arguments with `Array.isArray(argv) ? argv : []`; an ordinary Finder click now takes the default launch path.
- Keep Standard Additions enabled on the same `Application.currentApplication()` object used by `doShellScript()`.
- Do not show launcher stdout as a modal success dialog on the normal click path; activate ChatGPT after the launch flow completes or the user cancels a restart.
- Keep strict proxy preflight, process/environment checks, and `--verify-current`; no verification was bypassed.

## Acceptance

- Built the app bundle from the committed source, verified its code signature and bundle identifier, then deployed it to `~/Applications/Codex Proxy.app`.
- Reopened the installed app from its normal app-bundle path. The `Codex Proxy actions:` help dialog did not appear; with ChatGPT already running, the expected restart confirmation appeared. Canceling the restart left ChatGPT running and brought ChatGPT to the foreground.
- `launch-codex-proxied.sh --verify-current` passed for ChatGPT build 21421 and reported the native Chromium Page WebSocket call site fingerprint verified. This verifies proxy process paths; it does not claim separate Page-editing acceptance.
- Focused config, build, launcher, relay, static scan, template and log-rotation tests passed; `git diff --check` passed.
- The user subsequently confirmed: “好,可以用了,确认修复”. The click-to-launch repair is accepted.

## Source revisions

- `83661aa` — treat unknown applet arguments as launch
- `81b870b` — normalize JXA applet launch arguments
- `9b125dd` — restore ChatGPT focus after launcher confirmation
- `f4ef2f4` — launch ChatGPT without a success popup

The final source revision was pushed to `kumaxs/codex-proxy` `main` and read back from GitHub. The official ChatGPT application bundle, system proxy settings, and system CA trust store were not modified.
