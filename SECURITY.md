# 安全与隐私策略

English summary: This project is an unofficial macOS MITM relay. The relay can see decrypted HTTPS content, while its local CA, config, and logs remain in the user runtime. Do not run it on traffic you are not allowed to inspect, and never publish credentials or private runtime material.

## 威胁模型与安全边界

本项目把显式启动的 ChatGPT/Codex 进程送入本机 mitmproxy，再送到用户指定的 HTTP(S) upstream。经过 TLS interception 的流量会在 relay 进程中以明文出现，可能包含会话内容、Remote 控制流量、图片请求和响应元数据。relay 运行目录、CA 私钥和日志因此属于敏感资产。

- 只在你有权监控的设备、账号和网络中运行；
- 不把 runtime 下的 CA、配置、plist、日志或进程环境分享给不可信的人；
- 不把 token、Cookie、密码、JWT、私钥或真实 upstream 凭据写入 issue、PR、截图或公开日志；
- `UPSTREAM_PROXY_URL`/`--upstream-url` 只接受无 userinfo、无路径、无查询、无片段的 HTTP(S) authority。凭据不得嵌入 URL；
- 项目不会修改系统代理、官方 ChatGPT.app 或系统 CA 信任库。任何需要系统级信任变更的方案都不属于本项目默认边界。

relay 的 LaunchAgent 可以 `KeepAlive=true`，但 ChatGPT/Codex 不会被安装为 KeepAlive 服务，也没有自动重启。若 relay 或 upstream 失败，launcher 不会主动另行普通启动，而是保留失败路径并报告错误；GUI/Chromium 等子进程的环境继承仍需业务验证。

launcher 的 postflight 只对 ChatGPT 主进程和 Codex app-server 做环境检查，并采样已建立的 TCP socket。它不会检查 UDP/QUIC，也不会证明所有 GUI/Chromium helper 或未来新增传输都经过 relay；这是一项诊断门禁，不是全进程网络沙箱。

若 ChatGPT 已启动但 postflight 失败，launcher 返回错误，却不会在未获用户确认时自动 TERM。失败实例可能继续处于未验证状态；请立即手动退出，再检查 relay、配置和日志。该选择避免守护式重启或误杀，但意味着命令失败本身不会停止所有潜在流量。

## 本地文件与权限

默认 runtime：

```text
~/Library/Application Support/Codex Proxy/
```

其中可能包含：

- `config/codex-proxy.conf`：upstream authority、路径和正则；
- `mitmproxy/`：mitmproxy CA 与运行状态；
- `relay.log`、`launcher.log` 及轮转日志；
- `RUNTIME.md`：随 runtime 保留的生命周期说明；
- 安装 manifest、runtime 脚本和库（安装期间生成，默认卸载会删除脚本/库）。

安装器和 relay 会拒绝不安全的 symlink/权限路径，并以用户私有权限写入 runtime。请继续限制目录权限，并在共享主机上检查谁可以读取 CA 或日志。默认卸载保留 `RUNTIME.md`、`config/`、`mitmproxy/` 和日志；只有 `/bin/zsh scripts/uninstall.sh --purge-runtime --yes` 才会清除整个 runtime。完整生命周期见 [docs/RUNTIME.md](docs/RUNTIME.md)。

## 不应提交到仓库的内容

以下内容必须保持在本地忽略范围内，或在提交前彻底清理：

- CA、私钥和证书材料（例如 `*.pem`、`*.key`、`*.p12`、`*.pfx`、`*.cer`、`*.crt`）；
- 真实 `config/codex-proxy.conf`、私有 plist、runtime manifest、临时 stage 和备份；
- `auth.json`、会话数据库、SQLite、cookie、浏览器/应用状态；
- relay、launcher、audit 输出中的 token、Cookie、请求体、主机名、用户名、设备名和端口供应商信息；
- 带有凭据的 upstream URL 或任何可重放的认证材料。

提交前请运行仓库测试，并用搜索工具检查当前 diff；不要把敏感值换成“看起来像真实 token”的长字符串，使用 `<UPSTREAM_URL>`、`<PATH>` 等占位符。

## 漏洞报告

如果仓库已经启用，请通过 [Private vulnerability reporting](https://github.com/kumaxs/codex-proxy/security/advisories/new) 私下报告。如果入口不可用，请只开一个不含漏洞细节或凭据的公开 issue，请求维护者提供私下渠道；不要在公开 issue 中放置可利用的凭据、CA 或完整流量样本。报告应尽量包含：

1. 受影响的 macOS 版本、CPU 架构和仓库版本；
2. 可复现的最小命令和预期/实际行为；
3. 影响范围（进程环境、relay、LaunchAgent、配置解析器或卸载）；
4. 已做的脱敏处理，以及是否涉及明文、密钥或系统配置。

维护者会在确认后决定公开时间和修复方式；请不要把真实账号或生产 upstream 发给维护者。

## 隐私与第三方服务

本项目不承诺 OpenAI、ChatGPT、Codex、Remote、图片服务或任意第三方 upstream 的可用性、合规性或 SLA。`proxy-health.sh` 与 `openai-network-audit.sh` 的探针可能访问公开服务端点；运行前确认这符合你的组织政策。业务验证结果应与诊断日志分开保存并脱敏。

## 许可证

代码和文档按 [MIT License](LICENSE) 发布。MIT 许可不扩大你对第三方服务、账号、网络或官方应用的授权；使用者仍需遵守相关服务条款、组织政策和适用法律。

## Page companion

The Page companion handles the app-authorized Page tokens and document frames in memory, only for the supported official Page endpoints. It retains origin TLS verification and does not log credentials or content. Normal launches use private file descriptors rather than a debug TCP listener. Deployment-only attach mode requires an existing local listener owned by the selected ChatGPT process. Renderer adaptation is restricted to a validated build; unknown builds retain the ordinary proxy without this adapter.
