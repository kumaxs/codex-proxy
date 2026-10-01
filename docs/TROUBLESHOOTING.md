# 故障排查

English summary: Troubleshoot the upstream, loopback relay, process-scoped environment, CA file, and WebSocket probes separately. Use only the repository scripts listed below.

先定义默认 runtime：

```bash
RUNTIME="$HOME/Library/Application Support/Codex Proxy"
CONFIG="$RUNTIME/config/codex-proxy.conf"
```

## 1. 安装器拒绝参数

安装必须同时提供 `--upstream-url` 和 `--mitmdump`：

```bash
/bin/zsh scripts/install.sh \
  --upstream-url 'http://proxy.example:3128' \
  --mitmdump '/absolute/path/to/mitmdump' \
  --dry-run
```

检查以下项目：

- upstream 只能是 `http://` 或 `https://`，不能有 `user:password@`、路径、查询字符串或片段；
- `--mitmdump` 必须是绝对路径、可执行文件，且其路径链不能是不安全 symlink；
- `--chatgpt-app-path` 必须指向 `.../Contents/MacOS/ChatGPT`；bundled Codex 支持新版 `Contents/Resources/codex-cli/bin/codex`，并兼容旧版 `Contents/Resources/codex`；
- `--listen-host` 只能是 loopback；端口必须为 1–65535；
- `--passthrough` 必须是有效的扩展正则。

安装默认是 `--no-start`。如果 dry-run 通过后要在安装阶段 bootstrap relay，才加 `--start`；否则安装结束后执行 `bin/start-relay.sh`。

## 2. relay 无法启动

```bash
bin/start-relay.sh --config "$CONFIG"
```

该脚本会检查 upstream host/port、LaunchAgent plist、唯一监听 PID，并执行 HTTP-only health。失败时检查：

```bash
/usr/bin/nc -z <upstream-host> <upstream-port>
/usr/bin/nc -z 127.0.0.1 29759
tail -n 80 "$RUNTIME/relay.log"
```

如果你在安装时使用了非默认端口或 host，以 `config/codex-proxy.conf` 为准，不要把 `29759` 硬编码到后续探针中。`start-relay.sh` 会拒绝不属于本项目精确 label/PID 的 listener；对已加载且身份匹配的 relay job 会受控 kickstart，以确保配置修改生效。它不会启动 ChatGPT。

## 3. 健康检查失败

先执行轻量探针：

```bash
bin/proxy-health.sh --config "$CONFIG" --http-only
```

再执行完整探针：

```bash
bin/proxy-health.sh --config "$CONFIG" --full
```

`--full` 包括 bundled Codex `doctor --json --no-color` 和 `ws.chatgpt.com`、`chatgpt.com`、Remote-control endpoint 的 WebSocket upgrade 检查。HTTP 401/403/404 的未认证 WebSocket surface 仍可被分类为“已到达”；这不是业务登录成功。

另外可以运行网络审计：

```bash
bin/openai-network-audit.sh --config "$CONFIG"
bin/openai-network-audit.sh --config "$CONFIG" --codex-doctor
```

审计脚本不会修改系统网络设置。没有可读 config 时，必须显式给 `--proxy-url`，并选择 `--ca-file <绝对路径>` 或 `--system-ca`；不要把凭据放进 proxy URL。

## 4. TLS 证书错误

relay CA 通常在：

```text
$RUNTIME/mitmproxy/mitmproxy-ca-cert.pem
```

确认文件可读、runtime 目录不是 symlink，并重新执行：

```bash
bin/proxy-health.sh --config "$CONFIG" --http-only
bin/launch-codex-proxied.sh --config "$CONFIG" --preflight
```

launcher 会为 ChatGPT 主进程设置 `CODEX_CA_CERTIFICATE`、`SSL_CERT_FILE`、`NODE_EXTRA_CA_CERTS` 和 `NODE_USE_ENV_PROXY=1`，同时设置 HTTP(S) proxy，并移除 `ALL_PROXY`、SOCKS/WS/FTP 及常见 Git/npm 代理覆盖变量。当前桌面端生成的 Codex app-server 可能不保留 `NODE_EXTRA_CA_CERTS`；只要 `CODEX_CA_CERTIFICATE`、`SSL_CERT_FILE` 与 HTTP(S) proxy 正确且 socket 仍指向 relay，这不再判为故障。项目不会把该 CA 安装到系统钥匙串或系统信任库；不要通过修改系统 CA 来“修复”此错误。

## 5. Space / Pages 页面打不开

新版 Space/Pages 的正文实时连接由 Electron 主进程中的 Node WebSocket 发起，不属于 Codex app-server socket，也不会自动采用 Chromium 的系统代理。launcher 因此显式设置 `NODE_USE_ENV_PROXY=1`，让该 Node WebSocket 通过已有 `HTTP_PROXY`/`HTTPS_PROXY` 进入 relay。

先检查：

```bash
bin/launch-codex-proxied.sh --config "$CONFIG" --verify-current
```

运行中的 ChatGPT 主进程必须同时具有 `NODE_USE_ENV_PROXY=1` 与预期 HTTP(S) proxy。不要为此修改官方 `ChatGPT.app`、重签名应用或扩大系统 CA 信任。

## 6. Responses 出现 `retry 5/5` 或 WebSocket 断开

先确认 relay、upstream 和进程 socket 都经过同一配置：

```bash
bin/launch-codex-proxied.sh --config "$CONFIG" --status
bin/proxy-health.sh --config "$CONFIG" --full
bin/launch-codex-proxied.sh --config "$CONFIG" --verify-current
```

仓库中 `5/5` 观察只针对某一类 Responses WebSocket 重试问题。即使完整探针通过，也不能保证 Remote、图片或其他 Responses 模式；不要把这个计数解释成全局修复承诺。启动器在验证失败时不会主动另行普通启动，但 GUI/Chromium 等子进程是否遵守环境变量仍需业务验证。

## 7. Remote 离线、图片失败或业务结果不一致

Remote 和图片必须由真实业务操作验证，例如在目标工作区中实际建立 Remote 连接、发送一条业务消息并上传/加载一张图片。脚本的 HTTP/WebSocket 探针只能证明 transport surface 到达，不能证明账号、工作区、权限、图片处理或服务端状态。

请同时检查：

- 官方 Remote 要求中的 awake/online、账号和工作区条件：[Remote connections](https://learn.chatgpt.com/docs/remote-connections)；
- upstream ACL、DNS、TLS 和目标服务返回码；
- `PASSTHROUGH_REGEX` 是否误匹配了需要 TLS interception 的主机。

项目不保证 Remote 或图片功能；请把业务实测结果、时间、账号环境和 relay 日志分开记录，日志中不要包含 token、Cookie 或请求体。

## 8. `PASSTHROUGH_REGEX` 看起来没有生效

该值不是逗号分隔的域名白名单。`bin/relay.sh` 在非空时原样传入：

```text
--ignore-hosts <PASSTHROUGH_REGEX>
```

这是 mitmproxy 的 ignore-hosts 主机正则语义：匹配后跳过 TLS interception，但不触发 launcher 的 ChatGPT 直连回退；匹配后的具体转发方式由当前 mitmproxy mode 决定。空值则不传参数。修改 config 后，重新运行 `bin/start-relay.sh --config "$CONFIG"`；它会对身份匹配的已加载 job 受控 kickstart，然后再检查 `$RUNTIME/relay.log`。

## 9. 查看进程状态或启动 ChatGPT

```bash
bin/launch-codex-proxied.sh --config "$CONFIG" --preflight
bin/launch-codex-proxied.sh --config "$CONFIG" --launch-and-verify
bin/launch-codex-proxied.sh --config "$CONFIG" --status
bin/launch-codex-proxied.sh --config "$CONFIG" --verify-current
```

这些动作只作用于匹配的 ChatGPT/Codex 进程。`--launch-and-verify` 会拒绝并发残留进程、检查 ChatGPT 主进程与 Codex app-server 的精确环境和 relay socket；它不会在失败后主动另行普通启动，也不会由 ChatGPT 自己自动重启 relay。GUI/Chromium 子进程可能有不同的环境继承行为，必须做业务验证。

## 10. relay LaunchAgent 的 KeepAlive

relay plist 是 `io.github.kumaxs.codex-proxy-relay`，安装器生成的 plist 具有 `RunAtLoad` 和 `KeepAlive=true`。这表示 relay job 可以在退出后由 launchd 重新拉起；它不表示 ChatGPT/Codex 受到同样的监控。

安装后如果只想检查而不启动 ChatGPT，使用 `bin/start-relay.sh` 和 `bin/proxy-health.sh`；请不要照抄未在本仓库列出的旧命令。

## 11. Dock 仍显示旧图标

构建脚本会嵌入 `CodexProxy.icns`，移除默认 applet 图标资源，并让 `Info.plist` 只引用项目图标。若安装后的 Dock 仍显示旧图标，先确认运行中的旧 `Codex Proxy.app` 已退出，再把旧 Dock 项移除，并从 `~/Applications/Codex Proxy.app` 重新拖入 Dock。macOS 的 Dock/LaunchServices 图标缓存可能晚于 bundle 替换刷新；不要通过改动官方 `ChatGPT.app` 图标来处理。

## 12. 安装或启动锁残留

安装、卸载和 launcher 会使用当前 UID 专属的锁目录：

```text
/private/tmp/com.github.kumaxs.codex-proxy-install-<UID>.lock
/private/tmp/com.github.kumaxs.codex-proxy-launch-<UID>.lock
```

install lock 会故意对陈旧或无法验证的 owner fail-closed；不要看到报错就直接递归删除。先读取 `owner-pid`，再用 `ps -p <PID> -o pid=,uid=,command=` 确认该 PID 已不存在，并核对锁目录由当前用户拥有、不是 symlink、只含 `owner-pid`。只有全部成立时，才删除精确的 `owner-pid` 文件并用 `rmdir` 删除这个空锁目录。launcher 可以自行清理一个由当前用户拥有且能明确判定 owner PID 已消失的标准 launch lock；其他异常仍会拒绝继续。

如果 install lock 与 `/private/tmp/codex-proxy-install.*` 恢复目录同时存在，先保留恢复目录并检查安装目标，不要清锁后直接重装。无法确认时，请连同脱敏后的错误信息提交安全报告。

## 13. 卸载与现场清理

默认卸载：

```bash
/bin/zsh scripts/uninstall.sh --home "$RUNTIME"
```

它会先 bootout relay，再删除 runtime 的脚本/库/manifest、应用和 plist，保留 runtime 根目录的 `RUNTIME.md` 以及 `config/`、`mitmproxy/`、`launcher.log`、`relay.log`。要连同这些持久文件一并删除，必须明确确认：

```bash
/bin/zsh scripts/uninstall.sh --home "$RUNTIME" --purge-runtime --yes
```

如果卸载失败，不要手工 `rm -rf` 未确认的路径；先检查 runtime manifest、symlink 和权限，再保留错误日志供审计。完成后按 [docs/RUNTIME.md](RUNTIME.md) 确认是否还有你主动保留的配置或 CA。
