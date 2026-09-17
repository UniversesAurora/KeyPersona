# IME Memory

一个使用 AutoHotkey v2 和原生 Windows API 实现的轻量输入法按窗口记忆工具。

当前版本已实际验证以下两种输入 profile：

- 英语（美国）- 美式键盘
- 微信输入法 2.1.4.6

它会监听前台窗口变化，恢复该窗口上一次使用的输入 profile 和可读写的 IME 内部中/英文状态，并将学习结果持久化到 `state.ini`。

启用的输入 profile 会在启动、打开托盘菜单以及遇到未知活动 profile 时重新枚举。新发现的中文 TIP 会自动在运行时 `config.ini` 增加中文和英文两个命名状态；其他输入布局增加一个命名状态。自动生成只补充缺失项，不覆盖用户已有状态、名称和规则。

同步时以“完整 profile ID + IME 中文/英文模式”为唯一键：已有用户状态优先，不会因为名称不同重复创建同一状态。系统中已不可用的 profile 会从命名状态和自动记忆中移除；引用它的应用规则/窗口规则也会删除，使窗口回到无用户规则状态。失效的全局默认会自动改为仍有效的中文状态，其次英语，再其次任一有效状态。

## 运行

直接运行源码：

```text
.\ime-memory.ahk
```

构建后的独立程序位于源码目录的上一级：

```text
..\ime-memory.exe
```

编译版包含 AutoHotkey 运行时，目标机器不需要另行安装 AutoHotkey。程序启动后只有托盘图标，没有主窗口。

## 构建

使用 PowerShell 7 从源码目录运行：

```powershell
pwsh -NoProfile -File .\build.ps1
```

源码仓库应位于安装根目录的 `src` 子目录，官方 `Ahk2Exe.exe` 放在同级的 `build-tools` 目录。构建脚本会执行源码自检，将独立 EXE 输出到 `..\ime-memory.exe`，再做一次只观察烟雾测试。如果安装版原本正在运行，会在构建时短暂停止并在成功或失败后重新启动。安装根目录已有的 `config.ini`、`state.ini` 和日志不会被覆盖。

构建脚本会从系统安装目录或 `PATH` 查找 AutoHotkey v2。也可以用环境变量 `IME_MEMORY_AHK_RUNTIME` 指定本机运行时位置；该本地设置不需要写入仓库。

日常修改只提交 commit，不自动发布新版本。正式发布历史见 [CHANGELOG.md](CHANGELOG.md)，发布步骤和约束见 [RELEASING.md](RELEASING.md)。

产品名称、程序文件名、配置文件名、图标、作者和启动项名称集中在 `lib/AppInfo.ahk`。改名时优先修改这一处；构建脚本也从这里读取源码与输出文件名。

## 默认行为

- 未记录过的窗口使用 `wetype-chinese`，即微信输入法中文模式。
- Windows Terminal、经典 `powershell.exe` 和 Raycast 通过用户规则使用英语（美国）。
- Edge、Chrome、Firefox、Explorer 和 Zettlr 使用 `exe + window class + 标准化标题` 作为跨重启身份。
- 其他应用默认按 exe 记忆。

运行时配置位于 `..\config.ini`。源码目录里的 [config.ini](config.ini) 是首次安装时使用的默认模板。修改运行时配置后从托盘选择“重新加载”。

## 托盘菜单

- 启用/停用
- 开启或关闭当前用户的开机自启动
- 查看当前窗口、输入法状态、状态来源和短 ID
- 设置全局默认输入法
- 为当前窗口设置或取消用户规则
- 清除当前窗口的自动记忆
- 打开配置文件或状态文件
- 可选开启“中文模式下反引号键输出反引号”
- 重新加载
- 查看带程序图标和版本号的“关于”窗口
- 退出

托盘图标支持鼠标左键或右键单击打开菜单。

状态来源会明确显示为“用户规则”“自动记忆”或“全局默认”。菜单里的应用/窗口 ID 是持久身份键的短哈希，便于和 `state.ini` 对照，但不会暴露完整路径或标题。

“设置当前窗口为”子菜单显示当前用户规则对应的勾选项；选择其他输入法会建立当前窗口规则。没有用户规则时勾选“全局默认（无用户规则）”，再次点击不执行任何操作。已有规则时选择它只移除规则，保留自动记忆，随后恢复“自动记忆 → 全局默认”的正常优先级。

“清除当前窗口的自动记忆”只删除学习记录，不删除用户规则。这与取消规则是两个独立操作。

## 开机自启动

托盘中的“开机自启动”会在 Windows 当前用户的标准“启动”文件夹创建 `IME Memory.lnk`，不需要管理员权限。启用后，程序会在该用户每次登录 Windows 时启动；关闭时会删除快捷方式。旧版 `Run` 注册项会自动迁移并删除，避免形成重复启动入口。程序移动到其他目录后，重新切换一次该选项即可更新快捷方式。

自启动只保存程序启动命令，不保存窗口状态、输入法记录或其他用户数据。

## 配置格式

命名状态：

```ini
[state.wetype-chinese]
profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}
imeOpen=1
conversion=preserve
sentence=preserve
```

用户规则：

```ini
[rule.raycast]
enabled=1
priority=100
exe=Raycast.exe
state=english-us
```

规则还可以使用 `pathRegex`、`classRegex` 和 `titleRegex`。同一规则内填写的条件全部需要匹配。

通过托盘为当前窗口建立的规则会保存到运行时 `config.ini` 的 `[window-rule.<短 ID>]`，按该窗口现有的持久身份匹配，用户可以直接编辑；源码仓库里的 `config.ini` 仍只是默认模板。

把某个 exe 加入 `[identity]` 的 `windowModeExe`，即可让同一应用的不同窗口分别记忆。否则按应用 exe 共享状态。

反引号修正默认关闭，也可以直接配置：

```ini
[typing]
backtickInChinese=1
```

开启后，仅当当前输入语言属于中文且 IME 处于中文模式时，单独按物理反引号键才会直接发送一个 Unicode `` ` ``。Ctrl、Alt、Win、Shift 与该键组成的组合键完全保留原行为；实现不会先输入 `·` 再删除。

## 状态检测方式

- 输入 profile：目标焦点线程的 `GetKeyboardLayout`，结合 TSF active profile 和当前用户已启用的 profile 列表。
- IME 内部状态：`ImmGetDefaultIMEWnd` + `WM_IME_CONTROL`。
- 前台窗口：`SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`；事件发生后默认等待 80 ms，让 Windows 先完成自己的输入法恢复，再回读并仅在不一致时补偿。
- 手动切换：窗口事件触发后的 250 ms 短时采样，稳定后降为 1000 ms。

程序主动恢复时会短暂暂停学习，回读验证后才重新接受用户状态，避免把自己的切换写回并形成循环。

恢复前会先比较完整状态。如果输入 profile 和需要恢复的 IME 中/英文状态已经符合目标，程序会直接跳过，不发送 `WM_INPUTLANGCHANGEREQUEST` 或 IME 设置消息。

## 诊断与测试

只读取当前环境并生成 `tools\ime-probe.txt`：

```powershell
& AutoHotkey64.exe '.\tools\ime-probe.ahk'
```

静默自测：

```powershell
& AutoHotkey64.exe '.\ime-memory.ahk' --self-test
# 或测试已编译版本
..\ime-memory.exe --self-test
```

测试结果写入 `self-test.log`。`--observe-only` 可以启动完整监听但禁止切换和学习，适合排查窗口识别。未处理异常会写入 `fatal-error.log` 后退出，不会反复弹出错误窗口。

## 已知边界

- 浏览器没有公开的跨重启永久窗口 ID。当前会话内能可靠区分 HWND；重启后使用标准化标题匹配。
- 普通权限进程可能无法向管理员窗口发送输入法消息。需要覆盖管理员应用时，可使用 AutoHotkey 安装目录中的 `AutoHotkey64_UIA.exe` 运行脚本；不建议无必要地让程序始终以管理员权限运行。
- 同一语言安装多个 TSF 输入法时，目标线程的 HKL 无法独自区分它们。程序会自动发现所有 profile，并优先使用 TSF active profile；若仍有歧义会写入日志。
- UAC 安全桌面、登录界面和安全输入控件不参与记忆。
- 托盘、托盘溢出面板和副屏任务栏属于 Windows Shell 表面，会被忽略；打开折叠托盘后，菜单仍操作此前最后一个有效应用窗口。

更完整的设计和取舍见 [DESIGN.md](DESIGN.md)。
