# IME Memory

一个使用 AutoHotkey v2 和原生 Windows API 实现的轻量输入法按窗口记忆工具。

当前版本针对本机的两种输入 profile 做过适配：

- English (United States) - US
- 微信输入法 2.1.4.5

它会监听前台窗口变化，恢复该窗口上一次使用的输入 profile 和可读写的 IME 内部中/英文状态，并将学习结果持久化到 `state.ini`。

## 运行

安装版位于：

```text
..\ime-memory.exe
```

源码位于：

```text
.
```

编译版包含 AutoHotkey 运行时，目标机器不需要另行安装 AutoHotkey。程序启动后只有托盘图标，没有主窗口。

## 构建

使用 PowerShell 7 从源码目录运行：

```powershell
pwsh -NoProfile -File .\build.ps1
```

构建脚本会执行源码自检，将独立 EXE 直接输出到 `..\ime-memory.exe`，再做一次只观察烟雾测试。如果安装版原本正在运行，会在构建时短暂停止并在成功或失败后重新启动。安装根目录已有的 `config.ini`、`state.ini` 和日志不会被覆盖。

日常修改只提交 commit，不自动发布新版本。正式发布历史见 [CHANGELOG.md](CHANGELOG.md)，发布步骤和约束见 [RELEASING.md](RELEASING.md)。

## 默认行为

- 未记录过的窗口使用 `wetype-chinese`，即微信输入法中文模式。
- Windows Terminal、经典 `powershell.exe` 和 Raycast 强制使用 English US。
- Edge、Chrome、Firefox、Explorer 和 Zettlr 使用 `exe + window class + 标准化标题` 作为跨重启身份。
- 其他应用默认按 exe 记忆。

运行时配置在 `..\config.ini` 中。源码目录里的 [config.ini](config.ini) 是首次安装时使用的默认模板。修改运行时配置后从托盘选择 `Reload`。

## 托盘菜单

- 启用/停用
- 查看当前窗口和输入法状态
- 把当前窗口设置为任一已定义状态
- 清除当前窗口记录
- 打开配置文件或状态文件
- Reload
- Exit

命中强制规则的窗口不能被“设置当前窗口为”覆盖；应修改对应 `[rule.*]`。

## 配置格式

命名状态：

```ini
[state.wetype-chinese]
profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}
imeOpen=1
conversion=preserve
sentence=preserve
```

强制规则：

```ini
[rule.raycast]
enabled=1
priority=100
exe=Raycast.exe
state=english-us
```

规则还可以使用 `pathRegex`、`classRegex` 和 `titleRegex`。同一规则内填写的条件全部需要匹配。

把某个 exe 加入 `[identity]` 的 `windowModeExe`，即可让同一应用的不同窗口分别记忆。否则按应用 exe 共享状态。

## 状态检测方式

- 输入 profile：目标焦点线程的 `GetKeyboardLayout`，结合 TSF active profile 和当前用户已启用的 profile 列表。
- IME 内部状态：`ImmGetDefaultIMEWnd` + `WM_IME_CONTROL`。
- 前台窗口：`SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`。
- 手动切换：窗口事件触发后的 250 ms 短时采样，稳定后降为 1000 ms。

程序主动恢复时会短暂暂停学习，回读验证后才重新接受用户状态，避免把自己的切换写回并形成循环。

恢复前会先比较完整状态。如果输入 profile 和需要恢复的 IME 中/英文状态已经符合目标，程序会直接跳过，不发送 `WM_INPUTLANGCHANGEREQUEST` 或 IME 设置消息。

## 诊断与测试

只读取当前环境并生成 `tools\ime-probe.txt`：

```powershell
& 'AutoHotkey64.exe' '.\tools\ime-probe.ahk'
```

静默自测：

```powershell
& 'AutoHotkey64.exe' '.\ime-memory.ahk' --self-test
# 或测试已编译版本
.\ime-memory.exe --self-test
```

测试结果写入 `self-test.log`。`--observe-only` 可以启动完整监听但禁止切换和学习，适合排查窗口识别。未处理异常会写入 `fatal-error.log` 后退出，不会反复弹出错误窗口。

## 已知边界

- 浏览器没有公开的跨重启永久窗口 ID。当前会话内能可靠区分 HWND；重启后使用标准化标题匹配。
- 普通权限进程可能无法向管理员窗口发送输入法消息。需要覆盖管理员应用时，可使用 AutoHotkey 安装目录中的 `AutoHotkey64_UIA.exe` 运行脚本；不建议无必要地让程序始终以管理员权限运行。
- 同一语言安装多个 TSF 输入法时，目标线程的 HKL 无法独自区分它们。程序会自动发现所有 profile，并优先使用 TSF active profile；若仍有歧义会写入日志。
- UAC 安全桌面、登录界面和安全输入控件不参与记忆。

更完整的设计和取舍见 [DESIGN.md](DESIGN.md)。
