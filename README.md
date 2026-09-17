# KeyPersona

KeyPersona 在 Windows 上按窗口记住输入法。切回终端、浏览器、编辑器或资源管理器时，它会恢复该窗口上次使用的输入语言和中英文模式；没有记录的窗口使用全局默认值。

程序使用 AutoHotkey v2 和原生 Windows API，不依赖 Electron、WebView 或 Chromium。它常驻后台，通过托盘菜单管理设置，配置和学习状态保存在程序目录中。

## 功能

- 按当前会话窗口独立记忆输入法，跨重启按可配置的窗口身份恢复。
- 支持全局默认输入法、当前窗口用户规则和应用用户规则。
- 自动学习 Win+Space、语言栏和输入法内部中英文切换后的状态。
- 使用 TSF profile 区分同一语言下的不同输入法。
- 对支持标准 IMM 接口的中文输入法记忆中文/英文内部模式。
- 自动发现新增输入法，并把可选择状态补充到运行时 `config.ini`。
- 自动清理重复或已经不可用的输入法状态、规则和学习记录。
- 前台切换后先等待 Windows 自己恢复输入法，仅在状态不符时补偿切换。
- 支持当前用户登录时自动启动。
- 可选把中文模式下单独按反引号键的输出修正为 `` ` ``，组合键保持原样。

当前实际验证过：

- 英语（美国）- 美式键盘
- 微信输入法 2.1.4.6

其他键盘布局和 TSF 输入法会自动发现；输入法内部模式能否读写取决于该输入法是否支持标准 IMM 接口。

## 安装与运行

KeyPersona 目前尚未发布正式版本。当前请从源码构建；构建产物位于 `dist`。将 `KeyPersona.exe` 和 `config.ini` 放进同一个可写目录，运行 `KeyPersona.exe`。编译版包含 AutoHotkey 运行时，目标机器不需要另行安装 AutoHotkey。

已安装 AutoHotkey v2 时，也可以直接运行源码：

```text
.\KeyPersona.ahk
```

首次运行会在程序目录创建或使用：

- `config.ini`：用户配置、命名状态和用户规则。
- `state.ini`：程序自动学习的窗口状态。
- `state.ini.bak`：状态文件损坏恢复副本。
- `KeyPersona.log`：运行日志。

升级自旧名 IME Memory 时，原有 `config.ini`、`state.ini`、日志和自启动入口会自动迁移；配置和记忆不会重置。

## 托盘菜单

- 启用自动切换
- 开机自启动
- 当前窗口、输入法状态、状态来源和短 ID
- 设置全局默认输入法
- 为当前窗口设置或取消用户规则
- 清除当前窗口的自动记忆
- 中文模式反引号修正
- 打开配置文件或状态文件
- 重新加载
- 关于与退出

鼠标左键或右键单击托盘图标都可以打开菜单。

“全局默认（无用户规则）”描述规则层：没有用户规则时保持勾选，重复点击不执行操作；取消已有规则不会清除自动记忆。“清除当前窗口的自动记忆”只删除学习记录，不删除用户规则。

## 动态输入法状态

KeyPersona 在启动、打开托盘菜单以及遇到未知活动 profile 时重新枚举当前用户启用的输入法。

- 已存在相同“完整 profile ID + 内部模式”的状态时不会重复创建。
- 中文 TIP 自动生成中文和英文两个命名状态。
- 其他输入布局生成一个命名状态。
- 同一实际状态出现多个名称时优先保留用户手写项，并更新引用它的规则。
- profile 不再可用时删除对应状态、用户规则和自动记忆。
- 全局默认失效时依次回退到有效中文状态、英语（美国）或任一有效状态。

自动生成的状态会写入运行时 `config.ini`，用户可以直接重命名或用于规则。

## 配置

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

通过托盘建立的当前窗口规则保存在 `[window-rule.<短 ID>]`。Edge、Chrome、Firefox、Explorer 和 Zettlr 默认使用 `exe + class + 标准化标题` 作为跨重启身份，其他应用默认按 exe 共享状态。

## 开机自启动

“开机自启动”在当前用户的标准 Startup 文件夹创建 `KeyPersona.lnk`，不需要管理员权限。快捷方式动态保存当前 EXE 路径、参数和工作目录；移动程序后，从新位置重新勾选即可更新。

关闭时会删除当前与旧版启动入口。旧版 Run 注册项和 `IME Memory.lnk` 会在升级时迁移，避免重复启动。

## 从源码构建

### 要求

- Windows 10 或 Windows 11（64 位）
- [PowerShell 7](https://learn.microsoft.com/powershell/)
- [AutoHotkey v2](https://www.autohotkey.com/)（64 位）
- [官方 Ahk2Exe 编译器](https://github.com/AutoHotkey/Ahk2Exe/releases)

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

依赖不在标准位置时：

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
