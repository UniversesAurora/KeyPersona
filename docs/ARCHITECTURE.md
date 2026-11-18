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

1. 为配置目录取得独占运行锁，再迁移旧名称留下的配置、状态和日志。
2. 读取或创建 `config.ini`。
3. 枚举当前用户启用的输入 profile，并读取 `state.ini`。主文件缺失或损坏时读取备份。
4. 迁移自启动入口，核对输入源、命名状态、规则和自动记忆。
5. 分别订阅 `EVENT_SYSTEM_FOREGROUND` 和 `EVENT_OBJECT_FOCUS`，然后启动托盘菜单。
6. 前台窗口变化时选择目标状态；实际状态已经符合目标时不发送切换消息。

核心恢复路径是：

```text
EVENT_SYSTEM_FOREGROUND
  → 确认实际前台窗口，解析宿主并选择目标状态
  → 通过 EVENT_OBJECT_FOCUS 或一次性定时检查确认输入焦点
  → 读取当前输入源和内部模式
  → 有差异时只切换对应层，回读确认后结束
```

WinEvent 回调把消息交给应用线程。应用合并待处理的事件，以当时的前台窗口核对归属。稳定期间复用窗口信息。跨进程的 IME 模式读取使用 `SendMessageTimeout`，一次快照的多个查询共享同一个超时预算。

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

程序运行期间使用顶层 HWND 保存临时状态。同一窗口只在首次启用自动记忆时从磁盘取初始值。同一应用的另一个窗口更新共享磁盘记录后，已初始化窗口继续使用自己的记忆或规则。已关闭窗口的临时状态会定期清理。

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

使用 Windows 的 [EnumEnabledLayoutOrTip](https://learn.microsoft.com/windows/win32/tsf/enumenabledlayoutortip) 枚举当前用户的键盘布局和 TSF 输入法，筛掉禁用项，并通过当前用户的 `Keyboard Layout\Preload` 和 `Substitutes` 补充旧式 IME。Google Mozc 也使用这个接口读取 Windows 输入源。[Mozc 实现](https://github.com/google/mozc/blob/master/src/win32/base/uninstall_helper.cc)

输入法名称优先读取系统注册的本地化字符串，用 [SHLoadIndirectString](https://learn.microsoft.com/windows/win32/api/shlwapi/nf-shlwapi-shloadindirectstring) 解析资源引用。没有本地化名称时，TSF 输入法读取 [GetLanguageProfileDescription](https://learn.microsoft.com/windows/win32/api/msctf/nf-msctf-itfinputprocessorprofiles-getlanguageprofiledescription) 或注册描述，普通键盘布局和旧式 IME 读取布局描述。托盘菜单按输入源的语言 ID 从上到下分组，通过 Windows NLS 读取语言标题。规则和记忆使用输入源标识。

自动发现遵循以下规则：

- 中文 IME 生成中文、英文两个模式；日语 IME 生成开启、直接输入两个模式。每个输入源也有一个保留内部模式的状态，便于在不支持模式读写的输入框中使用。
- 以完整 profile ID 和规范化后的 `imeOpen`、`conversion`、`sentence` 判断两个状态是否等效。
- 已存在同一实际状态时不重复创建。
- 用户手写状态优先于 `generated=1` 的自动状态；重复项删除后，规则会改指向保留项。
- profile 已不可用时，删除对应的命名状态、用户规则和自动记忆。
- 全局默认失效时，依次选择有效中文状态、English US、任一有效状态。
- 首次发现已保存的 profile 缺失时，安排一次重新枚举。只有连续两次成功枚举确认输入源目录一致，才删除缺失项。枚举失败时沿用缓存，初次启动时回退到用户语言配置和预加载项。
- 新增状态、清理失效或重复项、更新规则引用和默认值，通过一次配置写入生效。写入失败时，在下次打开托盘或定时重试时重新枚举并处理。

### 5.2 读取

KeyPersona 用 `GetKeyboardLayout` 读取前台焦点线程的 HKL。旧式 IME 按准确的布局句柄匹配。TSF 输入法结合活动 profile、语言和替代布局判断。键盘布局与 TSF 证据冲突时返回未知。临时语言 ID 只在有可匹配的布局句柄时解析，持久化使用输入源的登记标识。持久化保存 TSF 完整标识或 `LANGID:KLID`。

对微信输入法和兼容 IME，内部模式通过 `ImmGetDefaultIMEWnd` 和 `WM_IME_CONTROL` 读取。普通采样主要读取开闭模式。日语输入法、显式配置转换或句子模式的输入源，以及正在观察这些已知模式的窗口，会额外读取模式标志。在已验证的 Windows Terminal 场景中，`ImmGetContext` 可能返回空，而 default IME window 仍能读写 open status，因此实现不能只依赖 `ImmGetContext`。

### 5.3 恢复

恢复分两层：

1. 键盘布局优先使用 `GetKeyboardLayoutList` 中可明确匹配的句柄，再使用 `LoadKeyboardLayout`。TSF TIP 先请求激活指定 profile。布局请求通过 `WM_INPUTLANGCHANGEREQUEST` 投递给当前焦点窗口，并等待回读确认。
2. 确认是目标 profile 后，再处理已有可靠读数的 IME 模式字段，例如 `IMC_SETOPENSTATUS`。conversion 和 sentence 由目标状态决定是否写入。

每一层都会先比较当前值。已经符合目标时不重复写入，也不会弹窗、抢焦点或模拟文本输入。

## 6. 前台事件和低频采样

`EVENT_SYSTEM_FOREGROUND` 确定使用哪个窗口的记忆和规则。有些窗口先获得前台，再变为可见。此时记录待就绪的窗口句柄、进程和线程，在同一窗口的 `EVENT_OBJECT_SHOW` 或 `EVENT_OBJECT_FOCUS` 到达时重新识别。启动阶段安排有限次数的复查。回读和写入仍以 Windows 当下的实际焦点句柄和线程为准。

自动记忆或强制保持生效时，通过 Windows Raw Input 接收按键通知。松开 Win+Space、Alt+Shift、Ctrl+Shift 或单独按下再松开 Shift 时，安排一次前台状态回读。如果切换还没完成，约 80 毫秒后再读一次。快捷键只是提示，程序按读到的输入状态判断变化，仍验证窗口、焦点和恢复状态。这个监听不拦截按键，不记录键值或输入内容。

语言栏点击、不同的 IME 快捷键，以及系统没有送到的通知由低频 `SetTimer` 兜底。

- 前台窗口刚变化后的 burst 阶段默认每 250 ms 采样一次，持续 2 秒。
- 稳定后默认每 1000 ms 采样一次。
- 强制保持有可用目标时，仅当前台是该应用才采用 `forcePollMs`，默认 100 ms。自动记忆与强制保持都未生效时停止采样。应用关闭自动切换后，仍可采样并记忆手动切换。
- 任务栏和输入法浮层处于前台时暂停状态采样。若中断了本次窗口的自动恢复，返回同一窗口后重新验证目标并继续。Windows 暂时没有前台窗口时安排短期复查。

按应用分别解析自动记忆和自动切换。应用有显式值时用该值，否则取全局值。自动记忆关闭时，目标选择和采样跳过该窗口的学习记录。前台窗口变化仍由 WinEvent 驱动，匹配的用户规则负责给出初始目标。强制保持启用时，同一个规则也可以作为持续保持的目标。

任务栏和输入法浮层短暂接管焦点后，返回同一应用时继续观察输入法。这样可以学习通过语言栏等方式造成的状态变化。锁屏和安全桌面期间只处理可确认的前台输入目标。

对已经识别的普通键盘布局，自动记忆和强制保持的定时检查都可只核对前台焦点与布局句柄。句柄、焦点、目标或输入源目录变化时重新识别。待确认的状态变化和同语言包含 IME 的情况也走完整检查。

一次读数共用同一个焦点目标。若读完后发现焦点或键盘布局已变，此次读数作废。焦点变化后的首次可靠读数用来建立基线。发现同一焦点内的状态变化后，约 60 毫秒后再确认一次。这样检测到变化后即可快速确认，同时保留低频常态采样。暂时读不到的内部模式保留上一次已知读数。

## 7. 避免把自动恢复当成用户操作

`InputRestoration.ahk` 管理一次进入窗口的恢复。`foregroundSettleMs`（默认 80 毫秒）后开始检查，也可由焦点通知提前触发。窗口已可见但还没有输入焦点时，等待首个有效焦点，短期复查结束后由焦点事件继续。宿主窗口已匹配时继续等待短暂的焦点交接。宿主已收到请求的情况下，如果激活期内焦点交给同一顶层窗口的输入控件，可以对该控件重新验证一次，仍有差异才发送请求。如果一直只有宿主并且状态已改变，保留实际状态。发出请求后，每次写入前再次核对恢复任务、焦点和布局。

恢复过程通过回读确认结果。

- 离开窗口、禁用自动切换或发起新恢复时，取消程序等待执行的后续动作。匹配的状态跳过写入，恢复完成后的控件焦点变化只用于观察。
- 以确认后的实际状态建立观察基线。检测到输入法切换快捷键时，如果同一控件出现与恢复请求不同的状态变化，就结束普通恢复，让该变化走正常的记忆确认流程。恢复失败或无法确认变化来源时，记录这次观察的基线，原有记忆继续保留。
- 恢复已有记忆时，目标仍在前台且实际状态没有出现其他变化，允许补偿一次。只有内部模式不符时只补偿内部模式。`applySuppressMs` 限制补偿的时间，恢复结束后即可继续采样。
- 当前 profile 无法识别时跳过切换和学习。同一语言有多个候选且无法确认当前输入源时，按未知状态处理。

普通用户规则和全局默认只在进入窗口时提供初始目标。强制保持由应用单独开启，复用同一套前台、焦点和回读校验。已知实际状态偏离目标时发起恢复，并跳过这次变化的自动学习。连续失败时逐渐拉长恢复间隔，成功确认后重新开始计数。

## 8. 规则、记忆和优先级

自动记忆开启时，目标状态按以下顺序选择：

1. 当前会话的 HWND 自动记忆。
2. 窗口首次启用记忆时，`state.ini` 中按持久 identity 找到的自动记忆。
3. `[window-rule.*]` 当前窗口用户规则。
4. 匹配的 `[rule.*]` 应用用户规则，按选择器的层级和 `priority` 决定。
5. 全局默认状态。

全局或应用的自动记忆关闭时只检查第 3、4 项。没有匹配规则时，该窗口没有自动切换或强制保持目标。已有记忆在重新开启后可继续使用。

`[input-app.*]` 按 exe 名称匹配，支持 `autoMemory=0`（关闭该应用的自动记忆）和 `force=1`（强制保持选定目标）。强制目标在进入窗口时从上述优先级取出，保持完整输入源和已知的中英文开闭模式。强制模式下保留 IME 的其他转换和句子标志。只有当前 profile 与目标相同且需要验证开闭模式时才查询 IME。快照中的未知字段不触发写入。

当前窗口用户规则通过托盘创建，保存在 `config.ini`。它绑定当前窗口的持久 `identityKey`，不是 HWND：对 `app` 模式应用，它会覆盖同一 exe；对 `window` 模式应用，它会绑定 `exe + class + 标准化标题`。规则表示没有记忆时的默认值，不是输入法锁。

应用规则选择最高 `priority`。优先级相同时，配置文件中后出现的匹配规则生效。规则可以只按 exe 匹配，也可以用 `pathRegex` 区分同名 EXE 的不同安装路径。

通过托盘设置当前窗口默认输入法时，会清除该窗口已有的自动记忆，让新规则能够立即成为初始值。之后的手动切换仍可重新学习。

托盘菜单关闭后，程序等待目标窗口重新成为前台，再立即应用刚选择的输入法。等待过程不会主动激活窗口；如果用户已经切到其他应用，则只保存规则，等目标窗口下次获得前台时应用。

「跟随应用规则」和「全局默认（无用户规则）」移除当前身份的覆盖。保留应用规则和自动记忆。菜单中的「使用全局默认」会创建 `state=@global` 覆盖，引用当前全局默认值。「清除当前窗口的自动记忆」移除该窗口的会话记忆和对应的持久记录。「清除所有自动记忆」重置全部会话记录和主、备状态文件。

清除记忆后，观察基线只留在内存。之后检测到的稳定状态变化才会写入 `state.ini`。托盘分别显示检测到的输入法和下次进入窗口时的目标。


清除记忆后，当前输入法只作为未持久化的观察基线：匹配用户规则时来源显示用户规则，匹配全局默认时显示全局默认，其他情况显示未记忆。观察基线不会写入 `state.ini`，也不会在下次进入窗口时覆盖用户规则；只有之后发生的稳定状态变化才会成为自动记忆。

## 9. 持久化格式

### 9.1 `config.ini`

`config.ini` 由用户维护，保存：

- 全局开关、自动记忆开关、默认状态、采样和超时参数。
- 按应用匹配的自动记忆、自动切换和强制保持设置。
- identity mode 列表和忽略规则。
- 命名输入法状态，包括自动生成项。
- `[rule.*]` 应用规则。
- `[window-rule.*]` 当前窗口规则。
- 符号转换总开关、逐项转换和全局/按应用自动补齐设置。

托盘更改以 UTF-8 保存一组设置，再原子替换配置文件。手动编辑文件后，从托盘重新加载。

### 9.2 `state.ini`

`state.ini` 由程序维护，当前 `schemaVersion=3`。主文件带记录数和完整性标记，旧版文件仍可读取。每条 `[window.<hash>]` 记录包含以下字段。

- `identityKey`、`mode` 和 exe。窗口模式还保存 class 和标准化标题。
- profile、`imeOpen`、conversion 和 sentence。
- `source`，当前自动学习记录使用 `learned`。
- `lastSeen`。

状态先在内存更新，默认 2 秒内的变化合并写盘。写盘时先生成同目录临时文件，再用 `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)` 原子替换；覆盖前保留 `state.ini.bak`。正常退出会强制 flush。

程序不保存用户输入内容，只保存窗口元数据和输入法状态。

## 10. 自启动和旧版本迁移

普通权限自启动使用当前用户 Startup 文件夹中的 `KeyPersona.lnk`。开启 `[general] runAsAdmin=1` 且启用自启动时，使用 Task Scheduler 的当前用户登录触发器、交互式用户令牌和最高运行级别。程序手动打开时用 Windows RunAs 请求同一账户授权，已有普通权限实例在确认子进程属于同一账户后退出，由子进程接管锁和配置。

编译版快捷方式保存：

- target：当前 `KeyPersona.exe` 的完整路径。
- arguments：`--startup`。
- working directory：EXE 所在目录。

源码运行模式则以当前 AutoHotkey 解释器为 target，把脚本路径放进 arguments。菜单勾选状态会同时核对 target、arguments 和 working directory；程序移动后，从新位置重新勾选即可重建正确快捷方式。

升级旧名称时：

- `LegacyMigration.ahk` 在同一运行目录内迁移旧日志名，并更新配置、状态、备份和日志中的旧产品标识。
- `StartupManager.ahk` 把旧 Run 注册项或 `IME Memory.lnk` 迁移为 `KeyPersona.lnk`，然后删除旧入口，避免重复启动。
- 关闭自启动时会同时删除当前入口和残留旧入口。

## 11. 托盘和符号处理

托盘菜单由 `TrayMenu.ahk` 管理，左右键单击均可打开。菜单打开时捕获操作对象，显示当前输入法、进入时使用的目标及来源。任务栏已接管焦点时，可用同一窗口的最近读数。应用仍在启动时，菜单短暂等待其就绪，避免把启动中的窗口当成桌面。窗口操作绑定到该对象，执行时确认窗口仍有效。符号设置子菜单按应用和配置版本复用。

`Punctuation.ahk` 定义 28 组转换设置，覆盖美式键盘的 32 个符号按键。按需启用 scan code 热键及其 Shift 变体。判断时复用当前窗口身份，只做短时 IME 查询，不触发输入法目录刷新。发送前再验证焦点和布局。按键接管要求满足以下条件。

- 用户打开符号转换总开关和该类符号的转换开关。符号转换与自动切换各自生效。
- 当前 profile 属于中文语言。
- 当前 IME 的 `imeOpen=1`。
- Ctrl、Alt、Win 都没有按下；Shift 用来区分符号变体。

转换条件中的总开关和逐项转换先解析应用覆盖，再取全局默认。每次符合条件的按键会发送对应的 Unicode ASCII 字符。关闭中文模式或无法识别状态时放行原按键，不改输入源，不修改剪贴板或已有文本。输出使用一次 `SendInput`，补齐时同时发送两个字符和向左移动一次，避免 Shift 使光标移动变成选区。

`[punctuation]` 保存 `enabled`、`convert.<id>` 和 `pair.<id>`。总开关、每类转换和自动补齐都默认关闭，已有显式设置优先。旧 `[typing] backtickInChinese` 仅在存在时迁移为新总开关和 `convert.backtick`，删除旧键；已有新配置优先，不保留旧配置回退路径。

`[punctuation-app.<名称>]` 使用 `exe` 匹配应用，支持 `enabled`、`convert.<id>` 和 `pair.<id>`。值 `1/0` 分别表示该应用开启/关闭，缺少该键或值为 `inherit` 时使用对应的全局值。应用可以在全局关闭时显式开启转换，也可以关闭全局开启的单项转换。转换和补齐相互独立，修改或取消某项覆盖时保留其他覆盖；最后一项覆盖删除后移除空段。菜单“全部跟随全局”删除整个应用配置段。补齐仍需最终解析的总开关和逐项转换均开启。

补齐支持圆括号、方括号、花括号、尖括号、单引号、双引号和反引号；左括号触发成对插入，右括号只输出本身。同字符引号每次按下均插入一对，不追踪文档或跳过已有右符号。编辑器已有补齐时可用应用覆盖关闭 KeyPersona 的补齐。

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
│  ├─ GitHub-Invertocat.ico
│  ├─ KeyPersona.ico
│  └─ KeyPersona-icon.png
├─ docs/
│  ├─ ARCHITECTURE.md
│  ├─ RELEASING.md
│  └─ releases/
│     ├─ v1.0.0.md
│     ├─ v1.1.0.md
│     ├─ v1.1.1.md
│     ├─ v1.2.0.md
│     └─ v1.3.0.md
├─ lib/
│  ├─ AppInfo.ahk
│  ├─ LegacyMigration.ahk
│  ├─ App.ahk
│  ├─ Config.ahk
│  ├─ WindowIdentity.ahk
│  ├─ WinEventHook.ahk
│  ├─ InputProfiles.ahk
│  ├─ InputRestoration.ahk
│  ├─ InputEnforcement.ahk
│  ├─ InputChangeKeys.ahk
│  ├─ ImeMode.ahk
│  ├─ Rules.ahk
│  ├─ StateStore.ahk
│  ├─ StartupManager.ahk
│  ├─ ElevationManager.ahk
│  ├─ TrayMenu.ahk
│  ├─ AboutDialog.ahk
│  ├─ Punctuation.ahk
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
4. 在临时目录执行 2 秒 observe-only 启动测试。测试只读取输入状态，不迁移自启动、不启用符号热键，配置和记忆用测试目录。
5. 如果指定 `-InstallDirectory`，复制 EXE；构建前程序正在运行时，安装后重新启动。
6. 如果指定 `-Package`，生成版本化 ZIP 和 `SHA256SUMS.txt`。

构建脚本按“显式参数 → 环境变量 → 标准安装目录 → PATH”查找 AutoHotkey 运行时；Ahk2Exe 另外支持仓库根目录的 `build-tools`。发布 ZIP 包含 EXE、`config.example.ini`、README、CHANGELOG 和 LICENSE，不包含用户的运行时文件。

正式发布步骤见 `docs/RELEASING.md`。

## 14. 已知边界

- 第三方 IME 若不能可靠读写内部模式，只恢复完整 profile。
- 普通权限进程受 UIPI 限制，可能无法向管理员权限窗口发送输入法消息。可在托盘启用始终以管理员身份运行，实际切换仍取决于目标应用和输入法。
- UAC 安全桌面、登录界面和密码安全控件不参与记忆。
- 同标题浏览器窗口跨重启时无法可靠区分。
- 用户配置按设计放在程序目录；只读目录、尚未挂载的网络盘或登录时未就绪的移动盘会影响保存和自启动。
- 发布文件没有数字签名，Windows SmartScreen 或安全软件可能显示提示。

## 15. 当前验证范围

实际验证环境使用 AutoHotkey `2.0.31` 64 位，输入 profile 包括：

- English US：`0409:00000409`。
- 微信输入法 2.1.4.6：`0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}`。

完整自检覆盖配置、规则优先级、自动记忆开关、清除全部记忆、动态 profile、重复与失效状态清理、旧名称迁移、状态原子写入和备份恢复。发布前还应人工验证 Alt+Tab、鼠标切换、Win+Tab、Win+Space、语言栏、输入法内部切换、自启动和重启恢复。
