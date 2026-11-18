#Requires AutoHotkey v2.0

class TrayMenuController {
    __New(app) {
        this.App := app
        this.LastFingerprint := ""
        this.StateMenu := ""
        this.DefaultMenu := ""
        this.PunctuationMenu := ""
        this.AppInputMenu := ""
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
        exe := MapGet(window, "exe", "")
        excluded := this.App.Config.IsAppMemoryExcluded(exe)
        forced := this.App.Config.IsAppInputForced(exe)
        fingerprint := this.App.Enabled "|" MapGet(window, "hwnd", 0) "|"
            . StateSignature(state) "|" MapGet(rule, "name", "") "|"
            . this.App.CurrentSource "|" this.App.Config.DefaultState "|"
            . this.App.Config.AutoMemory "|" this.App.Config.PunctuationRevision "|"
            . excluded "|" forced "|" StateSignature(this.App.Enforcement.Target)
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
        adminLabel := "始终以管理员身份运行" (A_IsAdmin ? "（当前已提权）" : "")
        tray.Add(adminLabel, ObjBindMethod(this.App, "ToggleRunAsAdmin"))
        if this.App.Config.RunAsAdmin
            tray.Check(adminLabel)
        tray.Add()
        if window.Count {
            status := StrReplace("当前窗口：" MapGet(window, "exe", "未知") " · " this.ShortState(state), "&", "&&")
            tray.Add(status, (*) => 0)
            tray.Disable(status)
            identityType := MapGet(window, "mode", "app") = "window" ? "窗口" : "应用"
            identityId := Fnv1a32(MapGet(window, "identityKey", ""))
            sourceStatus := "来源：" this.SourceLabel(this.App.CurrentSource, rule, window)
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
        defaultStatus := StrReplace(defaultStatus, "&", "&&")
        tray.Add(defaultStatus, (*) => 0)
        tray.Disable(defaultStatus)
        tray.Add()
        this.DefaultMenu := Menu()
        this.StateMenu := Menu()
        hasUserRule := rule.Count > 0 || this.App.CurrentSource = "manual"
        selectedStateName := this.SelectedRuleStateName(window, rule)
        this.StateMenu.Add("全局默认（无用户规则）", ObjBindMethod(this.App, "UseGlobalForCurrentWindow"))
        if !hasUserRule
            this.StateMenu.Check("全局默认（无用户规则）")
        this.StateMenu.Add()
        this.AddInputChoices(this.DefaultMenu, this.App.Config.DefaultState, "SetDefaultState")
        this.AddInputChoices(this.StateMenu, selectedStateName, "SetState")
        tray.Add("全局默认输入法", this.DefaultMenu)
        tray.Add("当前窗口默认输入法", this.StateMenu)
        if !window.Count
            tray.Disable("当前窗口默认输入法")
        appLabel := exe = "" ? "当前应用输入法设置" : "当前应用输入法设置（" StrReplace(exe, "&", "&&") "）"
        if exe = "" {
            tray.Add(appLabel, (*) => 0)
            tray.Disable(appLabel)
        } else {
            this.AppInputMenu := this.BuildAppInputMenu(exe, excluded, forced)
            tray.Add(appLabel, this.AppInputMenu)
        }
        this.PunctuationMenu := this.BuildPunctuationMenu(window)
        tray.Add("中文符号转英文", this.PunctuationMenu)
        tray.Add()
        memoryMenu := Menu()
        memoryMenu.Add("打开状态文件", ObjBindMethod(this, "OpenState"))
        memoryMenu.Add()
        memoryMenu.Add("清除当前窗口的自动记忆", ObjBindMethod(this.App, "ClearCurrentRecord"))
        memoryMenu.Add("清除所有自动记忆…", ObjBindMethod(this.App, "ClearAllRecords"))
        if !window.Count
            memoryMenu.Disable("清除当前窗口的自动记忆")
        tray.Add("记忆管理", memoryMenu)
        tray.Add("打开配置文件", ObjBindMethod(this, "OpenConfig"))
        tray.Add("重新加载", ObjBindMethod(this.App, "ReloadConfiguration"))
        tray.Add()
        tray.Add("关于 " AppInfo.Name, ObjBindMethod(this, "ShowAbout"))
        tray.Add("退出", ObjBindMethod(this, "ExitApplication"))
    }

    AddInputChoices(targetMenu, selected, method) {
        languages := Map()
        for stateName, state in this.App.Config.NamedStates {
            profileId := StrLower(MapGet(state, "profile", "unknown"))
            langId := InputProfiles.LanguageId(profileId)
            if !languages.Has(langId)
                languages[langId] := Map()
            profiles := languages[langId]
            if !profiles.Has(profileId)
                profiles[profileId] := []
            profiles[profileId].Push(state)
        }
        if !languages.Count {
            targetMenu.Add("未找到可用输入法", (*) => 0)
            targetMenu.Disable("未找到可用输入法")
            return
        }
        position := DllCall("user32\GetMenuItemCount", "Ptr", targetMenu.Handle, "Int")
        options := ""
        for langId, profiles in languages {
            heading := InputProfiles.LanguageDisplayName(langId)
            if (heading = "")
                heading := langId ? "语言 " Hex(langId, 4) : "其他输入法"
            targetMenu.Insert("", StrReplace(heading, "&", "&&"), (*) => 0, options)
            targetMenu.Disable(++position "&")
            options := "BarBreak"
            for profileId, states in profiles
                this.AddInputSourceChoice(targetMenu, profileId, states, selected, method, ++position)
        }
    }

    AddInputSourceChoice(targetMenu, profileId, states, selected, method, position) {
        label := StrReplace(this.App.Profiles.DisplayName(profileId), "&", "&&")
        first := states[1]
        if (states.Length = 1 && ImeMode.ModeLabel(profileId, first["imeOpen"]) = "") {
            targetMenu.Insert("", label, ObjBindMethod(this, method, first["name"]))
            if (first["name"] = selected)
                targetMenu.Check(position "&")
            return
        }
        modes := Menu()
        usedModeLabels := Map()
        checked := false
        for open in ["1", "0", "preserve"] {
            for state in states {
                name := state["name"]
                mode := ImeMode.ModeLabel(profileId, state["imeOpen"])
                if (open = "preserve" ? mode != "" : state["imeOpen"] != open)
                    continue
                modeLabel := TrayMenuController.UniqueLabel(
                    mode != "" ? mode : "仅切换输入法", name, usedModeLabels)
                modes.Add(modeLabel, ObjBindMethod(this, method, name))
                if (name = selected) {
                    modes.Check(modeLabel)
                    checked := true
                }
            }
        }
        targetMenu.Insert("", label, modes)
        if checked
            targetMenu.Check(position "&")
    }

    static UniqueLabel(label, key, used) {
        label := StrReplace(label, "&", "&&")
        if used.Has(label)
            label .= " · " SubStr(Fnv1a32(key), 1, 6)
        used[label] := true
        return label
    }

    BuildAppInputMenu(exe, excluded, forced) {
        settings := Menu()
        excludeLabel := "关闭此应用的自动记忆"
        forceLabel := "强制保持目标输入法"
        settings.Add(excludeLabel, ObjBindMethod(this.App, "ToggleAppInputOption", exe, "excludeMemory"))
        settings.Add(forceLabel, ObjBindMethod(this.App, "ToggleAppInputOption", exe, "force"))
        if excluded
            settings.Check(excludeLabel)
        if forced {
            settings.Check(forceLabel)
            target := this.App.Enforcement.Target
            label := StrReplace("强制目标：" (target.Count ? this.ShortState(target) : "无可用目标"), "&", "&&")
            if !this.App.Enabled
                label .= "（自动切换已停用）"
            settings.Add(label, (*) => 0)
            settings.Disable(label)
        }
        return settings
    }

    BuildPunctuationMenu(window) {
        config := this.App.Config
        symbols := Menu()
        symbols.Add("启用转换（全局）", ObjBindMethod(this, "TogglePunctuation"))
        if config.PunctuationEnabled
            symbols.Check("启用转换（全局）")
        symbols.Add()
        for group, groupLabel in Map("common", "常用标点", "pairs", "括号与引号", "other", "其他符号") {
            category := Menu()
            for rule in PunctuationCatalog.Rules {
                if (rule["group"] != group)
                    continue
                id := rule["id"]
                if (rule["close"] = "") {
                    category.Add(rule["label"], ObjBindMethod(this, "TogglePunctuationOption", id, false))
                    if config.PunctuationConvert[id]
                        category.Check(rule["label"])
                } else {
                    pairMenu := Menu()
                    pairMenu.Add("转换为英文", ObjBindMethod(this, "TogglePunctuationOption", id, false))
                    if config.PunctuationConvert[id]
                        pairMenu.Check("转换为英文")
                    pairMenu.Add("自动补齐（全局）", ObjBindMethod(this, "TogglePunctuationOption", id, true))
                    if config.PunctuationPairs[id]
                        pairMenu.Check("自动补齐（全局）")
                    category.Add(rule["label"], pairMenu)
                    if config.PunctuationConvert[id]
                        category.Check(rule["label"])
                }
            }
            symbols.Add(groupLabel, category)
        }
        symbols.Add()
        exe := MapGet(window, "exe", "")
        appLabel := "当前应用符号设置" (exe != "" ? "（" StrReplace(exe, "&", "&&") "）" : "")
        if (exe = "") {
            symbols.Add(appLabel, (*) => 0)
            symbols.Disable(appLabel)
        } else {
            appMenu := Menu()
            appMenu.Add("全部跟随全局", ObjBindMethod(this, "ClearAppPunctuationOptions", exe))
            if !config.PunctuationApps.Has(StrLower(exe))
                appMenu.Check("全部跟随全局")
            appMenu.Add()
            appMenu.Add("转换开关", this.BuildAppPunctuationOptionMenu(exe, "", false))
            appConversion := Menu()
            for group, groupLabel in Map("common", "常用标点", "pairs", "括号与引号", "other", "其他符号") {
                category := Menu()
                for rule in PunctuationCatalog.Rules {
                    if (rule["group"] != group)
                        continue
                    category.Add(rule["label"], this.BuildAppPunctuationOptionMenu(exe, rule["id"], false))
                    if config.ResolvePunctuationOption(exe, rule["id"])
                        category.Check(rule["label"])
                }
                appConversion.Add(groupLabel, category)
            }
            appMenu.Add("符号转换", appConversion)
            appPairs := Menu()
            for rule in PunctuationCatalog.Rules {
                if (rule["close"] = "")
                    continue
                id := rule["id"]
                appPairs.Add(rule["label"], this.BuildAppPunctuationOptionMenu(exe, id, true))
                if config.ShouldPairPunctuation(exe, id)
                    appPairs.Check(rule["label"])
            }
            appMenu.Add("自动补齐", appPairs)
            symbols.Add(appLabel, appMenu)
        }
        return symbols
    }

    BuildAppPunctuationOptionMenu(exe, id, pair) {
        config := this.App.Config
        override := config.GetAppPunctuationOption(exe, id, pair)
        globalEnabled := id = "" ? config.PunctuationEnabled
            : MapGet(pair ? config.PunctuationPairs : config.PunctuationConvert, id, false)
        inheritLabel := "跟随全局（" (globalEnabled ? "开启" : "关闭") "）"
        options := Menu()
        options.Add(inheritLabel, ObjBindMethod(this, "SetAppPunctuationOption", exe, id, pair, "inherit"))
        options.Add("开启", ObjBindMethod(this, "SetAppPunctuationOption", exe, id, pair, "1"))
        options.Add("关闭", ObjBindMethod(this, "SetAppPunctuationOption", exe, id, pair, "0"))
        options.Check(override = "inherit" ? inheritLabel : override ? "开启" : "关闭")
        return options
    }

    TogglePunctuation(*) {
        this.App.Config.SetPunctuationEnabled(!this.App.Config.PunctuationEnabled)
        this.Refresh(true)
    }

    TogglePunctuationOption(id, pair, *) {
        options := pair ? this.App.Config.PunctuationPairs : this.App.Config.PunctuationConvert
        this.App.Config.SetPunctuationOption(id, pair, !options[id])
        this.Refresh(true)
    }

    SetAppPunctuationOption(exe, id, pair, mode, *) {
        this.App.Config.SetAppPunctuationOption(exe, id, pair, mode)
        this.Refresh(true)
    }

    ClearAppPunctuationOptions(exe, *) {
        this.App.Config.ClearAppPunctuationOptions(exe)
        this.Refresh(true)
    }

    SourceLabel(source, rule, window) {
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
            return this.App.CanRemember(window) ? "当前状态（未记忆）" : "自动记忆已关闭"
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
        profileId := MapGet(state, "profile", "unknown")
        name := this.App.Profiles.DisplayName(profileId, true)
        mode := ImeMode.ModeLabel(profileId, MapGet(state, "imeOpen", "unknown"))
        return mode = "" ? name : name "（" mode "）"
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
        try this.About.Show()
        catch Error as failure {
            this.App.Logger.Error("Could not open About window: " failure.Message)
            TrayTip("无法打开关于窗口。", AppInfo.Name, "Iconx")
        }
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
