# Grok Build / Claude Code 活动接入

## 范围与体积

跟踪 Codex、Claude Code 和 Grok Build 的本机会话。Codex 从本地 app-server 与日志读取；Claude / Grok 的细粒度活动来自用户手动接入的 hooks。三者均支持额度读取，来源、网络边界和失败行为见 [技术说明](architecture.md)。普通 Claude 桌面聊天和 Grok Bot 不在范围内，子代理不作为额外主会话计数。

Codex 默认使用 ChatGPT 角色（AGPL-3.0），Grok Build 默认使用 Grok 角色（源自 Grok Ball，MIT），Claude Code 默认使用原创非官方 Clawd 像素演绎（绘图 AGPL-3.0，角色与商标归 Anthropic），也可换成自定义角色包。许可和固定来源见 [第三方说明](../THIRD_PARTY_NOTICES.md)。

不增加 HTTP 服务、Electron 或常驻 Node/Python 进程。图标使用离线 PNG 与原生 Core Animation 播放；Hook 每次短暂启动已有 Python 3，只写本应用缓存。应用使用 FSEvents 监听本地变化。

## 会话与状态

会话键为 `provider + sessionID`；文件名用 SHA-256，两个工具的相同会话 ID 互不覆盖。文件加锁更新、原子替换；只保留来源、会话 ID、状态、开始时间、更新时间、当前工具 ID 和轮次 ID，不保存提示词、回复、命令参数或项目内容。

| 事件 | 状态 | 计入运行数 |
| --- | --- | --- |
| SessionStart | 待机 | 否 |
| UserPromptSubmit | 思考 | 是 |
| PreToolUse | 工作 | 是 |
| PostToolUse | 还有其他工具则工作，否则思考 | 是 |
| PermissionRequest / permission_prompt | 等待输入 | 否，单独计入等待数 |
| PostToolUseFailure / StopFailure | 出错 | 否，单独计入错误数 |
| Stop | 有背景任务/未完成工具则工作，否则 Claude 完成、Grok 状态待确认 | 仅工作时 |
| task_complete 通知 | 完成 | 否 |
| idle_prompt / StopCancelled（仅 Grok）/ SessionEnd | 待机 | 否 |
| PreCompact / PostCompact | 思考 | 是 |

Claude 的 `Stop` 代表回复结束；Grok 的 `Stop` 是可被其他 hook 拦截的门控事件，缺少明确完成通知时保留“状态待确认”。完成记录保留为最近结果；从运行中或等待转为完成时触发一次提示与通知，提示后回到焦点任务。首次读取、子代理、中断和错误不补发提示。

Grok 使用 `promptId` 忽略旧轮次延迟到达的结束事件；缺少轮次 ID 的来源无法保证跨轮次乱序消歧。Grok 会读取 Claude 兼容 hooks，因此 Claude 记录器发现 Grok 的 camelCase 信封时忽略它，避免重复计数。

统计仅代表最近收到的真实事件，不是进程存活证明。异常退出/事件丢失可能保留旧状态；运行或等待状态超过一小时无更新后，在下一次事件或十分钟恢复检查时标记“待确认”，绝不推断成功。只展示最近 24 小时记录；面板合并来源分组，最多保留 10 条已完成会话，待处理和运行中会话不受此数量限制。缓存文件不自动删除。

菜单栏固定一个图标位，不按来源汇总状态优先级。平时展示非子代理运行任务中 `turnStartedAt` 最新者的角色及 thinking/working 动作；停止运行后重选，无运行任务时保留最后角色待机。Claude / Grok 的 `UserPromptSubmit` 刷新轮次时间；Grok 缺少 prompt 信号时退化为非运行→运行的时刻；等待后恢复执行也刷新。Codex 读取本地用户消息与 turn start 事件，不新增 hook。

完成与等待事件播放一个完整动作周期（manifest 帧数 ÷ fps），不写死秒数、不打断当前提示。期间分别保留最新等待与最新完成，播前优先校验等待，失效则尝试完成，只选一个后清空待播槽。所有事件照常通知，面板保留各任务真实状态；任务进入错误只退出焦点，不提示、不通知。静态等待点在仍有等待任务时保留；任务离开等待时移除对应等待通知。原生播放器完整播放 15 FPS 素材；系统“减少动态效果”开启时使用静态代表帧。面板和角色预览按各包 manifest 播放，与菜单栏一次性提示分开。

## 安装、撤销与验证

在 **设置 → 连接** 中，每个工具只有一个按钮。「连接／重试」会一并配置 Upkin 的会话 observer 并连接额度；旧路径会自动替换，保留其他 hooks 和配置字段，不额外确认、不创建备份。只有额度可用且会话配置完整时才显示「已连接」。Claude 已授权时显示「管理…」，菜单同时提供重试连接与断开；连接或 hooks 出错也保留撤销入口。「断开」先撤销额度授权，再尝试移除自己的 observer；清理失败会显示错误，修复配置后可重试移除。

打开设置只检测，不自动写入配置。更新 hook 后需重新打开对应 CLI 会话；移动应用后再次点击连接即可更新。配置完整不代表已经收到真实活动事件。

终端脚本仍可用于预览与安装（保留脚本原有备份行为）。先构建：

```bash
bash Scripts/build_app.sh
python3 Scripts/configure_agent_hooks.py          # 只预览目标路径，不写配置
python3 Scripts/configure_agent_hooks.py --install
```

安装会追加本应用 observer 到 `~/.claude/settings.json` 和 `~/.grok/hooks/upkin-activity.json`，不修改 Codex 配置；写入前生成权限 0600 的配置备份。已有 hook 和配置字段保留。重复安装不产生重复条目，并清理旧版误写入 Claude 的本应用 `StopCancelled` observer；该事件仅向 Grok 注册。配置命令绑定当前 Python 解释器与当前 app bundle 的绝对路径，移动应用或升级 Python 后应重新配置。

从旧版迁移时，新 bundle 为 `Upkin.app`。旧 hook 命令仍指向旧 bundle；确认新路径后手动重新执行安装命令以替换 observer，并清理旧 Grok 配置中的本应用 observer（保留其他 hook 与字段），保留旧 bundle 直到迁移完成。应用不自动改写配置。

安装后重新打开 CLI 会话以加载 hooks。不自动发起模型请求或付费任务，不操作审批。

```bash
python3 Scripts/configure_agent_hooks.py --remove  # 只删除本应用 observer，保留其他 hooks
python3 Scripts/test_agent_activity.py
swift run UpkinCoreTests
bash Scripts/test_status_popover.sh
bash Scripts/test_state_events.sh
```

缓存路径也随名称更新；重新配置 hook 后，新事件写入新目录，旧目录保留但不再读取。

应用状态目录：`~/Library/Caches/Upkin/activity/`。不要把测试事件写入此目录冒充真实活动，测试统一使用临时目录。

原始事件契约参考：Claude Code 官方 hooks reference（https://code.claude.com/docs/en/hooks）以及本机 Grok Build 自带 `~/.grok/docs/user-guide/10-hooks.md`。角色素材及许可证随应用保留。
