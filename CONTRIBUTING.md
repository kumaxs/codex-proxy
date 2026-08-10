# 贡献指南

English summary: Contributions should preserve this project's unofficial, macOS-only, process-scoped relay boundary. Keep changes small and auditable, run the real repository tests, and never commit credentials, CA material, private runtime files, or claims about unsupported scripts.

感谢参与。这个仓库维护的是本地 relay、启动器、诊断脚本和公开文档；贡献必须尊重以下范围：

- 这是非官方 macOS 工具，不代表 OpenAI、ChatGPT 或 Codex；
- relay 默认是 loopback `127.0.0.1:29759`，并转发到用户显式提供的 HTTP(S) upstream；
- 不改系统代理、官方 ChatGPT.app 或系统 CA 信任库；
- relay LaunchAgent 可以 `KeepAlive=true`，但不为 ChatGPT/Codex 添加 KeepAlive、自动重启；launcher 校验失败时不主动另行普通启动；
- upstream URL 禁止 userinfo、路径、查询和片段；不要用 URL 携带凭据；
- Remote 和图片能力需要业务实测，不得把某类 Responses WebSocket 的 `5/5` 观察写成全局保证；
- `PASSTHROUGH_REGEX` 必须保持 mitmproxy `--ignore-hosts` 的原样语义。

## 提交前检查

只修改与你的变更直接相关的文件，不要回退其他人的工作。至少运行：

```bash
/bin/zsh -n scripts/*.sh bin/*.sh lib/*.sh
/bin/zsh scripts/test-config.sh
/bin/zsh tests/run.sh
```

如果改动安装器、runtime 或应用构建路径，还应在当前支持环境中先执行 dry-run，再由维护者决定是否做真实安装。不要在测试、文档或示例里写入本机绝对路径、真实 upstream、token 或 CA 内容。

## 文档与脚本变更

涉及命令或配置行为时，请同步更新：

- `README.md` 的安装、常用命令和支持边界；
- `docs/ARCHITECTURE.md` 的数据流、安全边界和 Mermaid 图；
- `docs/RUNTIME.md` 的持久文件和卸载策略；
- `docs/TROUBLESHOOTING.md` 的实际故障路径。

只能引用仓库中实际存在的入口，例如 `scripts/install.sh`、`scripts/uninstall.sh`、`bin/start-relay.sh`、`bin/launch-codex-proxied.sh`、`bin/proxy-health.sh` 和 `bin/openai-network-audit.sh`。不要在文档中添加未经实现和验证的入口，也不要承诺签名、公证或跨架构支持，除非实现和验证同时落地。

## 安全与隐私

- 不提交 CA、私钥、证书、认证状态、SQLite、日志、私有 plist、runtime manifest 或临时 stage；
- 不在 PR、issue、测试 fixture 或截图中放真实主机名、账号、设备名、Cookie、JWT、token、请求体或 upstream 凭据；
- MITM relay 能看到经过 interception 的解密明文，新增日志和诊断必须明确数据范围并默认脱敏；
- 不扩大脚本权限，不绕过 symlink/owner/mode 校验，不添加系统级代理或系统 CA 写入；
- 报告安全问题请遵守 [SECURITY.md](SECURITY.md)，不要公开投递可利用材料。

## Pull Request 内容

PR 描述请说明：

1. 复现条件和受影响平台/架构；
2. 变更文件与行为边界；
3. 失败、回滚和卸载路径；
4. 运行过的命令、测试输出和未验证项；
5. 是否涉及 Remote、图片或 Responses WebSocket，以及哪些结论只是业务实测而非项目保证。

## 许可证

贡献默认按 [MIT License](LICENSE) 发布。提交即表示你有权按该许可提供相应内容。
