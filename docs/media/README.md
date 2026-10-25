# README 展示资源

2026-10-26 使用当前生产 AppKit 控件重新导出。中英文 README 共用资源，应用界面仍为中文。

- `app-icon.png`：由当前 `Resources/AppIcon.icns` 转出。
- `conversations-light.png` / `conversations-dark.png`：会话分组、项目、运行时长和 Codex 父子会话树，底部展示三种工具的剩余额度。
- `quota-light.png` / `quota-dark.png`：同一会话面板，展开 Codex 额度窗口、重置时间和更新时间。
- `connections-light.png` / `connections-dark.png`：原生工具连接页。
- `characters-light.png` / `characters-dark.png`：原生角色页，展示当前公开包与七状态预览。
- `notifications-light.png` / `notifications-dark.png`：原生通知设置页，不伪造系统通知横幅。
- `hero.gif`：由 `Scripts/export_readme_frames.cjs` 渲染高清素材，`Scripts/export_readme_hero.py` 读取三个默认角色包的 manifest，依次播放思考（30）、工作（32）、等你确认（35）与完成（33）；每段至少覆盖每个角色的一个完整周期，一次性状态停留在最后一帧。15 FPS，1440×460px，在 README 中以 720px 宽显示。角色直接从原始 SVG / 绘图源以 432×264px 渲染，不放大菜单栏的 72×44px 帧；文字也以 2 倍分辨率绘制。

截图保留实际原生界面，只添加统一渐变背景、留白与阴影，不重绘控件。会话、路径、连接状态与额度均为演示数据，不代表真实账号或联网验收。截图程序不调用服务、不安装 hooks、不写偏好设置。角色目录沿用应用发现规则；公开展示前应确认截图中只出现可公开的角色包。

## 重新导出

在仓库根目录运行（macOS 需要屏幕录制权限；第二、四步需要 Python 的 Pillow；第三步使用已有 Playwright，可通过 NODE_PATH 与 CHROME_PATH 指定本机依赖和浏览器）：

```bash
./Scripts/export_readme_media.sh
python3 Scripts/finish_readme_media.py
node Scripts/export_readme_frames.cjs
python3 Scripts/export_readme_hero.py
```

第一步把原生截图写到 `.codex-qa/readme-refresh/`，并更新应用图标；第二步生成此目录的最终截图；第三步生成高清角色帧，第四步合成 `hero.gif`，这两步无需屏幕录制权限。应用仍播放原生 PNG + Core Animation，不加载 README GIF。

角色、图标与衍生预览的来源与许可见 [第三方声明](../../THIRD_PARTY_NOTICES.md)。
