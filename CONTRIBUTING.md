# Contributing to Upkin

欢迎小而完整的修复。优先保持原生、低打扰、本地优先；不要为调试场景增加主界面配置。

## 目录

- `Sources/Upkin/`：AppKit 原生界面和应用入口。
- `Sources/UpkinCore/`：多来源额度、会话、事件解析与终端恢复。
- `Sources/UpkinCoreTests/`：可执行测试 runner，不是 XCTest。
- `Resources/`：bundle 元数据、离线角色帧、Grok Ball 导出宿主页和品牌图标。只放可再分发的素材。
- `ThirdParty/`：固定版本上游离线导出源码和许可（不是应用运行时依赖）。
- `Scripts/`：打包、活动接入和本地回归检查。

内部 target、Bundle ID、活动缓存及 hook 标记均使用 Upkin；旧名只保留在升级兼容读取与清理入口。

## 最小验证

```bash
swift build
swift run UpkinCoreTests
bash Scripts/test_rpc.sh
python3 Scripts/test_agent_activity.py
python3 Scripts/test_project_metadata.py
swift Scripts/test_character_frames.swift
```

以上与 CI（`.github/workflows/ci.yml`）一致。

涉及界面或事件时，在可交互的 macOS 登录会话中执行对应检查：

```bash
for name in native_animation conversation_icons menubar_quota status_popover state_events settings_window character_preview; do
  bash "Scripts/test_${name}.sh" || exit 1
done
```

这些脚本可能启动临时 AppKit 窗口，但不要求真实账号。`test_grok_ball_reference.cjs` 另需 Node、Playwright 与 Chrome；见架构说明；它检查离线导出来源，不代表应用运行时。`--live-*` 检查依赖本机登录，不属于默认测试，也不代表付费模型验收。

修改后构建 `./Scripts/build_app.sh`，退出旧进程再打开 `Upkin.app`。确认菜单栏显示、动画及弹窗；自动测试通过不等于视觉验收。

## 提交边界

- 保留别人的进行中改动，每一行修改都应与任务相关。
- 不提交凭据、个人会话、日志、项目路径、桌面截图或生成的 app。
- 新逻辑要有小测试；资源替换必须保留许可证并更新第三方说明。
- 默认不运行 hook 安装器，不使用真实用户配置测试。
- 贡献须有权按项目 AGPL-3.0 条款提交；第三方组件遵循其原许可。
