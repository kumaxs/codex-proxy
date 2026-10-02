# Runtime 文件与生命周期

English summary: Installation creates a user-scoped runtime, a local relay LaunchAgent plist, and a launcher app. Default uninstall removes executable runtime pieces but retains config, mitmproxy state, and logs; `--purge-runtime --yes` is the explicit destructive option.

## 默认路径

动态 launcher 要求安装使用 HOME 派生的固定 runtime 根目录：

```text
~/Library/Application Support/Codex Proxy/
```

应用和 LaunchAgent plist 默认分别为：

```text
~/Applications/Codex Proxy.app
~/Library/LaunchAgents/io.github.kumaxs.codex-proxy-relay.plist
```

安装器传入其他 `--home` 会被拒绝；卸载器的 `--home` 也只用于精确指定当前用户 HOME 所对应的既有 runtime，manifest 中的应用和 plist 仍必须匹配当前用户默认位置。相关操作会拒绝 root、危险 symlink 或不安全的 owner/mode 路径。

安装、重装或卸载前必须先退出 ChatGPT/Codex 与 `Codex Proxy.app`。脚本会在生命周期变更前后检查相关 bundle 进程；发现仍在运行时只会拒绝操作，不会替用户发送 TERM。

## 安装产生的内容

`/bin/zsh scripts/install.sh --upstream-url <URL> --mitmdump <PATH>` 会：

1. 校验无凭据的 HTTP(S) upstream、loopback 监听、ChatGPT/Codex 路径和 mitmdump 可执行文件；
2. 在 runtime 下复制 `bin/`、`lib/` 和配置模板；
3. 写入 `config/codex-proxy.conf`，包含 `UPSTREAM_PROXY_URL`、`LISTEN_HOST`、`LISTEN_PORT`、`MITMDUMP_PATH`、`CHATGPT_APP_PATH`、`PASSTHROUGH_REGEX`；
4. 构建 `Codex Proxy.app` 并安装图标；
5. 写入 relay plist 和 `.codex-proxy-manifest`；
6. 把本说明复制为 runtime 根目录的 `RUNTIME.md`，让默认卸载后仍有现场说明；
7. 默认保持 launchd 不变（`--no-start`）。只有传入 `--start` 才会在安装事务中 bootstrap 新 job。

relay 第一次启动时会在 `mitmproxy/` 下创建或使用 mitmproxy CA 状态，通常包括：

```text
mitmproxy/mitmproxy-ca-cert.pem
```

该 CA 能让 launcher 为本次 ChatGPT/Codex 进程验证 relay 重签发的 TLS；它不会被写入系统钥匙串或系统 CA store。relay 进程能看到经过 interception 的解密明文，请把整个目录当作敏感数据。

## 运行时文件

| 路径 | 作用 | 敏感性 |
| --- | --- | --- |
| `config/codex-proxy.conf` | relay/upstream 和 ChatGPT 路径配置 | 可能暴露内部主机、目录和策略；不得写凭据 |
| `bin/` | relay、launcher、health、audit 等已安装脚本 | 可执行代码 |
| `lib/` | 配置解析库 | 与 `bin/` 一起由安装器管理 |
| `mitmproxy/` | CA、mitmproxy 运行状态 | 高敏感；不要共享 CA |
| `relay.log` | LaunchAgent 标准输出/错误 | 可能包含错误上下文和主机信息 |
| `launcher.log`、`launcher.log.1`… | launcher 输出和轮转日志 | 可能包含进程/错误信息 |
| `RUNTIME.md` | 安装时复制的生命周期、保留和清理说明 | 可公开阅读，不应写入秘密 |
| `.codex-proxy-manifest` | 卸载器校验安装目标 | 用于生命周期管理 |

安装器会尽量使用用户私有权限；不要把 runtime 放到共享目录，不要把日志上传到公开 issue。`PASSTHROUGH_REGEX` 是传给 mitmproxy `--ignore-hosts` 的正则，不是系统级绕过开关。

## LaunchAgent 生命周期

plist label 是 `io.github.kumaxs.codex-proxy-relay`，默认包含 `RunAtLoad=true`、`KeepAlive=true`、后台进程类型和 runtime `relay.log` 路径。

- `--no-start`：安装后 plist 已写入，但不 bootstrap/kickstart；
- `--start`：安装事务完成后 bootstrap 新 job；
- `bin/start-relay.sh --config <CONFIG>`：未加载时 bootstrap；已加载且身份匹配时受控 kickstart，以应用当前配置；未知 listener 会被拒绝。为避免中断活动连接，ChatGPT/Codex 仍运行时不会执行 bootstrap/kickstart。动作后验证唯一 listener、launchd PID 和 HTTP health；
- relay 可由 launchd KeepAlive 拉起；ChatGPT/Codex 不受该 KeepAlive 影响；
- `scripts/uninstall.sh` 会先 bootout relay job，再移除目标文件。

## 进程环境

只有 `bin/launch-codex-proxied.sh --launch-and-verify`（或应用图标触发的同一路径）为 ChatGPT/Codex 设置 loopback HTTP(S) proxy、runtime CA 和 `NO_PROXY=localhost,127.0.0.1,::1`。它会移除 `ALL_PROXY`、SOCKS/WS/FTP 及常见 Git/npm 代理覆盖变量，验证 ChatGPT 主进程与 Codex app-server 的环境并采样已建立的 TCP socket，在验证失败时拒绝主动另行普通启动。该检查不覆盖 UDP/QUIC 或所有 GUI/Chromium helper；图片和 Remote 必须业务实测。

这组环境变量不会持久化为系统代理；退出或不使用 launcher 时，官方 ChatGPT.app 仍按自己的普通启动环境运行。项目不会改写官方应用包。

## 卸载策略

默认卸载：

```bash
RUNTIME="$HOME/Library/Application Support/Codex Proxy"
/bin/zsh scripts/uninstall.sh --home "$RUNTIME"
```

脚本会 bootout relay，然后删除：

- runtime `bin/`；
- runtime `lib/`；
- `.codex-proxy-manifest`；
- `~/Applications/Codex Proxy.app`；
- relay LaunchAgent plist。

默认会保留：

- `RUNTIME.md`（runtime 根目录的现场说明）；
- `config/`（包括配置文件）；
- `mitmproxy/`（包括 CA 和 mitmproxy 状态）；
- `relay.log`、`launcher.log` 及轮转日志。

需要彻底清理 runtime 时，必须显式确认：

```bash
/bin/zsh scripts/uninstall.sh --home "$RUNTIME" --purge-runtime --yes
```

此模式会移除 runtime 根目录及其保留文件，同时移除应用和 plist。`--purge-runtime` 没有 `--yes` 会被拒绝；这是为了避免误删可用于审计和复现的 CA、配置与日志。

## 清理现场

测试和构建产生的临时目录应在任务完成后删除。仓库中的 `.gitignore` 已忽略 runtime、日志、证书和本地配置；如果为了复现必须保留某个文件，请在同一目录写明用途、来源、敏感性和清理方式的 README，并确认其中没有凭据或 CA 私钥。

## Page realtime companion

`bin/pages-realtime-proxy.py` is launched by the proxy launcher with the `python3` beside `MITMDUMP_PATH`; that environment must include the repository requirements. It starts the official app through a private CDP pipe, routes only approved Page realtime sockets through the HTTP upstream, and exits with its app process. `pages-status.json` records process/build identifiers and aggregate connection counts only; `pages-status.json.lock` prevents duplicate companions. No token or document body is written there. Launcher verification distinguishes adapter readiness from actual Page document acceptance. See `PAGES_REALTIME_FIX_20261003.md` in the repository for compatibility and rollback details.
