# Upkin 项目适配

仅在本仓库使用此参考；复制技能到其他项目时由该项目的真实约束替换，不把本文件的数值推广为通用要求。下列路径均相对仓库根目录，无外部安装路径依赖。

## 当前合约

- 项目设计基线：`AGENTS.md`、`docs/character-animation-guidelines.md`；保留已验收角色与许可，未请求时不批量重做其他角色。
- 开发源：`Resources/ChatGPT/index.html`、`Resources/GrokBall/index.html`、`ThirdParty/GrokBall/grok-ball.js`。公开仓库只放可再分发的角色；不可再分发的自用角色放在仓库外，见 `docs/character-packs.md` 的「本机私有角色」。
- 离线资源：`Resources/CharacterFrames/<character>/<state>/<index>.png`，各包 `manifest.json`；保留包内 `SOURCE.txt` 与许可。
- 当前 PNG 为透明 72×44px，在菜单栏显示 36×22pt；采样率完整 15 FPS。播放器校验每状态 1–150 帧，超过 150 的测试输入应被拒绝。增加预算需同步校验、边界测试和实测，不截断或跳帧规避。
- 状态 ID：待机 `02`、思考 `30`、工作 `32`、等待 `35`、完成 `33`、错误 `34`、未知/待确认 `11`。菜单栏 `33`/`35` 事件提示均只播一个完整周期；`34` 不触发菜单栏提示。面板与角色预览按 manifest 播放，错误素材可用 `loopStartFrame` 做入场＋循环尾段。
- `staticFrame` 指向稳定代表帧；manifest 同时记录 `version`、`width`、`height`、各状态 `frames`、`fps` 和 `loop`；可选 `loopStartFrame` 指定只播一次的前缀之后的循环起点，必须配合 `loop=true` 且位于1至frames-1之间。
- 原生实现：`Sources/Upkin/GrokBallView.swift` 中 `CharacterFrames` 与独立 CALayer contents 关键帧；`main.swift` 负责 70pt 菜单栏、静态副本及额度。角色层不逐帧替换 `button.image`；只加载当前角色/状态；`ConversationIcons.swift` 缓存列表代表帧，面板展开时复用原生播放器，仅播放可见行，关闭即释放播放帧。
- 状态来源：`Sources/UpkinCore/CodexSessionActivityFetcher.swift`、`AgentActivity.swift`；焦点、完成/等待事件与待播校验：`MenuBarPresentation.swift`。平时展示轮次最新的非子代理运行任务；提示期间分别保留最新等待与最新完成，等待校验失效再尝试完成，不按 phase 汇总。子代理、中断和错误不提示；静态等待点独立保留。制作新动作不修改这些业务合约。

## 统一节奏基线

全部角色的循环状态共用4秒主节拍（60帧/15FPS）。工作A/B两轮共8秒/120帧；Grok思考双轮同为8秒素材。待机、等待、待确认素材为4秒；完成/等待提示时长取 manifest 的 frames/fps，不使用核心固定秒数；错误只在面板/预览按 manifest 播放；需要错误尾段时用75帧素材、loopStartFrame=15，不重复受挫入场。以 `docs/character-animation-guidelines.md` 的状态表为准。

每轮仅在固定节点同步切换整组脸，轮内保持，不恢复角度阈值、随机变脸或独立表情计时器。


## 最小修改与验证入口

在仓库根目录运行，先检查脚本现有参数与本地依赖。导出仅用已有 Playwright/浏览器环境；缺依赖时说明缺口，不为角色任务自动全局安装工具。

```bash
# 有针对性地重烘焙现有角色、状态；省略参数会扩大导出范围。
node Scripts/export_character_frames.cjs grok 32
node Scripts/test_character_export_config.cjs
swift Scripts/test_character_frames.swift
bash Scripts/test_grok_ball.sh
bash Scripts/test_native_animation.sh --character grok
node Scripts/test_unified_cadence.cjs
node Scripts/test_role_cadence.cjs
swift run UpkinCoreTests
swift build
```

新角色直接提供 PNG＋manifest 资源包，不新增角色枚举或播放器分支；用户包放入 `~/Library/Application Support/Upkin/Characters/`，重新打开「设置 → 角色」刷新。需要使用现有 HTML/SVG 导出协议时，在 `Resources/<source>/export.json` 声明源与七状态时序，导出器自动发现。完整 JSON、边界和开发源协议见 `docs/character-packs.md`；不把示例命令里的 grok 当作新角色名。测试所有既有角色的命令仍须保留覆盖。

涉及主 UI 或资源播放时继续使用 `Scripts/test_status_popover.sh`、`Scripts/test_conversation_icons.sh`、`Scripts/test_state_events.sh`；性能用 `Scripts/test_native_performance.sh` 并先读当前参数与指标含义。性能采样和其他 UI 测试串行，避免相互干扰。修改代码后先编译，再按项目要求重启 Upkin；由负责集成的代理统一重启，避免多个进程污染采样。

## 小尺寸验收

保留固定画布和配额区域；当前静态副本清除层只覆盖角色区 x<32pt，额度从 x=32pt 起，不扩大遮罩。实际菜单栏确认亮暗外观、点击、减少动态效果与屏幕缩放；跨屏及 Intel 的已有局限应明确记录，不由普通窗口测试代替。

真实屏幕截图需在采集时确认当前宿主、活动显示器和缩放，不能复用先前阶段的位置。状态栏可能跨屏或自动隐藏，`window.occlusionState` 的可见标记不证明指定屏幕矩形仍含图标；取到桌面应报告采样失败，不能放宽断言或据此判定动画静止。
