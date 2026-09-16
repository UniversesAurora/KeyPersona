# IME Memory：Windows 输入法按窗口记忆工具设计

## 1. 设计结论

采用 **AutoHotkey v2 + Win32/TSF/IMM32 API + INI**，不使用 Electron、WebView 或 Chromium 运行时。

程序主体是一个无界面的 AutoHotkey 常驻脚本：

- 用 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` 监听前台窗口变化。
- 前台切换后用 `GetGUIThreadInfo` 找到同一窗口内的真实焦点控件，但窗口记忆仍归属于顶层窗口。
- 用 `GetKeyboardLayout` 读取输入语言层。
- 对微信输入法和兼容 IME，优先通过 `ImmGetDefaultIMEWnd` + `WM_IME_CONTROL` 读取和恢复内部中/英文状态。
- 通过 TSF profile 标识保存具体输入法；HKL 只作为语言层和兼容路径，不能独自区分同一语言下的多个 TSF 输入法。
- 用事件驱动加低频、可自适应采样检测用户手动切换，避免几十毫秒一次的高频轮询。
- 配置和学习状态分别写入 `config.ini` 与 `state.ini`；机器状态采用临时文件加原子替换，避免异常退出留下半个文件。

验证环境：

- AutoHotkey `2.0.28` 64 位运行时。
- 当前启用的输入 profile 只有 English US 与微信输入法。
- English US：`0409:00000409`。
- 微信输入法 2.1.4.5：`0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}`。
- 微信输入法的 TSF/TIP 模块已启用。
- 在 Windows Terminal 的实际测试中，`ImmGetContext` 为空，但 `ImmGetDefaultIMEWnd` + `WM_IME_CONTROL` 可以读取 IME 开关和 conversion mode。因此不能只实现常见的 `ImmGetContext` 方案。

## 2. 状态模型

每条状态同时保存 profile 和可选的 IME 内部状态：

```ini
[state.wetype-cn]
profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}
imeOpen=1
conversion=preserve
sentence=preserve

[state.wetype-en]
profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}
imeOpen=0
conversion=preserve
sentence=preserve

[state.english-us]
profile=0409:00000409
imeOpen=unknown
conversion=preserve
sentence=preserve
```

`imeOpen` 是区分“同一个中文输入法的中文/英文模式”的首要字段。`conversionMode` 与 `sentenceMode` 只在目标 IME 确实支持、并且读写回测成功时才恢复；不支持时保存为 `unknown`，避免向第三方输入法写入它不理解的标志。

这里把需求中的“微软拼音中文/英文”推广为“任意支持可观测开关状态的 IME”。将来安装微软拼音后沿用同一状态模型，不需要重写窗口记忆层。

## 3. 窗口识别

### 3.1 运行时身份

运行期间用 HWND 维护临时映射，以保证同一程序的多个现存窗口绝对分开。HWND 不写成永久主键。

焦点可能落在 WebView2、浏览器渲染控件或子控件上。识别时按以下顺序回到真正宿主：

1. `GetGUIThreadInfo` 取得真实 `hwndFocus`。
2. `GetAncestor(..., GA_ROOT)` / `GA_ROOTOWNER` 取得顶层宿主。
3. 以顶层宿主的 PID 调用 `QueryFullProcessImageName`，取完整路径和 exe 名。
4. 同时保存顶层 window class、标准化后的标题及可选 AUMID/package 信息。

因此不会看到一个 WebView2 子控件就把窗口认成 `msedgewebview2.exe`。本机 Raycast 的实际顶层进程就是 `Raycast.exe`，窗口类为 `HwndWrapper[Raycast;Main;...]`，强制规则直接写 `Raycast.exe` 即可。

### 3.2 持久身份

采用可配置的 identity policy：

- `app`：只按规范化 exe 路径/文件名。默认策略，稳定且简单。
- `window`：`exe + class + 标准化标题`。用于 Edge、Chrome 等需要多窗口分别记忆的程序。
- `rule`：用户提供 title/class 正则，把经常变化的标题归到稳定标签。

会话内始终按 HWND 区分；identity policy 只决定重启后怎样找回记录。

浏览器没有向普通 Win32 程序暴露“跨重启不变的浏览器窗口 ID”。所以对 Edge/Chrome：

- 当前会话内可以可靠区分每个窗口，即使标签页标题改变。
- 重启后的最佳无扩展方案是 `exe + class + 标准化标题/用户规则`。
- 若两个浏览器窗口重启后标题完全相同，无法保证映射到原来的那个窗口；这是 Win32 可见信息的边界，不应假装能可靠识别。

Explorer 后续可增加专用 identity provider，用 Shell COM 读取文件夹路径，比窗口标题更稳定；基础版本仍可先用 class + 标题。

### 3.3 忽略对象

默认忽略程序自己的窗口、桌面、任务切换器、输入法候选框、工具提示、无宿主的临时菜单，以及不应被记忆的系统安全桌面。

## 4. 前台窗口监听

主路径：

```text
EVENT_SYSTEM_FOREGROUND
  → WinEvent 回调只投递内部消息
  → 10–30 ms 后重新读取 GetForegroundWindow
  → 解析宿主身份
  → 按优先级选择目标状态
  → 恢复并异步验证
```

使用 `WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS`，不向其他进程注入 DLL。AutoHotkey 自带消息循环可以接收回调。

回调中不直接读写文件，也不直接切换输入法，以避免 WinEvent 重入和事件乱序。回调仅使用 `PostMessage` 或一次性短 `SetTimer` 把工作放回脚本主线程。

切换和采样时会通过 `GetGUIThreadInfo` 重新获取当前焦点控件，因此不会把一个窗口内的不同文本框误当成不同“窗口记录”。

## 5. profile 读取与切换

### 5.1 自动发现

启动时枚举：

- `HKCU\Control Panel\International\User Profile\<language>` 中当前用户启用的 TIP/KLID。
- `HKLM\SOFTWARE\Microsoft\CTF\TIP\<CLSID>\LanguageProfile\<LANGID>\<profile GUID>` 中的说明和能力信息。

注册表只用于发现，不直接修改用户的系统语言配置。

### 5.2 读取

读取当前前台线程的 `GetKeyboardLayout(threadId)`，并用 TSF active profile 信息尽量解析为完整 profile。当前只有一个中文 TIP 时，`0x0804` 可以无歧义映射到微信输入法；将来同语言有多个 TIP 时必须以完整 TSF profile 为准。

### 5.3 恢复

恢复分两层：

1. profile 层：
   - 普通 keyboard layout 用 `LoadKeyboardLayout` + 向焦点窗口发送 `WM_INPUTLANGCHANGEREQUEST`。
   - TSF TIP 用 `ITfInputProcessorProfileMgr::ActivateProfile` 激活完整 CLSID/profile GUID，再向当前焦点线程请求对应输入语言，随后回读验证。
2. IME 内部模式层：
   - 找到焦点控件对应的 default IME window。
   - 使用 `WM_IME_CONTROL / IMC_SETOPENSTATUS`。
   - 只有能力探测确认支持时，才写 `IMC_SETCONVERSIONMODE` 与 `IMC_SETSENTENCEMODE`。

所有跨进程消息使用 `SendMessageTimeout`，设置很短的超时，避免某个卡死窗口拖住整个工具。切换后不弹窗、不激活其他窗口、不模拟文本输入。

## 6. 用户手动切换检测

没有一个文档化的 Win32 广播能同时覆盖 Win+Space、语言栏点击、第三方 IME 自己的 Shift 切换和所有 TSF 应用。因此采用组合方案：

1. 前台窗口事件到达时立即进入短时采样。
2. 低频兜底采样覆盖 Win+Space、语言栏点击和第三方 IME 自己的 Shift 切换，不注册或吞掉任何热键：
   - 前台或焦点刚变化后的短时间窗口内约 250 ms。
   - 稳定后约 1000 ms。
   - 会话锁定、无有效前台窗口或工具 Disable 时停止采样。
3. profile、IME open、conversion 三者形成快照；连续两次一致才认为是新的用户状态。

这种方式的常驻开销主要是几次很小的 Win32 查询，不需要 10–50 ms 的高频 `SetTimer`。

## 7. 防止自动切换被当成用户学习

状态机维护以下字段：

- `applyGeneration`：每次程序主动恢复都递增。
- `desiredState`：本次准备恢复的状态。
- `suppressLearningUntil`：短暂抑制学习的截止时间。
- `lastObservedState` / `stableCount`：采样防抖。

主动恢复流程：

```text
进入窗口
  → 决定 desiredState
  → 开启 learning suppression
  → 写 profile
  → 写 IME 内部模式
  → 回读验证（最多补偿一次）
  → 等待状态稳定
  → 结束 suppression
```

抑制期内：

- 与 `desiredState` 相同的变化只算应用成功，不写学习记录。
- 不同的瞬态变化先忽略，超时后仍不一致才作为失败记录到日志。
- 强制规则窗口永远不自动学习；如果用户手动改掉，下一次采样会恢复强制状态。

正常观察期内只有稳定状态变化才写入当前窗口记录，并延迟合并写盘。

## 8. 规则和优先级

最终优先级：

1. 第一条匹配的强制规则。
2. 当前会话 HWND 记录。
3. 按持久 identity 找到的记录。
4. 全局默认状态。

规则的 `exe`、完整路径、class、title regex 等已填写字段采用 AND；规则之间按显式 `priority` 和文件顺序匹配。

建议初始规则：

```ini
[rule.windows-terminal]
enabled=1
priority=100
exe=WindowsTerminal.exe
state=english-us

[rule.classic-powershell]
enabled=1
priority=100
exe=powershell.exe
state=english-us

[rule.raycast]
enabled=1
priority=100
exe=Raycast.exe
state=english-us
```

注意：PowerShell 运行在 Windows Terminal 标签页里时，顶层窗口进程仍是 `WindowsTerminal.exe`，不能根据终端内部 shell 的 `powershell.exe` 区分；Windows Terminal 规则已经覆盖这种情况。经典独立控制台才会匹配 `powershell.exe`。

## 9. 持久化

使用两个 INI：

- `config.ini`：用户可编辑，保存默认状态、规则、identity policy、采样间隔、日志级别。
- `state.ini`：程序管理，保存窗口身份、状态、最后见到时间和 schema version。

选择 INI 的理由：AutoHotkey v2 原生支持，用户可读，不需要内置 JSON 解析器，能减少代码和常驻开销。

状态写盘策略：

- 内存中先更新；约 2 秒 debounce 合并多次变化。
- 写到同目录临时文件，flush 后用 `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)` 原子替换。
- 正常退出前强制 flush。
- 保留一个 `.bak`，schema 升级时可以恢复。
- 不保存用户输入内容，只保存窗口元数据和输入法状态。

## 10. 托盘菜单

最低菜单项：

- Enable / Disable
- 当前窗口：exe、身份模式、已观察状态、命中的规则
- 设置当前窗口为 English US
- 设置当前窗口为微信输入法（中文）
- 设置当前窗口为微信输入法（英文）
- 清除当前窗口记录
- 打开配置文件
- 打开状态文件
- Reload
- Exit

菜单操作后立即刷新当前窗口，但不会抢焦点或弹出常驻窗口。

## 11. 模块划分

```text
ime-memory/
├─ ime-memory.ahk          # 入口、生命周期
├─ config.ini              # 用户配置
├─ state.ini               # 自动生成
├─ lib/
│  ├─ App.ahk              # 协调状态机
│  ├─ WinEventHook.ahk     # foreground/focus 事件
│  ├─ WindowIdentity.ahk   # 宿主解析与持久 key
│  ├─ InputProfiles.ahk    # profile 枚举、TSF/HKL 切换
│  ├─ ImeMode.ahk          # IME open/conversion 读写
│  ├─ Rules.ahk            # 规则匹配
│  ├─ StateStore.ahk       # INI、原子写盘、迁移
│  └─ TrayMenu.ahk         # 托盘交互
├─ tools/
│  └─ ime-probe.ahk        # 环境能力探针
└─ README.md
```

依赖方向保持单向，Win32 封装和业务策略分开，后续替换某个输入法实现时不会碰窗口记忆层。

## 12. 失败边界与降级

- 第三方 IME 若不能可靠读写内部模式：仍记忆和恢复完整 profile，内部模式显示 `unknown`，不模拟输入法私有快捷键。
- 高完整性（管理员）窗口受 UIPI 限制：普通权限脚本可能能观察但不能发送切换消息。本机当前有管理员运行的 VS Code，因此需要提供普通版和 UIAccess/管理员测试说明；默认不建议整日以管理员权限运行。
- UAC 安全桌面、登录界面、密码安全控件不参与记忆。
- 卡死窗口：跨进程调用超时后跳过，不阻塞切换。
- 同标题浏览器窗口：跨重启无稳定 Win32 ID，需用户 title 规则或接受 app 级回退。

## 13. 验证标准

实现不能只通过语法检查，应至少覆盖：

1. English US ↔ 微信输入法 profile 切换。
2. 微信输入法中文 ↔ 英文内部模式。
3. Alt+Tab、鼠标点击、Win+Tab 后恢复。
4. Edge 两个窗口、Explorer、Windows Terminal、Raycast。
5. 手动 Win+Space、Shift、语言栏点击后自动学习。
6. 重启脚本和重启 Windows 后恢复。
7. 强制规则不被用户临时切换覆盖。
8. 卡死/无响应窗口不会卡住脚本。
9. 运行 30 分钟的 CPU、私有内存与句柄数无持续增长。
10. `.ahk` 直接运行和编译 `.exe` 两种交付方式。
