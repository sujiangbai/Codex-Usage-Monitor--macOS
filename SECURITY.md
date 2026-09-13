# 安全问题报告

请通过 [GitHub 私密漏洞报告](https://github.com/sujiangbai/Codex-Usage-Monitor--macOS/security/advisories/new) 联系维护者 sujiangbai。不要在公开 Issue 中提交尚未修复的漏洞细节、Token、`auth.json`、Cookie、原始额度响应、私人配置或真实账号截图。

报告请尽量只包含受影响版本、macOS / Codex 版本、使用合成数据的复现步骤、预期与实际结果。不要为了复现而访问他人账号或破坏他人数据。若私密入口不可用，可先在普通 Issue 请求开放私密渠道，但不要公开敏感细节。

维护资源有限，优先处理最新发布版本的问题，不承诺响应或修复时限。修复后通过 GitHub Releases 发布，不内置自动下载更新功能。

## 当前边界

- 只提供 Apple Silicon、macOS 13+ 构建。
- 当前仅 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。SHA-256 校验用于文件完整性检查，不等同于发布者身份认证；不要为安装关闭整体系统安全保护。
- 组件会执行本机 Codex，尚未增加候选程序发布者验证；请从可信来源安装官方程序，并保护本机账户和可执行文件目录。
- 组件本身不读取凭据文件、不执行服务端下发动作、不开放 TCP 监听端口，但这不是对本机其他程序或官方 Codex 所有版本的安全保证。

项目按 Apache License 2.0 提供。安全报告渠道和本说明不修改许可证，不承诺绝对安全。
