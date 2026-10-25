# 添加角色：资源包与开发源分开

应用只读取 PNG 与 `manifest.json`；新增角色不需要 Swift 枚举、播放器分支或状态映射代码。角色制作可以用手绘、动画工具或开发脚本，但导入前需导出成同一资源协议。

## 安装 PNG 角色包

将文件夹放到：

```text
~/Library/Application Support/Upkin/Characters/my-character/
  manifest.json
  LICENSE
  SOURCE.txt
  02/0.png …
  30/0.png …
  32/0.png …
  35/0.png …
  33/0.png …
  34/0.png …
  11/0.png …
```

文件夹名是稳定 ID，采用小写字母、数字、连字符或下划线（最多80字符），不使用名称或路径分隔符。重新打开「设置 → 角色」刷新预览列表；点击角色只切换预览，不修改工具绑定。菜单栏与会话列表统一使用各工具的默认角色，不再读取旧的自选绑定。角色较多时横向滚动查看，“默认预览”返回默认角色预览。移走自定义文件夹可撤销导入。自定义包不执行脚本，也不读取包里的 HTML。

以下为完整最小 manifest 示例；每状态一张图可先验证接入，真正动画应导出完整动作周期：

```json
{
  "version": 1,
  "name": "我的角色",
  "sortOrder": 40,
  "width": 72,
  "height": 44,
  "states": {
    "02": { "frames": 1, "fps": 15, "loop": true, "staticFrame": 0 },
    "30": { "frames": 1, "fps": 15, "loop": true, "staticFrame": 0 },
    "32": { "frames": 1, "fps": 15, "loop": true, "staticFrame": 0 },
    "35": { "frames": 1, "fps": 15, "loop": true, "staticFrame": 0 },
    "33": { "frames": 1, "fps": 15, "loop": false, "staticFrame": 0 },
    "34": { "frames": 1, "fps": 15, "loop": false, "staticFrame": 0 },
    "11": { "frames": 1, "fps": 15, "loop": true, "staticFrame": 0 }
  }
}
```

- 七状态固定：待机 `02`、思考 `30`、工作 `32`、等待你 `35`、完成 `33`、错误 `34`、待确认 `11`（不确定状态，不等于成功）；角色自己画动作，不更改业务状态。
- 每状态 `1–150` 帧，连续命名 `0.png` 至 `frames-1.png`，每张为 72×44px PNG，建议透明背景。播放帧率范围 `1–15`，制作仍优先完整 15 FPS。
- `staticFrame` 是减少动态效果与静态图标的代表帧，索引必须落在本状态中。
- `loop: false` 播一次后保持；`loop: true` 持续循环。可选 `loopStartFrame` 大于 0、小于 `frames`：前缀只播一次，再循环尾段。例如错误状态 `frames: 75, fps: 15, loop: true, loopStartFrame: 15, staticFrame: 15` 表示 1 秒入场＋4 秒循环。
- `name` 为显示名（省略使用文件夹名）；`sortOrder` 控制排序（省略为 0）。可选 `defaultFor` 是单个工具 ID 或 ID 数组（`codex`、`claude`、`grok`），表示这些工具默认使用此包，不是必填项。例如内置 ChatGPT 为 `"codex"`，Grok 为 `["grok"]`，Clawd 为 `["claude"]`。
- 包完整性、PNG头尺寸/大小、帧数、帧率、路径和循环边界在发现时校验，非法包跳过；发现阶段不解码整包像素。损坏的像素数据由原生播放器拒绝并显示后备图标，移走损坏的用户包并重启应用可恢复内置包，不影响其他包。第三方素材随包保留许可和来源，校验通过不代表获得分发权。

开发者可运行像素级检查（额外验证透明和非空内容）：

```bash
swift Scripts/test_character_frames.swift "$HOME/Library/Application Support/Upkin/Characters"
```

内置包使用同样结构，放在 `Resources/CharacterFrames/`；构建脚本整目录复制，无需修改角色清单。不要直接覆盖内置包目录中的既有角色来试验新角色。

## 开发期 HTML/SVG 源适配

已经有 PNG 的角色到此结束，**不需要 `export.json`**。

本仓库现有 HTML/SVG 制作源使用 `Resources/<source>/export.json`，导出器自动发现，不维护全局角色列表。配置示例可参考 `Resources/GrokBall/export.json`。

配置字段：

| 字段 | 用途 |
| --- | --- |
| `id` | 输出到 `Resources/CharacterFrames/<id>` |
| `sourceHTML` | 相对于配置目录的 HTML 文件 |
| `assetMarker` | 可选，将同目录 SVG 文件名（不含后缀）映射注入为 `const assets` 的替换标记 |
| `runtime` | 可选 `{ "marker": "…", "file": "…" }`，将本地 JS 替换到标记；文件相对于配置目录 |
| `frameSelector` | 可选 iframe 选择器；未指定时在主文档取帧，指定时等待 iframe 内 SVG 就绪 |
| `attributionDirectory` | 相对于配置目录，含 `LICENSE` 与 `SOURCE.txt` 的来源目录 |
| `states` | 七状态字典，各项含 `seconds`、`loop`、`staticFrame`，可选 `loopStartFrame` |

这不是任意 SVG 的通用播放器：源 HTML 必须实现 `setBallState(id, false, 0)`；动画适配现有确定性时钟（requestAnimationFrame、定时器、CSS 动画），接受固定 60Hz 积分和 15 FPS 截图。新的制作协议需自己先适配此开发接口，或直接从别的工具导出 PNG。

```bash
# 只导出指定角色和状态；省略状态导出该角色，省略角色导出全部源码角色。
node Scripts/export_character_frames.cjs my-character 32
node Scripts/test_character_export_config.cjs
swift Scripts/test_character_frames.swift
node Scripts/test_unified_cadence.cjs
```

导出依赖现有 Playwright 与本地浏览器；不在应用运行时加载。导出更新动画字段，但保留现有 manifest 的 `name`、`defaultFor`、`sortOrder` 等元数据。新包首次导出后编辑 manifest 设置显示名，再进行小尺寸、接缝和业务状态切换验收。角色特有的脸形/动作测试仍作为回归测试保留，不要求新角色复用旧角色表情。

## 本机私有角色

有些角色你可以自用，但许可不允许再分发（例如只授权个人使用的美术）。这类角色**不要放进仓库**，放在仓库外的目录里，例如：

```text
~/UpkinPrivateCharacters/
  my-character/manifest.json, LICENSE, 02/0.png …
```

两种用法任选其一：

- **打进本机构建**：`UPKIN_EXTRA_CHARACTERS=~/UpkinPrivateCharacters ./Scripts/build_app.sh`。同 ID 的本机包会先清空 bundle 内的同名文件夹再复制，并输出替换提示，避免旧 PNG 合并残留。私有包与内置包同级加载，可以用 `defaultFor` 替换某个工具的默认角色。只用于自己的机器，不要用这样构建的 app 发布。
- **放进用户目录**：复制到 `~/Library/Application Support/Upkin/Characters/`。注意界面回归脚本也会扫描这个目录，运行测试前先移走。

ChatGPT 角色已内置于公开版，无需通过本机额外角色目录加载。`Scripts/test_project_metadata.py` 检查它的默认绑定与资源元数据。

升级兼容：仍读取旧版 `~/Library/Application Support/Agent Upstairs/Characters/`，新增角色请使用 Upkin 目录；不会自动移动或删除旧资源。
