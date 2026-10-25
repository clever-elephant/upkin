# 开源发布检查

Upkin 使用 AGPL-3.0，第三方素材保留原许可证与固定来源。公开源码与发布二进制分别验收；本地构建成功不代表完成分发验收。

## 角色素材

公开仓库与发布包只应包含已确认可再分发的角色（当前 ChatGPT 角色由 clever-elephant 绘制并采用 AGPL-3.0，云形轮廓改编自 OpenAI Codex 标志；Grok 角色源自 Grok Ball，采用 MIT，以及原创非官方 Clawd 像素演绎；Clawd 绘图为 AGPL-3.0，角色与商标归 Anthropic，不随绘图许可授予）。ChatGPT 角色随默认构建打包，不依赖 `UPKIN_EXTRA_CHARACTERS`；元数据测试覆盖它的默认绑定与资源完整性。自用的私有角色放在仓库外，通过 `UPKIN_EXTRA_CHARACTERS` 只打进本机构建，**不要用它构建要发布的二进制**。

## 源码

- [ ] 使用经过审核的源码树，确认构建时未设置 `UPKIN_EXTRA_CHARACTERS`。排除 `.build/`、`*.app/`、`.codex-qa/`、`output/`、个人日志、截图及凭据；保留离线导出源码和许可证。
- [ ] 扫描计划公开的全部文件及计划推送的 Git 历史；发现秘密先撤销或轮换。`.gitignore` 不移除已有追踪或历史，`export-ignore` 只影响 Git 源码归档。
- [ ] 核对 [第三方声明](../THIRD_PARTY_NOTICES.md) 中的固定来源、原始许可与衍生素材；品牌署名不代表官方背书。
- [ ] 在公开仓库启用私密漏洞报告，确认 README、贡献指南及安全反馈入口可用。

## 验证

- [ ] 在干净源码目录运行 [贡献指南](../CONTRIBUTING.md) 的构建、核心、RPC、Python 与界面回归。
- [ ] 在目标 macOS 版本测试未安装或未登录 AI 工具时的启动和错误降级。
- [ ] 人工检查菜单栏真实尺寸、深浅外观、减少动态效果、角色预览/用户包移除和会话跳转。
- [ ] 验证睡眠唤醒、多显示器与长时间运行；普通 AppKit fixture 不替代这些环境验收。
- [ ] 记录真实 CLI 版本及账号兼容性。Codex 额度需验证独立安装与桌面端内置 CLI 的发现、ChatGPT 登录态及 app-server 接口兼容性；Grok 的私有 ACP 接口可能随版本变化。

## 二进制

```bash
env -u UPKIN_EXTRA_CHARACTERS ./Scripts/build_app.sh
codesign --verify --deep --strict Upkin.app
file Upkin.app/Contents/MacOS/Upkin
```

脚本先构建 release 可执行文件，再在临时目录组装 bundle、校验角色 PNG，最后替换仓库根目录已有的 `Upkin.app`；不要在该 bundle 内保存自定义文件。它复制根许可、第三方声明、RunCat Neo 许可、角色帧及包内许可、品牌图标和 hook 记录器，不打包开发期 HTML/SVG/JS，也不安装 hooks 或自动启动应用。产物为 ad-hoc 签名并经 `codesign --verify` 校验；设置 `UPKIN_UNIVERSAL=1` 时分别构建 arm64 与 x86_64 再用 `lipo` 合并。

- [ ] 默认按构建主机架构产出；发布包由 `package_release.sh` 构建 Universal 并校验两种架构。
- [ ] 决定 Developer ID 签名与公证方案；未公证的预览版明确告知安装限制，不默认要求用户关闭系统安全功能。
- [ ] 记录版本、build number、源码 commit/tag；随 app 提供对应源码、构建步骤、根许可证及第三方声明。
- [ ] 独立安装并启动最终制品，确认资源和许可完整，并核对 bundle 内实际目录：第三方声明中的仓库路径不是 bundle 路径。旧版用户重新配置活动 hooks 前保留仍被引用的旧 bundle，不自动改写用户配置。

## 发布流程

1. 更新 `Resources/Info.plist` 的 `CFBundleShortVersionString`（递增 `CFBundleVersion`），并在 `CHANGELOG.md` 新增 `## [x.y.z] - 日期` 小节。
2. 本地试打包：`./Scripts/package_release.sh`，产物为 `dist/Upkin-x.y.z-macos.zip` 与 `.sha256`；解压到其他目录启动验收。
3. 提交后打标签并推送：`git tag -a vx.y.z -m "Upkin x.y.z" && git push origin main vx.y.z`。
4. `.github/workflows/release.yml` 在 tag 推送后运行测试、校验 tag 与 Info.plist 版本一致、构建 Universal zip，并以 CHANGELOG 对应小节为说明创建 GitHub Release。

## 当前支持边界

运行需 macOS 14+，构建需 Xcode 26（Swift 6.3 已验证）；iTerm 跳转需系统自动化许可；活动 hooks 需 Python 3，默认不安装。当前没有自动更新、遥测或正式公证发布流程。

Apple Silicon 保留其他显示器的角色静态回退；Intel 的非活动显示器可能只显示额度，见 [架构说明](architecture.md)。未验证的平台或环境不记为通过。
