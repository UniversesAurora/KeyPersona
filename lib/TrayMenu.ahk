#Requires AutoHotkey v2.0

class TrayMenuController {
    __New(app) {
        this.App := app
        this.PunctuationKey := ""
        this.PunctuationMenu := ""
        this.About := AboutDialog()
        this.LastLeftClick := 0
        this.TrayMessageCallback := ObjBindMethod(this, "OnTrayMessage")
        this.ShowMenuCallback := ObjBindMethod(this, "ShowMenu")
        OnMessage(0x0404, this.TrayMessageCallback)
        A_IconTip := AppInfo.Name
    }

    Build(context) {
        window := context.window
        rule := context.rule
        desired := context.desired
        exe := WindowIdentity.AppSelectorFor(window)
        appName := WindowIdentity.AppLabel(window)
        forced := this.App.Config.IsAppInputForced(exe)
        tray := A_TrayMenu
        tray.Delete()
        tray.Add("自动切换（全局）", ObjBindMethod(this.App, "ToggleEnabled"))
        if this.App.Config.Enabled
            tray.Check("自动切换（全局）")
        tray.Add("自动记忆（全局）", ObjBindMethod(this.App, "ToggleAutoMemory"))
        if this.App.Config.AutoMemory
            tray.Check("自动记忆（全局）")
        tray.Add("开机自启动", ObjBindMethod(this.App, "ToggleStartup"))
        if this.App.Startup.IsEnabled()
            tray.Check("开机自启动")
        adminLabel := "始终以管理员身份运行" (A_IsAdmin ? "（当前已提权）" : "")
        tray.Add(adminLabel, ObjBindMethod(this.App, "ToggleRunAsAdmin"))
        if this.App.Config.RunAsAdmin
            tray.Check(adminLabel)
        tray.Add()
        if window.Count {
            state := context.actual
            status := "当前：" appName " · " this.ShortState(state)
                . (context.cached ? "（最近检测）" : "")
            this.AddStatus(tray, status)
            target := !this.App.CanSwitch(window) ? "自动切换已停用" : desired.Count
                ? this.ShortState(desired) "（" this.SourceLabel(MapGet(desired, "source", ""), rule) "）"
                : "跟随 Windows"
            this.AddStatus(tray, "进入时：" target)
        } else {
            this.AddStatus(tray, context.waiting ? "当前窗口：正在等待就绪" : "当前窗口：无可管理窗口")
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
        defaultMenu := Menu()
        this.AddInputChoices(defaultMenu, this.App.Config.DefaultState, ObjBindMethod(this.App, "SetDefaultState"))
        tray.Add("全局默认输入法", defaultMenu)
        stateMenu := Menu()
        if window.Count {
            appRule := this.App.MatchInheritedRule(window)
            windowRule := this.App.Config.GetWindowRule(window)
            follow := appRule.Count ? "跟随应用规则" : "全局默认（无用户规则）"
            stateMenu.Add(follow, ObjBindMethod(this.App, "UseInheritedWindowRule", window))
            if !windowRule.Count
                stateMenu.Check(follow)
            selected := MapGet(windowRule, "stateName", "")
            setRule := ObjBindMethod(this.App, "SetCurrentState", window)
            windowScoped := MapGet(window, "mode", "app") = "window"
            if appRule.Count || selected = "@global" {
                globalOverride := windowScoped ? "使用全局默认（当前窗口）" : "使用全局默认（当前应用）"
                stateMenu.Add(globalOverride, ObjBindMethod(setRule, "Call", "@global"))
                if selected = "@global"
                    stateMenu.Check(globalOverride)
            }
            stateMenu.Add()
            this.AddInputChoices(stateMenu, selected, setRule)
            scope := windowScoped ? "当前窗口默认输入法" : "当前应用默认输入法"
            tray.Add(scope, stateMenu)
        } else {
            this.AddStatus(tray, "当前窗口默认输入法")
        }
        appLabel := exe = "" ? "当前应用输入法设置" : "当前应用输入法设置（" StrReplace(appName, "&", "&&") "）"
        if exe = "" {
            tray.Add(appLabel, (*) => 0)
            tray.Disable(appLabel)
        } else {
            tray.Add(appLabel, this.BuildAppInputMenu(window, exe, forced, desired))
        }
        punctuationKey := exe "|" this.App.Config.PunctuationRevision
        if punctuationKey != this.PunctuationKey {
            this.PunctuationMenu := this.BuildPunctuationMenu(window)
            this.PunctuationKey := punctuationKey
        }
        tray.Add("中文符号转英文", this.PunctuationMenu)
        tray.Add()
        memoryMenu := Menu()
        memoryMenu.Add("打开状态文件", ObjBindMethod(this, "OpenState"))
        memoryMenu.Add()
        memoryMenu.Add("清除当前窗口的自动记忆", ObjBindMethod(this.App, "ClearCurrentRecord", window))
        memoryMenu.Add("清除所有自动记忆…", ObjBindMethod(this.App, "ClearAllRecords"))
        if !window.Count || !this.App.HasWindowMemory(window)
            memoryMenu.Disable("清除当前窗口的自动记忆")
        tray.Add("记忆管理", memoryMenu)
        tray.Add("打开配置文件", ObjBindMethod(this, "OpenConfig"))
        tray.Add("重新加载", ObjBindMethod(this.App, "ReloadConfiguration"))
        tray.Add()
        tray.Add("关于 " AppInfo.Name, ObjBindMethod(this, "ShowAbout"))
        tray.Add("退出", ObjBindMethod(this, "ExitApplication"))
    }

    AddStatus(targetMenu, label) {
        label := StrReplace(label, "&", "&&")
        targetMenu.Add(label, (*) => 0)
        targetMenu.Disable(label)
    }

    AddInputChoices(targetMenu, selected, callback) {
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
        firstLanguage := true
        for langId, profiles in languages {
            if !firstLanguage {
                targetMenu.Add()
                position += 1
            }
            firstLanguage := false
            heading := InputProfiles.LanguageDisplayName(langId)
            if (heading = "")
                heading := langId ? "语言 " Hex(langId, 4) : "其他输入法"
            targetMenu.Insert("", StrReplace(heading, "&", "&&"), (*) => 0)
            targetMenu.Disable(++position "&")
            for profileId, states in profiles
                this.AddInputSourceChoice(targetMenu, profileId, states, selected, callback, ++position)
        }
    }

    AddInputSourceChoice(targetMenu, profileId, states, selected, callback, position) {
        label := StrReplace(this.App.Profiles.DisplayName(profileId), "&", "&&")
        first := states[1]
        if (states.Length = 1 && ImeMode.ModeLabel(profileId, first["imeOpen"]) = "") {
            targetMenu.Insert("", label, ObjBindMethod(callback, "Call", first["name"]))
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
                modeLabel := mode != "" ? mode : "仅切换输入法"
                if ImeMode.NeedsDetailedMode(state)
                    modeLabel .= " · " (state["description"] != "" ? state["description"] : name)
                modeLabel := TrayMenuController.UniqueLabel(modeLabel, name, usedModeLabels)
                modes.Add(modeLabel, ObjBindMethod(callback, "Call", name))
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

    BuildAppInputMenu(window, exe, forced, target) {
        settings := Menu()
        settings.Add("自动记忆", this.BuildInputOverrideMenu(exe, "autoMemory"))
        settings.Add("自动切换", this.BuildInputOverrideMenu(exe, "autoSwitch"))
        forceLabel := "强制保持目标输入法"
        settings.Add(forceLabel, ObjBindMethod(this.App, "ToggleAppForce", exe))
        if forced {
            settings.Check(forceLabel)
            if !this.App.Config.ResolveAppInputOption(exe, "autoSwitch")
                label := "强制保持暂停（此应用的自动切换已关闭）"
            else
                label := "强制目标：" (target.Count ? this.ShortState(target) : "请设置默认输入法规则")
            this.AddStatus(settings, label)
        }
        }
        return settings
    }

    BuildInputOverrideMenu(exe, option) {
        submenu := Menu()
        selected := this.App.Config.GetAppInputOption(exe, option)
        inherited := this.App.Config.GetInheritedAppInputOption(exe, option)
        for mode, label in Map("inherit", this.InheritedOptionLabel(exe, inherited), "1", "开启", "0", "关闭") {
            submenu.Add(label, ObjBindMethod(this.App, "SetAppInputOption", exe, option, mode))
            if selected = mode
                submenu.Check(label)
        }
        return submenu
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
                    if !config.PunctuationEnabled || !config.PunctuationConvert[id]
                        this.AddStatus(pairMenu, "生效需开启全局转换和此符号")
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
                pairLabel := rule["label"] (config.ShouldConvertPunctuation(exe, id) ? "" : "（转换关闭）")
                appPairs.Add(pairLabel, this.BuildAppPunctuationOptionMenu(exe, id, true))
                if config.ShouldPairPunctuation(exe, id)
                    appPairs.Check(pairLabel)
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
        this.UpdatePunctuation(ObjBindMethod(this.App.Config, "SetPunctuationEnabled",
            !this.App.Config.PunctuationEnabled))
    }

    TogglePunctuationOption(id, pair, *) {
        options := pair ? this.App.Config.PunctuationPairs : this.App.Config.PunctuationConvert
        this.UpdatePunctuation(ObjBindMethod(this.App.Config, "SetPunctuationOption", id, pair, !options[id]))
    }

    SetAppPunctuationOption(exe, id, pair, mode, *) {
        this.UpdatePunctuation(ObjBindMethod(this.App.Config, "SetAppPunctuationOption", exe, id, pair, mode))
    }

    ClearAppPunctuationOptions(exe, *) {
        this.UpdatePunctuation(ObjBindMethod(this.App.Config, "ClearAppPunctuationOptions", exe))
    }

    UpdatePunctuation(update) {
        try update()
        catch Error as failure {
            this.App.ReportSettingsError(failure)
            return
        }
        this.App.Punctuation.RefreshBindings()
    }

    SourceLabel(source, rule) {
        if source = "learned"
            return "自动记忆"
        if source = "rule" {
            if MapGet(rule, "stateName", "") = "@global"
                return "窗口跟随全局"
            return MapGet(rule, "scope", "") = "window" ? "用户规则" : "应用规则"
        }
        return "全局默认"
    }

    ShortState(state) {
        if !state.Count
            return "检测中"
        if !HasKnownProfile(state)
            return "输入法未知"
        profileId := state["profile"]
        name := this.App.Profiles.DisplayName(profileId, true)
        mode := ImeMode.ModeLabel(profileId, MapGet(state, "imeOpen", "unknown"))
        return mode = "" ? name : name "（" mode "）"
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
        try {
            context := this.App.CaptureMenuContext()
            if context.waiting && TickCount64() - this.LastLeftClick < 350 {
                SetTimer(this.ShowMenuCallback, -30)
                return
            }
            this.App.RefreshInputProfiles()
            this.Build(this.App.ResolveMenuPolicy(context))
            A_TrayMenu.Show()
        } catch Error as failure {
            this.App.Logger.Error("Could not display tray menu: " failure.Message)
            TrayTip("无法打开托盘菜单。", AppInfo.Name, "Iconx")
        }
    }

    ShowAbout(*) {
        try this.About.Show()
        catch Error as failure {
            this.App.Logger.Error("Could not open About window: " failure.Message)
            TrayTip("无法打开关于窗口。", AppInfo.Name, "Iconx")
        }
    }

    OpenConfig(*) {
        try Run(this.App.Config.Path)
        catch Error as failure
            this.App.ReportSettingsError(failure)
    }

    OpenState(*) {
        this.App.Store.Flush()
        if FileExist(this.App.Config.StatePath) {
            try Run(this.App.Config.StatePath)
            catch Error as failure
                this.App.ReportSettingsError(failure)
        }
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
