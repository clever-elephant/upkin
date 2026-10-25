# Security

请勿在公开 issue 中粘贴 OAuth 凭据、auth.json、钥匙串导出、会话日志或含私人项目的截图。

安全问题请使用 GitHub 仓库的 [Security → Report a vulnerability](https://github.com/clever-elephant/upkin/security/advisories/new) 私下报告（维护者应在公开前启用 Private vulnerability reporting）。若该入口尚未启用，可开一个仅请求私密报告渠道的 issue，不附漏洞细节、复现、日志或秘密；等待维护者提供私密渠道后再提交完整报告。

报告建议包含：受影响版本、最小复现、影响范围与脱敏证据。诊断只需结构和错误信息，不需要真实令牌。

## 支持范围与验证

目前仅维护默认分支的最新代码；尚无历史发行版安全更新承诺。报告请注明 commit、macOS 及相关 CLI 版本。修复验证方式见 [贡献指南](CONTRIBUTING.md)，使用临时目录和脱敏 fixture，不用真实凭据复现。

目前项目由社区维护，没有承诺的响应时限。只有本机 ad-hoc 构建，尚无签名、公证的正式发行版。
