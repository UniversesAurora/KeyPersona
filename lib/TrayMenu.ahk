#Requires AutoHotkey v2.0

class TrayMenuController {
    __New(app) {
        this.App := app
        this.LastFingerprint := ""
        this.StateMenu := ""
        this.DefaultMenu := ""
        this.About := AboutDialog()
        this.LastLeftClick := 0
        this.TrayMessageCallback := ObjBindMethod(this, "OnTrayMessage")
        this.ShowMenuCallback := ObjBindMethod(this, "ShowMenu")
        OnMessage(0x0404, this.TrayMessageCallback)
        A_IconTip := "IME Memory"
    }

    Refresh(force := false) {
        window := this.App.CurrentWindow
        state := this.App.CurrentState
        rule := this.App.CurrentRule
        fingerprint := this.App.Enabled "|" MapGet(window, "hwnd", 0) "|"
            . StateSignature(state) "|" MapGet(rule, "name", "") "|"
            . this.App.Config.DefaultState
        if !force && fingerprint = this.LastFingerprint
            return
        this.LastFingerprint := fingerprint
        tray := A_TrayMenu
        tray.Delete()
        tray.Add("启用", ObjBindMethod(this.App, "ToggleEnabled"))
        if this.App.Enabled
            tray.Check("启用")
        tray.Add("开机自启动", ObjBindMethod(this.App, "ToggleStartup"))
        if this.App.Startup.IsEnabled()
            tray.Check("开机自启动")
        tray.Add()
        if window.Count {
            status := "当前：" MapGet(window, "exe", "unknown") " — " this.ShortState(state)
            tray.Add(status, (*) => 0)
            tray.Disable(status)
            if rule.Count {
                ruleText := "强制规则：" rule["name"]
                tray.Add(ruleText, (*) => 0)
                tray.Disable(ruleText)
            }
        } else {
            tray.Add("当前：无可记录窗口", (*) => 0)
            tray.Disable("当前：无可记录窗口")
        }
        defaultState := this.App.Config.GetNamedState(this.App.Config.DefaultState)
        defaultStatus := "全局默认：" this.App.Config.DefaultState
        if defaultState.Count
            defaultStatus .= " — " this.ShortState(defaultState)
        tray.Add(defaultStatus, (*) => 0)
        tray.Disable(defaultStatus)
        this.DefaultMenu := Menu()
        this.StateMenu := Menu()
        for stateName, namedState in this.App.Config.NamedStates {
            label := this.StateMenuLabel(stateName, namedState)
            this.DefaultMenu.Add(label, ObjBindMethod(this, "SetDefaultState", stateName))
            if (stateName = this.App.Config.DefaultState)
                this.DefaultMenu.Check(label)
            this.StateMenu.Add(label, ObjBindMethod(this, "SetState", stateName))
        }
        tray.Add("全局默认输入法", this.DefaultMenu)
        tray.Add("设置当前窗口为", this.StateMenu)
        tray.Add("清除当前窗口记录", ObjBindMethod(this.App, "ClearCurrentRecord"))
        if !window.Count {
            tray.Disable("设置当前窗口为")
            tray.Disable("清除当前窗口记录")
        }
        tray.Add()
        tray.Add("打开配置文件", ObjBindMethod(this, "OpenConfig"))
        tray.Add("打开状态文件", ObjBindMethod(this, "OpenState"))
        tray.Add("Reload", ObjBindMethod(this.App, "ReloadConfiguration"))
        tray.Add()
        tray.Add("关于 IME Memory", ObjBindMethod(this, "ShowAbout"))
        tray.Add("Exit", ObjBindMethod(this, "ExitApplication"))
    }

    StateMenuLabel(stateName, namedState) {
        label := stateName " — " this.App.Profiles.DisplayName(MapGet(namedState, "profile", "unknown"))
        open := MapGet(namedState, "imeOpen", "unknown")
        if (open = "1")
            label .= "（中文）"
        else if (open = "0")
            label .= "（英文）"
        return label
    }

    ShortState(state) {
        if !state.Count
            return "检测中"
        name := this.App.Profiles.DisplayName(MapGet(state, "profile", "unknown"))
        open := MapGet(state, "imeOpen", "unknown")
        if (open = "1")
            return name " / 中文"
        if (open = "0")
            return name " / 英文"
        return name
    }

    SetState(stateName, *) {
        this.App.SetCurrentState(stateName)
    }

    SetDefaultState(stateName, *) {
        this.App.SetDefaultState(stateName)
    }

    OnTrayMessage(wParam, lParam, message, receiverHwnd) {
        if (receiverHwnd != A_ScriptHwnd)
            return
        eventCode := lParam & 0xFFFF
        if (eventCode != 0x0202 && eventCode != 0x0400 && eventCode != 0x0401)
            return
        now := TickCount64()
        if (now - this.LastLeftClick < 250)
            return 0
        this.LastLeftClick := now
        SetTimer(this.ShowMenuCallback, -10)
        return 0
    }

    ShowMenu(*) {
        A_TrayMenu.Show()
    }

    ShowAbout(*) {
        this.About.Show()
    }

    OpenConfig(*) {
        Run(this.App.Config.Path)
    }

    OpenState(*) {
        this.App.Store.Flush()
        if FileExist(this.App.Config.StatePath)
            Run(this.App.Config.StatePath)
        else
            TrayTip("还没有自动记忆记录。", "IME Memory")
    }

    ExitApplication(*) {
        ExitApp()
    }

    Dispose() {
        try OnMessage(0x0404, this.TrayMessageCallback, 0)
        try SetTimer(this.ShowMenuCallback, 0)
        try this.About.Dispose()
    }
}
