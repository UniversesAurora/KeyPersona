#Requires AutoHotkey v2.0

class TrayMenuController {
    __New(app) {
        this.App := app
        this.LastFingerprint := ""
        this.StateMenu := ""
        this.DefaultMenu := ""
        this.BacktickLabel := "中文模式下反引号键输出 " Chr(96)
        this.About := AboutDialog()
        this.LastLeftClick := 0
        this.TrayMessageCallback := ObjBindMethod(this, "OnTrayMessage")
        this.ShowMenuCallback := ObjBindMethod(this, "ShowMenu")
        OnMessage(0x0404, this.TrayMessageCallback)
        A_IconTip := AppInfo.Name
    }

    Refresh(force := false) {
        window := this.App.CurrentWindow
        state := this.App.CurrentState
        rule := this.App.CurrentRule
        if (window.Count && !DllCall("user32\IsWindow", "Ptr", MapGet(window, "hwnd", 0), "Int")) {
            window := Map()
            state := Map()
            rule := Map()
        }
        fingerprint := this.App.Enabled "|" MapGet(window, "hwnd", 0) "|"
            . StateSignature(state) "|" MapGet(rule, "name", "") "|"
            . this.App.CurrentSource "|" this.App.Config.DefaultState "|"
            . this.App.Config.AutoMemory "|" this.App.Config.BacktickInChinese
        if !force && fingerprint = this.LastFingerprint
            return
        this.LastFingerprint := fingerprint
        tray := A_TrayMenu
        tray.Delete()
        tray.Add("启用自动切换", ObjBindMethod(this.App, "ToggleEnabled"))
        if this.App.Enabled
            tray.Check("启用自动切换")
        tray.Add("自动记忆输入法", ObjBindMethod(this.App, "ToggleAutoMemory"))
        if this.App.Config.AutoMemory
            tray.Check("自动记忆输入法")
        tray.Add("开机自启动", ObjBindMethod(this.App, "ToggleStartup"))
        if this.App.Startup.IsEnabled()
            tray.Check("开机自启动")
        tray.Add()
        if window.Count {
            status := "当前窗口：" MapGet(window, "exe", "未知") " · " this.ShortState(state)
            tray.Add(status, (*) => 0)
            tray.Disable(status)
            identityType := MapGet(window, "mode", "app") = "window" ? "窗口" : "应用"
            identityId := Fnv1a32(MapGet(window, "identityKey", ""))
            sourceStatus := "来源：" this.SourceLabel(this.App.CurrentSource, rule)
                . " · " identityType " ID " identityId
            tray.Add(sourceStatus, (*) => 0)
            tray.Disable(sourceStatus)
        } else {
            tray.Add("当前窗口：无可管理窗口", (*) => 0)
            tray.Disable("当前窗口：无可管理窗口")
        }
        defaultState := this.App.Config.GetNamedState(this.App.Config.DefaultState)
        defaultStatus := "全局默认："
        if defaultState.Count
            defaultStatus .= this.ShortState(defaultState)
        else
            defaultStatus .= "未配置"
        tray.Add(defaultStatus, (*) => 0)
        tray.Disable(defaultStatus)
        this.DefaultMenu := Menu()
        this.StateMenu := Menu()
        hasUserRule := rule.Count > 0 || this.App.CurrentSource = "manual"
        selectedStateName := this.SelectedRuleStateName(window, rule)
        this.StateMenu.Add("全局默认（无用户规则）", ObjBindMethod(this.App, "UseGlobalForCurrentWindow"))
        if !hasUserRule
            this.StateMenu.Check("全局默认（无用户规则）")
        this.StateMenu.Add()
        usedStateLabels := Map()
        for stateName, namedState in this.App.Config.NamedStates {
            label := this.StateMenuLabel(stateName, namedState)
            if usedStateLabels.Has(label)
                label .= " · " SubStr(Fnv1a32(stateName "|" MapGet(namedState, "profile", "")), 1, 6)
            usedStateLabels[label] := true
            this.DefaultMenu.Add(label, ObjBindMethod(this, "SetDefaultState", stateName))
            if (stateName = this.App.Config.DefaultState)
                this.DefaultMenu.Check(label)
            this.StateMenu.Add(label, ObjBindMethod(this, "SetState", stateName))
            if (stateName = selectedStateName)
                this.StateMenu.Check(label)
        }
        tray.Add("全局默认输入法", this.DefaultMenu)
        tray.Add("当前窗口默认输入法", this.StateMenu)
        tray.Add("清除当前窗口的自动记忆", ObjBindMethod(this.App, "ClearCurrentRecord"))
        tray.Add("清除所有自动记忆…", ObjBindMethod(this.App, "ClearAllRecords"))
        if !window.Count {
            tray.Disable("当前窗口默认输入法")
            tray.Disable("清除当前窗口的自动记忆")
        }
        tray.Add()
        tray.Add(this.BacktickLabel, ObjBindMethod(this.App, "ToggleBacktickInChinese"))
        if this.App.Config.BacktickInChinese
            tray.Check(this.BacktickLabel)
        tray.Add()
        tray.Add("打开配置文件", ObjBindMethod(this, "OpenConfig"))
        tray.Add("打开状态文件", ObjBindMethod(this, "OpenState"))
        tray.Add("重新加载", ObjBindMethod(this.App, "ReloadConfiguration"))
        tray.Add()
        tray.Add("关于 " AppInfo.Name, ObjBindMethod(this, "ShowAbout"))
        tray.Add("退出", ObjBindMethod(this, "ExitApplication"))
    }

    StateMenuLabel(stateName, namedState) {
        if (stateName = "english-us")
            return "英语（美国）- 美式键盘"
        if (stateName = "wetype-chinese")
            return "微信输入法（中文）"
        if (stateName = "wetype-english")
            return "微信输入法（英文）"
        profileId := MapGet(namedState, "profile", "unknown")
        label := this.App.Profiles.DisplayName(profileId)
        if (label = profileId && MapGet(namedState, "description", "") != "")
            label := namedState["description"]
        open := MapGet(namedState, "imeOpen", "unknown")
        if (open = "1")
            label .= "（中文）"
        else if (open = "0")
            label .= "（英文）"
        return label
    }

    SourceLabel(source, rule) {
        if (source = "rule") {
            if (rule.Count && MapGet(rule, "scope", "application") = "window")
                return "用户规则（当前窗口默认）"
            return "用户规则" (rule.Count ? "（" rule["name"] "，默认）" : "（默认）")
        }
        if (source = "manual")
            return "手动指定"
        if (source = "learned")
            return "自动记忆"
        if (source = "default")
            return "全局默认"
        if (source = "observed")
            return this.App.Config.AutoMemory ? "仅观察" : "自动记忆已关闭"
        return "检测中"
    }

    SelectedRuleStateName(window, rule) {
        if rule.Count
            return MapGet(rule, "stateName", "")
        if (this.App.CurrentSource != "manual" || !window.Count)
            return ""
        hwndKey := MapGet(window, "hwnd", 0) ""
        if !this.App.SessionStates.Has(hwndKey)
            return ""
        manualState := this.App.SessionStates[hwndKey]
        for stateName, namedState in this.App.Config.NamedStates {
            if (StateSignature(manualState) = StateSignature(namedState))
                return stateName
        }
        return ""
    }

    ShortState(state) {
        if !state.Count
            return "检测中"
        name := this.App.Profiles.DisplayName(MapGet(state, "profile", "unknown"))
        open := MapGet(state, "imeOpen", "unknown")
        if (open = "1")
            return name "（中文）"
        if (open = "0")
            return name "（英文）"
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
        if (eventCode != 0x0202 && eventCode != 0x0205 && eventCode != 0x007B
            && eventCode != 0x0400 && eventCode != 0x0401)
            return
        now := TickCount64()
        if (now - this.LastLeftClick < 250)
            return 0
        this.LastLeftClick := now
        SetTimer(this.ShowMenuCallback, -10)
        return 0
    }

    ShowMenu(*) {
        this.App.RefreshInputProfiles()
        this.App.RefreshCurrentStateForMenu()
        this.Refresh(true)
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
            TrayTip("还没有自动记忆记录。", AppInfo.Name)
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
