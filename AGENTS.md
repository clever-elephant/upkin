# Agent 指南

## 项目概览

Upkin 是一个 Swift Package，用来构建轻量级 macOS 菜单栏应用，支持 Codex、Claude Code 与 Grok Build 的额度和会话活动。当前使用离线导出的原生 PNG 帧动画。

产品、可执行文件及主 target 统一为 Upkin，核心模块为 UpkinCore，测试 runner 为 UpkinCoreTests；bundle ID 为 com.local.Upkin。旧名仅用于升级兼容读取和清理。项目采用 AGPL-3.0，第三方资源各自许可见 THIRD_PARTY_NOTICES.md。

## 产品定位与体验取舍

- 这是一个“小而美”的 macOS 工具，不是完整监控平台。所有功能都应服务于菜单栏里的快速感知、轻量操作和低打扰陪伴感。
- 默认优先级是：稳定可靠、原生 macOS 质感、状态表达清楚、资源占用低、可理解可恢复。炫技、复杂配置和大而全功能排在后面。
- UI 要克制、紧凑、可一眼扫懂。菜单栏图标、popover 和菜单项都应减少文字负担，避免把桌面小工具做成网页式仪表盘。
- 新功能必须有明确的日常使用场景。若一个能力只对少数调试场景有用，优先放到文档、脚本或隐藏诊断路径里，不要默认暴露在主 UI。
- 保持“本地优先”。会话状态读取不应依赖网络服务；既有 Claude / Grok 额度查询可联网，但不上传会话内容，也不静默修改用户配置。
- 自定义能力要友好但有边界：优先采用文件夹、JSON profile、资源包导入这类用户可理解的方式；同时要校验输入、提供重置路径，并避免因为坏资源导致应用崩溃。
- 动画和视觉反馈应该温和、有生命感，但不能抢注意力。状态变化要帮助用户理解 Codex 是否在思考、工作、等待或出错，而不是单纯追求动效复杂度。
- 做技术取舍时，优先删除和收敛。能用现有 AppKit、Swift 标准库、本地文件和既有核心模块解决的问题，不引入新依赖或新常驻进程。

## 仓库结构

- `Package.swift`: Swift Package 清单。项目要求 macOS 14 和 Swift tools 6.0。
- `Sources/UpkinCore/`: 核心配额、RPC、可执行文件定位和会话活动逻辑。非 AppKit 行为优先放在这里。
- `Sources/Upkin/`: AppKit 菜单栏应用入口和 UI 连接代码。
- `Sources/UpkinCoreTests/`: 使用本地 `expect` 辅助函数的可执行测试 runner。它不是 XCTest target。
- `Resources/`: App bundle 元数据和角色 PNG 帧资源。
- `Scripts/`: 打包脚本、Claude / Grok 活动 hook 辅助脚本（Codex 不使用 hook）及本地回归检查。

## 构建与测试

在仓库根目录使用这些命令：

```bash
swift run UpkinCoreTests
swift build
swift Scripts/test_character_frames.swift
```

可选检查：

```bash
swift run UpkinCoreTests --live-sparse-path
swift run Upkin
./Scripts/build_app.sh
```

只有在任务需要时才运行 live app/RPC 检查。它们依赖本地 Codex 安装和用户环境。

每次完成代码修改后，必须先编译验证，再重启 Upkin 应用以加载最新构建；如果无法重启，要在最终回复里说明原因。

## 编码约定

- 平台 UI 代码放在 `Sources/Upkin/`，可复用逻辑放在 `Sources/UpkinCore/`。
- Codex RPC/进程相关工作优先使用 `async` API 和明确的错误类型。
- 除非项目明确迁移到 XCTest，否则保留 `Sources/UpkinCoreTests/main.swift` 里现有的简单可执行测试风格。
- 菜单栏文本要保持紧凑；避免在 status item 本身放很长的状态字符串。
- 谨慎处理进程检测和 hook 逻辑。优先使用确定性的解析辅助函数，并通过 core test runner 覆盖。
- Codex 状态保持本地读取；Claude OAuth 额度与 Grok CLI 账单查询沿用既有网络边界，不上传会话内容。

## 项目内技能

- 新建、制作或修改菜单栏角色及动作包时，使用 `.agents/skills/menu-bar-character/SKILL.md`；通用动作与表情规范在技能主体，当前项目的资源参数、源码及测试入口在其 `references/upkin.md`。技能随项目自动发现，不依赖全局安装。

## 资源约定

- 所有现有及新增角色遵守 `docs/character-animation-guidelines.md`：工作状态每轮完整主动作只在固定节点切换一次表情；眼睛和嘴巴同步，轮内保持稳定。导出完整周期，不以降低 FPS 或任意截段解决节奏问题。

- 公开仓库只放可再分发的角色（当前为 ChatGPT、Grok（源自 Grok Ball）与原创非官方 Clawd 像素演绎；Clawd 角色与商标归 Anthropic，绘图许可不授予这些权利）；不可再分发的自用角色放在仓库外，经 `UPKIN_EXTRA_CHARACTERS` 打入本机构建，不得提交。

- 当前角色帧位于 `Resources/CharacterFrames/<character>/<state>/<index>.png`，每包 `manifest.json` 记录帧率与循环方式；72×44px 对应菜单栏 36×22pt 的 2x 显示。
- 原 SVG / JS 仅用于开发期离线导出；应用只打包帧及许可，不在运行时创建 WebKit。导出后必须校验每个角色七状态、透明背景与最后一帧。
- 默认只加载当前角色/状态；面板展开时仅可见列表行播放原生帧动画，关闭或滚出可见区域即停止并释放播放帧，减少动态效果使用静态代表帧；不为列表或隐藏角色增加动画计时器。菜单栏通过独立 CALayer 的 contents 关键帧以完整 15 FPS 播放，不逐帧更新 button.image；配额与静态副本仅在状态、外观、缩放或额度变化时更新。

## 安全注意事项

- 除非用户明确要求，否则不要修改用户的 Codex 配置、hook 文件或本地 Codex 状态。
- 安装活动 hook 的脚本属于有副作用的操作。运行前先检查脚本；如果确实需要执行，要说明它的副作用。
- 避免破坏性的 git 清理操作，除非用户明确要求。
