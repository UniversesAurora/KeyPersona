# KeyPersona

KeyPersona 在 Windows 上按窗口记住输入法。切回终端、浏览器、编辑器或资源管理器时，它会恢复该窗口上次使用的输入语言和中英文模式；没有记录时先使用匹配的用户规则，没有规则再使用全局默认值。

程序使用 AutoHotkey v2 和原生 Windows API，不依赖 Electron、WebView 或 Chromium。它常驻后台，通过托盘菜单管理设置，配置和学习状态保存在程序目录中。

## 运行要求

运行发布页提供的 `KeyPersona.exe` 只需要 64 位 Windows 10 或 Windows 11，以及一个当前用户可写的本地目录。EXE 已包含 AutoHotkey 运行时，用户不需要安装 AutoHotkey、PowerShell 7 或 Ahk2Exe。

直接运行 `.ahk` 源码时才需要 64 位 AutoHotkey v2。PowerShell 7 和 Ahk2Exe 只用于从源码构建 EXE，不是程序的运行依赖。

## 功能

- 按当前会话窗口独立记忆输入法，跨重启按可配置的窗口身份恢复。
- 支持全局默认输入法、当前窗口用户规则和应用用户规则。
- 用户规则只提供没有记忆时的默认输入法，不会锁定窗口，也不会阻止手动切换。
- 自动学习 Win+Space、语言栏和输入法内部中英文切换后的状态。
- 可以全局或按应用关闭自动记忆。
- 可以为指定应用启用强制保持。检测到实际输入源或已知中英文模式变化后，恢复该窗口的目标输入法。
- 区分同一语言下的 TSF 输入法、传统 IME 和键盘布局。
- 记忆兼容输入法的内部模式，例如中文、英文和日语输入法的开关。
- 自动发现新增输入法，并把可选择状态补充到运行时 `config.ini`。
- 自动清理重复或已经不可用的输入法状态、规则和学习记录。
- 监听窗口和输入焦点变化，在实际输入控件就绪后检查状态，只有发现差异才切换。
- 支持当前用户登录时自动启动。
- 中文输入模式下可以把符号转换成美式键盘对应的英文符号，每类符号可单独开关。
- 符号转换与括号、引号自动补齐都支持按应用覆盖全局设置，补齐后光标放在中间。

当前实际验证过：

- 英语（美国）- 美式键盘
- 微信输入法 2.1.4.6

其他键盘布局和输入法会自动发现。内部模式是否可读写取决于输入法版本和当前输入框。

## 安装与运行

从 [GitHub Releases](https://github.com/UniversesAurora/KeyPersona/releases/latest) 下载 ZIP 或单独的 `KeyPersona.exe`。把 EXE 放进可写目录后运行。程序会在同一目录创建 `config.ini`、`state.ini` 和日志。

ZIP 中的 `config.example.ini` 是默认配置示例。升级现有安装时不要用它覆盖自己的 `config.ini`。

已安装 AutoHotkey v2 时，也可以直接运行源码：

```text
.\KeyPersona.ahk
```

首次运行会在程序目录创建或使用：

- `config.ini`：用户配置、命名状态和用户规则。
- `state.ini`：程序自动学习的窗口状态。
- `state.ini.bak`：状态文件损坏恢复副本。
- `KeyPersona.log`：运行日志，达到约 1 MiB 时轮换并保留上一份。

升级自旧名 IME Memory 时，原有 `config.ini`、`state.ini`、日志和自启动入口会自动迁移；配置和记忆不会重置。

## 托盘菜单

- 启用自动切换
- 自动记忆输入法
- 开机自启动
- 当前窗口、输入法状态、状态来源和短 ID
- 开机自启动和始终以管理员身份运行
- 设置全局默认输入法
- 为当前窗口设置或取消默认输入法规则
- 当前应用输入法设置，包含关闭自动记忆和强制保持
- 中文符号转英文、逐项设置和当前应用符号设置
- 记忆管理，可打开状态文件、清除当前窗口或全部自动记忆
- 打开配置文件
- 重新加载
- 关于与退出

鼠标左键或右键单击托盘图标都可以打开菜单。

「全局默认输入法」和「当前窗口默认输入法」按语言分栏，例如「中文（简体，中国）」和「英语（美国）」。语言和输入法的名称来自 Windows。普通键盘可直接选择，带内部模式的输入法可展开。例如，微信输入法可选「中文」「英文」或「仅切换输入法」。如果某个输入框无法恢复内部模式，可以选「仅切换输入法」，内部模式由输入法自己决定。

“全局默认（无用户规则）”描述规则层：没有用户规则时保持勾选，重复点击不执行操作；取消已有规则不会清除自动记忆。“清除当前窗口的自动记忆”和“清除所有自动记忆”只删除学习记录，不删除用户规则、命名输入法或全局默认值。

自动记忆开启时，恢复顺序是：当前会话记忆、持久记忆、用户规则、全局默认。规则只在没有记忆时提供初始值；用户手动切换后，新状态会被学习，下次进入窗口时优先恢复学习结果。

关闭全局自动记忆，或在「当前应用输入法设置」中关闭某个应用的自动记忆后，对应窗口只使用匹配的用户规则。已有记忆会保留，恢复自动记忆后可继续使用。

「强制保持目标输入法」默认关闭。启用后，用当前窗口原本选出的目标继续恢复，优先使用记忆，然后是匹配的规则和可用的全局默认。关闭自动记忆时，匹配的规则可以继续作为强制目标。菜单会显示目标。强制期间，临时切走的输入法不会写入记忆。应用持续拒绝切换时，恢复尝试会逐渐减慢。

## 中文符号转英文

所有符号转换和自动补齐选项默认关闭。在托盘菜单“中文符号转英文”中打开“启用转换（全局）”，再逐项开启需要的“常用标点”“括号与引号”“其他符号”。也可以在“当前应用符号设置”中只为当前应用开启。覆盖美式键盘的 32 个符号按键，包括 `￥ → $`、`…… → ^`、`—— → _`、`、 → \`、`。 → .` 和 `《》 → <>`。已有明确保存的设置会保留。

转换发生在按键进入中文输入法之前，输出该键在美式键盘上的符号。因此省略号键输出 `^`，破折号键输出 `_`；不会把粘贴内容或已经写好的中文标点批量改掉。Ctrl、Alt、Win 组合键保留原有行为；Shift 用来选择大括号、双引号等符号。

圆括号、方括号、花括号、尖括号、单引号、双引号和反引号各有“自动补齐（全局）”选项。开启后，输入左括号会插入一对符号，并把光标移到中间；输入右括号只插入右括号。引号和反引号每次按下都会插入一对。补齐默认关闭，已经有自动补齐的编辑器可继续使用编辑器自己的功能。

“当前应用符号设置”包含转换开关、逐项符号转换和自动补齐，每项可选“跟随全局”“开启”或“关闭”。同一 exe 的所有窗口共用设置，应用设置优先于对应的全局设置。例如全局关闭，只为某个应用开启转换开关和所需符号，就只会在该应用转换；也可以全局转换某个符号，在指定应用关闭它。

转换与补齐分别保存，修改其中一项不会重置另一项。补齐生效时，该应用最终采用的转换开关和对应符号转换也必须开启。“全部跟随全局”会删除该应用的所有符号覆盖设置。所有修改立即生效并保存到 `config.ini`。

设置示例：

```ini
[punctuation]
enabled=1
convert.dollar=1
convert.caret=1
pair.parentheses=1
pair.doubleQuote=0

[punctuation-app.editor]
exe=Code.exe
enabled=1
convert.parentheses=1
pair.parentheses=0
pair.doubleQuote=0
```

旧配置存在 `backtickInChinese` 时会迁移到新配置，并删除旧键。没有旧配置时不执行迁移；已有的新设置会保留。

## 动态输入法状态

KeyPersona 在启动、打开托盘菜单以及遇到未知活动 profile 时重新枚举当前用户启用的输入法。

- 已存在相同“完整 profile ID + 内部模式”的状态时不会重复创建。
- 中文输入法提供「中文」「英文」，日语输入法提供「启用日文输入」「直接输入」。
- 每个输入源都有仅恢复输入法的选项。普通键盘布局直接选择。
- 同一实际状态出现多个名称时优先保留用户手写项，并更新引用它的规则。
- profile 不再可用时删除对应状态、用户规则和自动记忆。
- 全局默认失效时依次回退到有效中文状态、英语（美国）或任一有效状态。

自动生成的状态会写入运行时 `config.ini`，用户可以直接重命名或用于规则。

## 配置

自动记忆开关：

```ini
[general]
autoMemory=1
```

按 exe 名称设置应用的输入法行为，名称大小写均可。下面的应用只使用匹配的用户规则，并在有人切走时恢复到该规则的输入法。

```ini
[input-app.terminal]
exe=WindowsTerminal.exe
autoMemory=0
force=1
```

命名状态示例：

```ini
[state.wetype-chinese]
profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}
imeOpen=1
conversion=preserve
sentence=preserve
```

应用用户规则示例：

```ini
[rule.raycast]
enabled=1
priority=100
exe=Raycast.exe
state=english-us
```

规则还可以使用 `pathRegex`、`classRegex` 和 `titleRegex`。同一规则内填写的条件全部需要匹配。

规则决定窗口没有记忆时使用的输入法。以 Windows Terminal 的英语规则为例，首次进入时使用美式键盘，之后可以手动切到中文。启用该应用的强制保持后，程序才会在检测到变化时恢复选定的目标。

通过托盘建立的当前窗口规则保存在 `[window-rule.<短 ID>]`。Edge、Chrome、Firefox、Explorer 和 Zettlr 默认使用 `exe + class + 标准化标题` 作为跨重启身份，其他应用默认按 exe 共享状态。

## 开机自启动

“开机自启动”在当前用户的标准 Startup 文件夹创建 `KeyPersona.lnk`，不需要管理员权限。快捷方式动态保存当前 EXE 路径、参数和工作目录；移动程序后，从新位置重新勾选即可更新。

开启「始终以管理员身份运行」后，普通权限的实例会通过 Windows 授权重启。之后从普通权限入口手动打开时，也会请求管理员授权。若已开启开机自启，KeyPersona 会把登录入口换成当前用户的最高权限计划任务。关闭管理员选项后，下次手动启动按 Windows 默认权限运行，自启恢复为 Startup 快捷方式。

关闭开机自启时会删除对应入口。旧版 Run 注册项和 `IME Memory.lnk` 会在升级时迁移，避免重复启动。

## 从源码构建

### 构建环境与工具

- Windows 10 或 Windows 11（64 位）
- [PowerShell 7](https://learn.microsoft.com/powershell/)：运行 `build.ps1`
- [AutoHotkey v2](https://www.autohotkey.com/)（64 位）：运行源码自检，并作为编译基础运行时
- [官方 Ahk2Exe 编译器](https://github.com/AutoHotkey/Ahk2Exe/releases)：生成独立 EXE

项目没有需要另外下载的第三方代码库，也不使用包管理器。以上要求只用于开发和构建；最终用户只运行 EXE 时不需要安装这些工具。

在任意克隆目录运行：

```powershell
pwsh -NoProfile -File .\build.ps1
```

默认输出：

```text
dist\KeyPersona.exe
dist\config.ini
```

安装到指定目录：

```powershell
pwsh -NoProfile -File .\build.ps1 -InstallDirectory '<install-directory>'
```

AutoHotkey 运行时或 Ahk2Exe 不在标准位置时：

```powershell
pwsh -NoProfile -File .\build.ps1 `
  -RuntimePath '<path-to-AutoHotkey64.exe>' `
  -CompilerPath '<path-to-Ahk2Exe.exe>'
```

也可以使用环境变量 `KEYPERSONA_AHK_RUNTIME` 和 `KEYPERSONA_AHK_COMPILER`。构建脚本与仓库所在位置、安装目录无关。

也可以把 `Ahk2Exe.exe` 放进仓库根目录的 `build-tools`，构建脚本会自动发现。

生成发布 ZIP：

```powershell
pwsh -NoProfile -File .\build.ps1 -Package
```

构建默认执行源码自检、编译后自检和隔离烟雾测试。

## 已知边界

- 用户配置按设计保存在程序目录，因此程序必须位于当前用户可写的本地目录。
- 网络盘或移动盘在登录时尚未就绪会导致自启动失败。
- 普通权限进程可能无法向管理员权限窗口发送输入法消息。
- 浏览器没有向普通 Win32 程序暴露跨重启稳定窗口 ID；标题相同的浏览器窗口可能无法区分。
- 未签名发行包可能触发 Windows SmartScreen 或安全软件提示。

## 项目

- 架构说明：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 版本记录：[CHANGELOG.md](CHANGELOG.md)
- 发布流程：[docs/RELEASING.md](docs/RELEASING.md)
- 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md)
- 安全策略：[SECURITY.md](SECURITY.md)

KeyPersona 采用 [MIT License](LICENSE)。

作者：浮枕 [@universesaurora](https://github.com/UniversesAurora)
