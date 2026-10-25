# 使用指南

## 构建与启动

运行需要 **macOS 14+**；从源码构建需要 **Xcode 26 或对应的 Command Line Tools**（已验证 Swift 6.3）。先安装并登录要使用的 AI CLI；无需同时使用全部三种工具。Codex 额度通过已用 ChatGPT 账号登录的 `codex` CLI 查询，优先查找 PATH、`~/.local/bin` 及常见安装目录，其次查找 `/Applications` 或 `~/Applications` 中 Codex / ChatGPT 桌面应用内置的 CLI。活动 hooks 另需本机 Python 3；iTerm 会话跳转需 iTerm 和系统自动化许可。

```bash
swift build
swift run UpkinCoreTests
./Scripts/build_app.sh
open "Upkin.app"
```

也可在仓库根目录执行 `swift run Upkin`。打包版只出现在菜单栏，不显示 Dock 图标。

当前构建仅做本机 ad-hoc 签名，没有 Developer ID 公证；还未提供正式 GitHub Release 安装包。

### 设置

点击会话面板右上角齿轮打开原生设置窗口，提供「连接」「角色」「通知」「关于」。不会在启动时弹出，也没有初始化步骤或活动配置项；连接状态显示真实查询结果，失败原因可悬停查看。「角色」只预览动作，不修改工具对应关系；“默认预览”返回默认角色，更多角色可横向滚动查看，切换页面或关闭窗口会停止并释放预览。

### 连接 Claude 额度

首次启动不读取 Claude 登录凭据，未授权时会话面板不显示 Claude 额度或连接按钮。进入「设置 → 连接」点击 Claude Code 的「连接」，会先配置本地活动 hooks，再显示额度用途说明；选择「授权并连接」后才读取凭据，macOS 可能显示钥匙串授权。后台及普通刷新不弹出钥匙串授权；已授权时可从「管理…」菜单重试连接。取消额度授权不影响已经配置的会话活动；「管理… → 断开」停止后续凭据读取、清除界面额度并尝试移除 Upkin hooks，即使连接失败也可操作。它不删除 Claude Code 的登录凭据，也不修改钥匙串访问控制；hooks 清理失败会显示错误，修复配置后可重试移除。

### 接入 Claude / Grok 活动

默认不安装 hooks。额度读取与 hooks 独立；细粒度活动需手动接入：

```bash
python3 Scripts/configure_agent_hooks.py           # 预览，不写配置
python3 Scripts/configure_agent_hooks.py --install # 确认后安装
```

安装会备份并修改 Claude / Grok 的 hook 配置。移动 app 或更换 Python 后需重新配置。具体副作用、撤销和旧版迁移见 [活动接入](grok-claude-activity.md)。

## 自定义角色

角色是 PNG 帧与 JSON 描述文件，不需要为每个角色修改播放器。将角色文件夹放入 `~/Library/Application Support/Upkin/Characters/`，重新打开「设置 → 角色」即可发现。完整格式、边界与开发期导出见 [角色资源包](character-packs.md)。

## 隐私与网络边界

- Codex 通过本地 app-server/RPC 和本地日志读取，不上传会话状态。
- Claude 额度复用已有 OAuth 登录，只向 Anthropic 的 usage 接口发送额度请求；Grok 通过已登录 CLI 查询账单，CLI 自行处理网络与认证。
- 本工具不发送提示词、回复或项目文件给这些额度接口，也不自动执行模型任务。原有 AI 服务仍可能按账号订阅或用量计费。
- 会话标题、项目路径与活动状态只在本机处理；凭据不写日志、不上传。动画不加载远程页面或脚本。
- 不自动安装 hooks、刷新 OAuth 令牌或改写 AI 工具配置。详细读取范围见 [技术说明](architecture.md)。


## 分发前

公开发布前见 [发布检查](releasing.md)。只打包许可允许再分发的角色；自用但不可再分发的角色请放在仓库外，见 [角色资源包 → 本机私有角色](character-packs.md#本机私有角色)。
