# KeyPersona 架构说明

## 1. 技术选择和运行要求

KeyPersona 使用 AutoHotkey v2、Win32、TSF、IMM32 和 INI。程序没有 Electron、WebView、Chromium 或第三方运行库。

发布版 `KeyPersona.exe` 已包含 AutoHotkey 运行时。最终用户只需要 64 位 Windows 10 或 Windows 11，以及一个当前用户可写的本地目录；不需要安装 AutoHotkey、PowerShell 7 或 Ahk2Exe。

开发方式分三种：

- 直接运行源码：需要 64 位 AutoHotkey v2。
- 构建 EXE：需要 PowerShell 7、64 位 AutoHotkey v2 和官方 Ahk2Exe。
- 创建 GitHub Release：在构建工具之外还需要 Git 和 GitHub CLI。

PowerShell 7 只负责执行 `build.ps1`，不是程序运行时的一部分。

## 2. 运行流程

程序常驻后台，不创建主窗口。启动后依次完成：

1. 迁移旧名称留下的配置、状态、日志和自启动入口。
2. 读取或创建 `config.ini`。
3. 枚举当前用户启用的输入 profile，并对账命名状态、规则和自动记忆。
4. 读取 `state.ini`；文件损坏时尝试读取 `state.ini.bak`。
5. 安装 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` 并启动托盘菜单；自动记忆开启时再启动输入法状态采样。
6. 前台窗口变化时选择目标状态；实际状态已经符合目标时不发送切换消息。

核心恢复路径是：

```text
EVENT_SYSTEM_FOREGROUND
  → WinEvent 回调投递内部消息
  → 等待 foregroundSettleMs（默认 80 ms）
  → 再次确认前台窗口
  → 解析顶层宿主和焦点控件
  → 按自动记忆、用户规则、全局默认选择目标状态
  → 比较实际状态
  → 仅在不一致时切换并回读验证
```

WinEvent 回调不直接读写文件或切换输入法，避免回调重入和事件乱序。跨进程消息使用 `SendMessageTimeout`，目标窗口无响应时跳过，不让 KeyPersona 一直卡住。

## 3. 输入法状态模型

每条命名状态同时保存 profile 和可选的 IME 内部模式：

```ini
[state.wetype-chinese]
profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}
imeOpen=1
conversion=preserve
sentence=preserve
```

各字段的用途：

- `profile`：完整 TSF profile ID，或键盘布局的 `LANGID:KLID`。
- `imeOpen`：中文输入法的内部中文/英文开关；`1` 为中文，`0` 为英文，`unknown` 表示无法可靠读取。
- `conversion`、`sentence`：只有目标 IME 支持并能可靠读写时才使用；`preserve` 表示不改。
- `description`：托盘菜单显示名称。
- `generated=1`：该命名状态由自动发现创建。

profile 层负责区分 English US、微信输入法、微软拼音等输入源；`imeOpen` 再区分同一个中文输入法的中文和英文模式。内部模式不可读时，KeyPersona 仍可记忆和恢复 profile，不猜测，也不模拟输入法私有快捷键。

## 4. 窗口识别

### 4.1 顶层宿主

输入焦点可能位于子控件、浏览器渲染控件或 WebView2 内部。KeyPersona 使用顶层宿主保存窗口记忆：

1. 通过 `GetAncestor(..., GA_ROOT)` 找到顶层窗口。
2. 通过 `GetWindowThreadProcessId` 和 `QueryFullProcessImageName` 读取宿主进程路径与 exe 名。
3. 保存顶层 window class 和标准化标题。
4. 切换或读取输入法时，再用 `GetGUIThreadInfo` 找到当前焦点控件。

这个过程没有针对 Raycast 写特殊分支。只要顶层窗口属于 `Raycast.exe`，通用宿主识别就会得到 `Raycast.exe`；WebView2 子控件不会让整个窗口被识别成 `msedgewebview2.exe`。

### 4.2 会话内身份

程序运行期间始终按顶层 HWND 保存临时状态。同一应用的多个现存窗口可以独立记忆，即使它们跨重启使用的是应用级身份。

HWND 不写成永久主键。窗口关闭或 Windows 重启后，旧 HWND 没有可复用价值。

### 4.3 跨重启身份

跨重启只使用两种 identity mode：

- `app`：规范化后的 exe 文件名。默认模式，同一 exe 的多个窗口共享一条持久记忆。
- `window`：`exe + class + 标准化标题`。默认用于 Edge、Chrome、Firefox、Explorer 和 Zettlr。

`windowModeExe` 在 `config.ini` 的 `[identity]` 中配置。完整进程路径会作为状态元数据保存，也可以由应用规则的 `pathRegex` 匹配，但它不是默认持久身份的一部分。

应用规则不是第三种 identity mode。`[rule.*]` 可以组合 `exe`、`pathRegex`、`classRegex` 和 `titleRegex`；填写的条件必须全部匹配。

浏览器没有向普通 Win32 程序提供跨重启稳定的窗口 ID。标题相同的两个浏览器窗口在重启后可能无法区分，这是当前识别策略的边界。

### 4.4 忽略对象

程序自己的窗口、不可见窗口、桌面、任务栏、托盘溢出面板、输入法候选框和工具提示不参与记忆。任务栏和折叠托盘使用的 Explorer 窗口类会被忽略，真正的资源管理器 `CabinetWClass` 不受影响。

## 5. profile 发现、读取和切换

### 5.1 自动发现和清理

KeyPersona 在以下时机重新枚举当前用户启用的输入法：

- 程序启动时。
- 打开托盘菜单时。
- 观察到目录中不存在的活动 profile 时；重复刷新带冷却时间。

发现来源包括当前用户语言 profile 注册表和 TSF TIP 注册信息。程序只读取这些信息，不修改 Windows 的语言列表。

自动发现遵循以下规则：

- 中文 TIP 生成中文、英文两个命名状态；其他键盘布局生成一个状态。
- 唯一键是完整 profile ID 加规范化后的 `imeOpen`。
- 已存在同一实际状态时不重复创建。
- 用户手写状态优先于 `generated=1` 的自动状态；重复项删除后，规则会改指向保留项。
- profile 已不可用时，删除对应的命名状态、用户规则和自动记忆。
- 全局默认失效时，依次选择有效中文状态、English US、任一有效状态。
- 只有枚举成功且结果非空时才执行删除，避免临时读取失败误删配置。

### 5.2 读取

KeyPersona 先用 `GetKeyboardLayout` 读取前台线程的语言层，再尽量解析活动 TSF profile。HKL 不能独自区分同一语言下的多个 TSF 输入法，因此持久状态优先保存完整 profile ID。

对微信输入法和兼容 IME，内部模式通过 `ImmGetDefaultIMEWnd` 和 `WM_IME_CONTROL` 读取。在已验证的 Windows Terminal 场景中，`ImmGetContext` 可能返回空，而 default IME window 仍能读写 open status，因此实现不能只依赖 `ImmGetContext`。

### 5.3 恢复

恢复分两层：

1. 键盘布局使用 `LoadKeyboardLayout` 和 `WM_INPUTLANGCHANGEREQUEST`；TSF TIP 使用 `ITfInputProcessorProfileMgr::ActivateProfile` 激活完整 profile。
2. profile 已正确激活后，再对支持的 IME 使用 `IMC_SETOPENSTATUS`；conversion 和 sentence 只有在目标状态要求写入时才处理。

每一层都会先比较当前值。已经符合目标时不重复写入，也不会弹窗、抢焦点或模拟文本输入。

## 6. 前台事件和低频采样

前台窗口变化主要依靠 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`，不是高频轮询。

Windows 没有一个文档化广播能同时覆盖 Win+Space、语言栏点击、第三方输入法内部快捷键和所有 TSF 应用。自动记忆开启时，KeyPersona 因此保留一个低频 `SetTimer`：

- 前台窗口刚变化后的 burst 阶段默认每 250 ms 采样一次，持续 2 秒。
- 稳定后默认每 1000 ms 采样一次。
- 关闭自动记忆或关闭整个自动切换功能时停止定时器。
- 没有可识别的前台窗口时，定时器仍按当前周期触发，但本轮立即返回，不读写状态。

自动记忆关闭后不读取或写入会话记忆和 `state.ini`。前台窗口变化仍由 WinEvent 驱动，匹配的用户规则只在进入窗口时执行一次；没有规则的窗口保持当前输入法。

当前实现没有单独监听 Windows 会话锁定事件。锁屏或安全桌面没有可识别窗口时不会学习状态；自动记忆开启时，采样定时器本身不会因为 session lock 被显式关闭。

同一快照连续观察两次才学习；离开窗口时允许用最后一次有效读取立即收尾。快照包含 profile、`imeOpen`、conversion 和 sentence。

## 7. 避免把自动恢复当成用户操作

每次主动恢复都会记录目标状态、递增 `applyGeneration`，并为当前 HWND 设置 `suppressLearningUntil`。抑制期内不学习程序自己造成的瞬态变化。

恢复完成后会异步回读：

- 实际状态与目标一致：记为恢复成功，不写新的学习记录。
- 第一次不一致：最多补偿一次。
- 仍不一致：写日志并停止重试。
- 当前 profile 无法识别：不切换、不学习，等待后续重新发现或用户处理。

用户规则和全局默认属于一次性的初始选择，不进入持续强制逻辑。规则应用后的验证不会补偿重试；用户随后手动切换时，程序不会再把状态拉回规则值。自动记忆开启时，稳定后的手动状态会写入会话记忆和 `state.ini`，以后优先于规则。

## 8. 规则、记忆和优先级

自动记忆开启时，目标状态按以下顺序选择：

1. 当前会话的 HWND 自动记忆。
2. `state.ini` 中按持久 identity 找到的自动记忆。
3. `[window-rule.*]` 当前窗口用户规则。
4. 匹配的 `[rule.*]` 应用用户规则；多条匹配时取最高 `priority`。
5. 全局默认状态。

自动记忆关闭时只检查第 3、4 项；没有匹配规则就不切换。这样可以把 KeyPersona 当作“按应用给一个进入时默认值”的工具，同时保留窗口内自由切换。

当前窗口用户规则通过托盘创建，保存在 `config.ini`。它绑定当前窗口的持久 `identityKey`，不是 HWND：对 `app` 模式应用，它会覆盖同一 exe；对 `window` 模式应用，它会绑定 `exe + class + 标准化标题`。规则表示没有记忆时的默认值，不是输入法锁。

应用规则选择最高 `priority`。优先级相同时，配置文件中后出现的匹配规则生效。规则可以只按 exe 匹配，也可以用 `pathRegex` 区分同名 EXE 的不同安装路径。

通过托盘设置当前窗口默认输入法时，会清除该窗口已有的自动记忆，让新规则能够立即成为初始值。之后的手动切换仍可重新学习。

“全局默认（无用户规则）”只表示当前窗口没有用户规则。选择它会删除命中的当前窗口规则或应用规则，但不会删除自动记忆。“清除当前窗口的自动记忆”只清除该窗口的学习结果。“清除所有自动记忆”会清空会话记忆、`state.ini` 和 `state.ini.bak`，但保留 `config.ini` 中的规则、命名输入法和全局默认值。

## 9. 持久化格式

### 9.1 `config.ini`

`config.ini` 由用户维护，保存：

- 全局开关、自动记忆开关、默认状态、采样和超时参数。
- identity mode 列表和忽略规则。
- 命名输入法状态，包括自动生成项。
- `[rule.*]` 应用规则。
- `[window-rule.*]` 当前窗口规则。
- 中文模式反引号修正开关。

程序通过托盘修改配置时会直接写回该文件，重新加载后生效。

### 9.2 `state.ini`

`state.ini` 由程序维护，当前 `schemaVersion=2`。每条 `[window.<hash>]` 记录包含：

- `identityKey`、`mode`、exe、路径、class 和标准化标题。
- profile、`imeOpen`、conversion 和 sentence。
- `source`，当前自动学习记录使用 `learned`。
- `lastSeen`。

状态先在内存更新，默认 2 秒内的变化合并写盘。写盘时先生成同目录临时文件，再用 `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)` 原子替换；覆盖前保留 `state.ini.bak`。正常退出会强制 flush。

程序不保存用户输入内容，只保存窗口元数据和输入法状态。

## 10. 自启动和旧版本迁移

自启动使用当前用户标准 Startup 文件夹中的 `KeyPersona.lnk`，不需要管理员权限。

编译版快捷方式保存：

- target：当前 `KeyPersona.exe` 的完整路径。
- arguments：`--startup`。
- working directory：EXE 所在目录。

源码运行模式则以当前 AutoHotkey 解释器为 target，把脚本路径放进 arguments。菜单勾选状态会同时核对 target、arguments 和 working directory；程序移动后，从新位置重新勾选即可重建正确快捷方式。

升级旧名称时：

- `LegacyMigration.ahk` 在同一运行目录内迁移旧日志名，并更新配置、状态、备份和日志中的旧产品标识。
- `StartupManager.ahk` 把旧 Run 注册项或 `IME Memory.lnk` 迁移为 `KeyPersona.lnk`，然后删除旧入口，避免重复启动。
- 关闭自启动时会同时删除当前入口和残留旧入口。

## 11. 托盘和反引号处理

托盘菜单由 `TrayMenu.ahk` 管理，左键和右键单击都能打开。菜单显示当前窗口、当前输入法、状态来源、全局默认值和版本，并提供启用、自动记忆开关、窗口默认规则、清除当前或全部记忆、自启动、配置文件、关于、重新加载和退出等操作。

`BacktickKey.ahk` 只在以下条件同时满足时接管单独按下的 `SC029`：

- 用户打开“中文模式反引号修正”。
- 当前 profile 属于中文语言。
- 当前 IME 的 `imeOpen=1`。
- Ctrl、Alt、Win、Shift 都没有按下。

接管后直接发送 Unicode 反引号。组合键和非中文状态保持原样。

## 12. 代码和安装布局

源码仓库：

```text
KeyPersona/
├─ KeyPersona.ahk
├─ build.ps1
├─ config.ini                 # 默认配置模板
├─ README.md
├─ CHANGELOG.md
├─ CONTRIBUTING.md
├─ SECURITY.md
├─ LICENSE
├─ AGENTS.md
├─ assets/
│  ├─ KeyPersona.ico
│  └─ KeyPersona-icon.png
├─ docs/
│  ├─ ARCHITECTURE.md
│  ├─ RELEASING.md
│  └─ releases/
│     └─ v1.0.0.md
├─ lib/
│  ├─ AppInfo.ahk
│  ├─ LegacyMigration.ahk
│  ├─ App.ahk
│  ├─ Config.ahk
│  ├─ WindowIdentity.ahk
│  ├─ WinEventHook.ahk
│  ├─ InputProfiles.ahk
│  ├─ ImeMode.ahk
│  ├─ Rules.ahk
│  ├─ StateStore.ahk
│  ├─ StartupManager.ahk
│  ├─ TrayMenu.ahk
│  ├─ AboutDialog.ahk
│  ├─ BacktickKey.ahk
│  ├─ SelfTest.ahk
│  └─ Utils.ahk
└─ tools/
   └─ KeyPersona-probe.ahk
```

安装目录只需要 `KeyPersona.exe`。运行时会按需在同一目录创建或更新 `config.ini`、`state.ini`、`state.ini.bak` 和日志，因此该目录必须允许当前用户写入。

`AppInfo.ahk` 是产品名、文件名、作者、版本和编译元数据的单一来源。构建脚本从这里读取源码名、EXE 名、配置名、产品名和版本号，避免安装位置或仓库目录名写死在脚本中。

## 13. 构建、测试和发布包

`build.ps1` 与仓库和安装目录的绝对位置无关。默认流程：

1. 用 AutoHotkey v2 运行源码自检。
2. 用 Ahk2Exe 和指定的 64 位 AutoHotkey 运行时编译 `dist\KeyPersona.exe`。
3. 运行编译后自检。
4. 在临时目录执行 2 秒 observe-only 隔离烟雾测试。
5. 如果指定 `-InstallDirectory`，复制 EXE；构建前程序正在运行时，安装后重新启动。
6. 如果指定 `-Package`，生成版本化 ZIP 和 `SHA256SUMS.txt`。

构建脚本按“显式参数 → 环境变量 → 标准安装目录 → PATH”查找 AutoHotkey 运行时；Ahk2Exe 另外支持仓库根目录的 `build-tools`。发布 ZIP 包含 EXE、`config.example.ini`、README、CHANGELOG 和 LICENSE，不包含用户的运行时文件。

正式发布步骤见 `docs/RELEASING.md`。

## 14. 已知边界

- 第三方 IME 若不能可靠读写内部模式，只恢复完整 profile。
- 普通权限进程受 UIPI 限制，可能无法向管理员权限窗口发送输入法消息；不建议为此让 KeyPersona 长期以管理员权限运行。
- UAC 安全桌面、登录界面和密码安全控件不参与记忆。
- 同标题浏览器窗口跨重启时无法可靠区分。
- 用户配置按设计放在程序目录；只读目录、尚未挂载的网络盘或登录时未就绪的移动盘会影响保存和自启动。
- 发布文件没有数字签名，Windows SmartScreen 或安全软件可能显示提示。

## 15. 当前验证范围

实际验证环境使用 AutoHotkey `2.0.28` 64 位，输入 profile 包括：

- English US：`0409:00000409`。
- 微信输入法 2.1.4.6：`0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}`。

完整自检覆盖配置、规则优先级、自动记忆开关、清除全部记忆、动态 profile、重复与失效状态清理、旧名称迁移、状态原子写入和备份恢复。发布前还应人工验证 Alt+Tab、鼠标切换、Win+Tab、Win+Space、语言栏、输入法内部切换、自启动和重启恢复。
