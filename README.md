# Codex Proxy：macOS 本地中继（非官方）

![Codex Proxy 图标](assets/Codex-Proxy-icon-1024.png)

English summary: Codex Proxy is an unofficial macOS utility. It applies proxy and CA variables only to an explicitly launched ChatGPT/Codex process, sends that process through a loopback mitmproxy relay (default `127.0.0.1:29759`), and then to a user-supplied HTTP(S) upstream proxy. It does not change the system proxy, the official ChatGPT app, or the system CA store.

> 本项目是社区维护的非官方 macOS 工具，不是 OpenAI、ChatGPT 或 Codex 的官方组件。相关名称和商标归各自权利人所有。

## 用途与边界

本项目把**显式启动的** ChatGPT/Codex 进程连接到本机 relay，再连接到用户自己指定的 HTTP(S) upstream。默认只监听回环地址，默认端口是 `29759`。

它不会：

- 修改 macOS 系统代理、网络设置、钥匙串或系统 CA 信任库；
- 修改、注入或替换官方 `ChatGPT.app`；
- 给 ChatGPT 进程安装 `KeepAlive`、自动重启或守护式循环；
- 在 relay/upstream 失败时主动另行启动一次普通直连；launcher 没有 direct-launch fallback，但 GUI/Chromium 等子进程是否遵守环境变量仍需业务验证；
- 代替用户向 upstream 提供凭据。`--upstream-url` 禁止 userinfo、路径、查询字符串和片段。

relay 的 LaunchAgent 可以使用 `KeepAlive=true` 维持 relay 服务；这只适用于 relay 进程，不适用于 ChatGPT/Codex。

## 架构

```mermaid
flowchart LR
  subgraph P[用户显式启动的进程范围]
    L[Codex Proxy.app 或 launch-codex-proxied.sh] --> C[ChatGPT.app + Codex helper]
    C -->|HTTP_PROXY / HTTPS_PROXY<br/>CA 变量；NO_PROXY 仅回环<br/>其他代理变量被移除| R[loopback relay<br/>127.0.0.1:29759]
  end

  subgraph H[本机服务]
    R --> M[mitmdump / mitmproxy<br/>--mode upstream:URL]
    A[LaunchAgent<br/>RunAtLoad + KeepAlive=true] --> R
    M --> F[relay.log / launcher.log<br/>runtime 状态]
  end

  M --> U[用户显式提供的<br/>HTTP(S) upstream]
  U --> T[目标服务]
  C -. launcher 失败路径：不主动普通启动 .-> X[拒绝普通直连 fallback]
  S[系统代理、官方 ChatGPT.app、<br/>系统 CA 信任库] -. 保持不变 .- C
```

relay 监听地址只能是 loopback（`127.0.0.1`、`localhost` 或 `::1`）。默认配置把 `127.0.0.1:29759` 传给 mitmdump；`--listen-host` 和 `--listen-port` 可以在安装时显式调整。

## 支持范围

- 目标平台：macOS。
- 当前验证边界：macOS 26、arm64。
- Intel Mac 和其他 macOS 版本没有当前项目验证保证；升级系统或更换架构后请自行做完整业务验证。
- 仓库当前提供源码和本地构建流程；`build-app.sh` 生成的是 ad-hoc 签名应用，不是 Developer ID 签名或 Apple 公证的发行包。
- Remote 连接和图片上传/加载必须由你的真实业务操作验证，本项目不保证其可用性、账号状态或服务端行为。
- 已观察到的 `5/5` 只针对某一类 Responses WebSocket 重试问题，不能推导为 Remote、图片或所有网络错误都会修复。

## 前置条件

- 可用的 macOS `/bin/zsh`、`launchctl`、`curl`、`nc`、`lsof`、`plutil`、`osacompile`、`osadecompile` 和 `codesign`；
- 已安装且可执行的 `mitmdump`（安装器不会替你下载或安装它）；
- 已安装的官方 ChatGPT.app，且其 `Contents/MacOS/ChatGPT` 与 `Contents/Resources/codex` 可被校验；
- 一个你有权使用的 HTTP 或 HTTPS upstream 代理 URL。

## 安装

安装器要求同时提供 `--upstream-url` 和 `--mitmdump`，两者都没有默认值。URL 只能是无凭据的 HTTP(S) authority，例如 `http://proxy.example:3128`；不要把用户名、密码、token 或其他秘密写进 URL。

安装、重装或卸载前请先退出 ChatGPT/Codex 和 `Codex Proxy.app`。生命周期脚本会检查这些进程并 fail-closed；它们不会替你发送 TERM，也不会在应用仍运行时重启或拆除 relay。

```bash
cd /path/to/codex-proxy
/bin/zsh scripts/install.sh \
  --upstream-url 'http://proxy.example:3128' \
  --mitmdump '/absolute/path/to/mitmdump'
```

默认是 `--no-start`：安装会写入本地 runtime、应用图标和 relay LaunchAgent plist，但不会触碰 launchd 中的现有 job。需要在安装时启动 relay 时才加 `--start`；也可以安装后按下节中的 `start-relay.sh` 显式启动。

常用可选参数：

```text
--listen-host HOST       loopback 主机，默认 127.0.0.1
--listen-port PORT       relay 端口，默认 29759
--chatgpt-app-path PATH  官方 ChatGPT 可执行文件路径
--passthrough REGEX      原样传给 mitmproxy --ignore-hosts
--dry-run                只校验并打印计划，不写入安装目标
```

当前动态 launcher 要求安装使用当前用户 HOME 派生的固定 runtime：`~/Library/Application Support/Codex Proxy`；传入其他 `--home` 会被拒绝。安装成功后，应用默认在 `~/Applications/Codex Proxy.app`。图标用于启动本项目的本地 launcher；它不是官方 ChatGPT 应用图标，也不代表官方背书。

## 常用命令

下面的 `RUNTIME` 和 `CONFIG` 指向默认安装位置。安装使用仓库中的 `scripts/`；安装后的 `bin/` 会被复制到 runtime 中，也可以直接使用仓库中的同名脚本。

```bash
RUNTIME="$HOME/Library/Application Support/Codex Proxy"
CONFIG="$RUNTIME/config/codex-proxy.conf"
```

启动或检查 relay：

```bash
bin/start-relay.sh --config "$CONFIG"
```

`start-relay.sh` 会拒绝未知端口监听者；job 未加载时才 bootstrap，已加载且 plist/label/PID 身份全部匹配时会受控 kickstart，使配置修改确实生效。因为 kickstart 会短暂重启 relay，它在任何 launchd 动作前都会拒绝仍在运行的 ChatGPT/Codex；请先退出应用。完成后它会重新核对唯一监听 PID 和 HTTP 健康状态。

查看当前 upstream、relay 和 ChatGPT/Codex 进程状态：

```bash
bin/launch-codex-proxied.sh --config "$CONFIG" --status
```

健康检查：

```bash
bin/proxy-health.sh --config "$CONFIG" --http-only
bin/proxy-health.sh --config "$CONFIG" --full
```

`--full` 会运行 bundled Codex `doctor --json --no-color` 和若干 HTTP/WebSocket 探针；这不等于 Remote 或图片业务验收。

网络审计：

```bash
bin/openai-network-audit.sh --config "$CONFIG"
bin/openai-network-audit.sh --config "$CONFIG" --codex-doctor
```

显式启动并做 ChatGPT 主进程、Codex app-server 环境和 socket 校验（launcher 不会使用普通直连回退）：

```bash
bin/launch-codex-proxied.sh --config "$CONFIG" --launch-and-verify
```

卸载：

```bash
/bin/zsh scripts/uninstall.sh --home "$RUNTIME"
```

默认卸载会 bootout relay job，移除 runtime 的 `bin/`、`lib/`、安装 manifest、应用和 plist，但保留 runtime 内的 `RUNTIME.md` 以及 `config/`、`mitmproxy/`、`launcher.log` 与 `relay.log`，便于说明、审计和复现。确认要删除整个 runtime 时：

```bash
/bin/zsh scripts/uninstall.sh --home "$RUNTIME" --purge-runtime --yes
```

`--purge-runtime` 必须和 `--yes` 一起使用；它还会删除上述保留文件。卸载的 `--home` 用于精确指定**当前用户 HOME 所对应的已安装 runtime**；manifest 仍会拒绝指向其他 HOME 的应用或 plist。卸载行为和持久文件见 [docs/RUNTIME.md](docs/RUNTIME.md)；安装器也会把这份说明复制为 runtime 根目录的 `RUNTIME.md`。

## 配置与 PASSTHROUGH_REGEX

安装写入的 `config/codex-proxy.conf` 只接受以下键：

| 键 | 含义 |
| --- | --- |
| `UPSTREAM_PROXY_URL` | mitmdump 的 HTTP(S) upstream authority；禁止 userinfo、路径、查询和片段。 |
| `LISTEN_HOST` | relay loopback 绑定地址。 |
| `LISTEN_PORT` | relay 监听端口，默认 `29759`。 |
| `MITMDUMP_PATH` | 已存在且可执行的 mitmdump 绝对路径。 |
| `CHATGPT_APP_PATH` | 官方 ChatGPT `Contents/MacOS/ChatGPT` 绝对路径。 |
| `PASSTHROUGH_REGEX` | 传给 mitmdump `--ignore-hosts` 的扩展正则；空值表示不设置该参数。 |

`PASSTHROUGH_REGEX` 是 mitmproxy 的 **ignore-hosts 精确语义**：脚本把字符串原样作为一个 `--ignore-hosts` 参数传入，匹配的主机跳过 TLS interception；这不是系统代理白名单，也不是 launcher 的直连回退开关。匹配后的具体转发方式由 mitmproxy 当前 mode（本项目默认是 upstream mode）决定。默认安装值只匹配 `localhost`、`127.0.0.1` 和 `::1`；如需其他主机，必须显式传入正则。具体匹配细节以所用 mitmproxy 版本为准。

## MITM 安全边界与隐私

relay 使用 mitmproxy 的本地 CA 来解密和重新签发 HTTPS 流量，因此 relay 进程及其运行目录对**经过拦截的明文**具有可见性；这包括可能的会话内容、Remote 控制流量或图片请求元数据。请只在你有权审计的设备和网络中运行，不要把 runtime CA 发给他人。

launcher 会验证 ChatGPT 主进程和 Codex app-server 的环境，并多轮采样它们已建立的 TCP socket；它不覆盖 UDP/QUIC，也不能穷尽所有 GUI/Chromium helper 的网络活动。部分 GUI 或 Chromium 栈可能不继承或不遵守同一进程环境，所以 Remote、图片和其他业务链路不能由这项检查推断，必须做真实业务实测。

如果进程已经启动、但 postflight 随后失败，launcher 会返回非零并明确提示“状态未验证”；为避免再次出现自动终止/重启循环，它不会擅自发送 TERM。此时应用可能仍在运行，必须由用户手动退出后再重试；“没有 direct-launch fallback”不等于对残留进程实施了网络沙箱。

本项目不把 CA 写入系统钥匙串，也不修改系统信任库；launcher 只把 `HTTP_PROXY`/`HTTPS_PROXY`、`CODEX_CA_CERTIFICATE`、`SSL_CERT_FILE`、`NODE_EXTRA_CA_CERTS` 和 loopback `NO_PROXY` 注入到本次启动的进程。`ALL_PROXY`、SOCKS/WS/FTP 及常见 Git/npm 代理覆盖变量会被移除。请按 [SECURITY.md](SECURITY.md) 管理 runtime 权限、日志和报告敏感问题。

## 官方资料

- [Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)
- [Remote connections](https://learn.chatgpt.com/docs/remote-connections)

官方资料描述的是官方产品行为；本项目只负责本机 relay 和进程级启动边界。

## 文档与贡献

- [架构](docs/ARCHITECTURE.md)
- [运行时文件与卸载](docs/RUNTIME.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [安全策略](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)

贡献默认遵循 [MIT License](LICENSE)。
