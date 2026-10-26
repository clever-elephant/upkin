# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.1] - 2026-10-26

### 修复

- 菜单栏百分比显示可用额度：取 5 小时与每周剩余额度中的较低值，不再固定显示周额度；只有一个周期时使用该周期。
- 悬浮说明与无障碍描述同步使用可用额度口径。

### 优化

- 收紧菜单栏角色与额度的布局，移除等待圆点。
- 更新 README 截图、角色演示与构建工具链说明。

### 下载说明

- `Upkin-1.0.1-macos.zip`：Universal（Apple Silicon + Intel），macOS 14+。
- 当前为 ad-hoc 签名，未经 Apple 公证；首次打开的处理方法见 README「安装」。

## [1.0.0] - 2026-10-26

首个公开版本。

### 功能

- 菜单栏角色动画表达 Codex、Claude Code、Grok Build 的思考、工作、等待、完成与出错状态；内置 ChatGPT、Clawd、Grok 三个角色。
- 面板按待处理、运行中、已完成分组会话，Codex 子任务挂在主任务下；点击跳回 Codex 桌面应用或 iTerm 会话。
- 显示三家剩余额度与重置时间，⌘R 刷新。
- 任务完成时发出静音通知（可关闭）。
- 支持角色预览与用户自制角色包导入。

### 下载说明

- `Upkin-1.0.0-macos.zip`：Universal（Apple Silicon + Intel），macOS 14+。
- 当前为 ad-hoc 签名，未经 Apple 公证。首次打开会被 Gatekeeper 拦截，处理方法见 README「安装」。
