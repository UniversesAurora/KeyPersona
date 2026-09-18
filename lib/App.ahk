#Requires AutoHotkey v2.0

class KeyPersonaApp {
    static EVENT_MESSAGE := 0x8001

    __New(baseDir, observeOnly := false) {
        this.BaseDir := baseDir
        this.ObserveOnly := observeOnly
        LegacyMigration.MigrateRuntimeFiles(baseDir)
        this.Config := KeyPersonaConfig(baseDir)
        this.Logger := Logger(this.Config.LogPath, this.Config.LogLevel)
        this.Startup := StartupManager(this.Logger)
        this.Identity := WindowIdentity(this.Config, this.Logger)
        this.Profiles := InputProfiles(this.Identity, this.Config, this.Logger)
        catalogResult := this.Config.ReconcileDiscoveredStates(
            this.Profiles.LastRefreshSucceeded ? this.Profiles.Catalog : Map()
        )
        this.SyncedProfileRevision := this.Profiles.Revision
        this.LogCatalogResult(catalogResult)
        this.Mode := ImeMode(this.Identity, this.Config, this.Logger)
        this.Rules := RuleEngine(this.Config, this.Logger)
        this.Store := StateStore(this.Config.StatePath, this.Logger)
        removedRecords := catalogResult["authoritative"]
            ? this.Store.RemoveInvalidProfiles(catalogResult["validProfiles"]) : 0
        if removedRecords {
            this.Logger.Info("Removed " removedRecords " remembered state(s) for unavailable input profiles")
            this.Store.Flush()
        }
        this.Enabled := this.Config.Enabled
        this.CurrentWindow := Map()
        this.CurrentState := Map()
        this.CurrentRule := Map()
        this.CurrentSource := ""
        this.SessionStates := Map()
        this.SessionWindows := Map()
        this.LastSamples := Map()
        this.StableCounts := Map()
        this.Suppressions := Map()
        this.DesiredStates := Map()
        this.RetryAllowed := Map()
        this.ProfilePolicyRefreshNeeded := false
        this.ApplyGeneration := 0
        this.ForegroundSequence := 0
        this.PendingForegroundHwnd := 0
        this.PendingForegroundDue := 0
        this.BurstUntil := 0
        this.PollPeriod := 0
        this.Started := false
        this.ShuttingDown := false
        this.EventGui := Gui("+ToolWindow -Caption")
        this.EventGui.Title := AppInfo.Name " Event Sink"
        this.EventGui.Show("Hide")
        this.MessageCallback := ObjBindMethod(this, "OnWinEventMessage")
        this.PollCallback := ObjBindMethod(this, "Poll")
        this.FlushCallback := ObjBindMethod(this, "FlushState")
        this.Hook := ForegroundWinEventHook(this.EventGui.Hwnd, KeyPersonaApp.EVENT_MESSAGE, this.Logger)
        this.BacktickKey := BacktickKeyController(this)
        this.Tray := TrayMenuController(this)
    }

    Start() {
        try this.Startup.MigrateLegacy()
        catch Error as migrationError
            this.Logger.Error("Startup migration failed: " migrationError.Message)
        OnMessage(KeyPersonaApp.EVENT_MESSAGE, this.MessageCallback)
        this.Hook.Start()
        this.Started := true
        this.Logger.Info(AppInfo.Name " started" (this.ObserveOnly ? " in observe-only mode" : ""))
        this.Tray.Refresh(true)
        if this.Enabled {
            if this.Config.AutoMemory
                this.SetPollPeriod(this.Config.ActivePollMs)
            this.QueueForegroundSwitch()
        }
    }

    OnWinEventMessage(wParam, lParam, message, receiverHwnd) {
        if !this.Enabled || this.ShuttingDown
            return 0
        this.QueueForegroundSwitch(wParam)
        return 0
    }

    QueueForegroundSwitch(eventHwnd := 0, delayMs := "") {
        if !this.Enabled || this.ShuttingDown
            return
        if !eventHwnd
            eventHwnd := DllCall("user32\GetForegroundWindow", "Ptr")
        if !eventHwnd
            return
        if (delayMs = "")
            delayMs := this.Config.ForegroundSettleMs
        now := TickCount64()
        if (this.PendingForegroundHwnd = eventHwnd && now < this.PendingForegroundDue)
            return
        this.ForegroundSequence += 1
        sequence := this.ForegroundSequence
        this.PendingForegroundHwnd := eventHwnd
        this.PendingForegroundDue := now + delayMs
        SetTimer(ObjBindMethod(this, "CommitForegroundSwitch", sequence, eventHwnd), -delayMs)
    }

    CommitForegroundSwitch(sequence, eventHwnd) {
        if (sequence != this.ForegroundSequence || !this.Enabled || this.ShuttingDown)
            return
        this.PendingForegroundHwnd := 0
        this.PendingForegroundDue := 0
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        if (foreground != eventHwnd) {
            this.QueueForegroundSwitch(foreground)
            return
        }
        this.SwitchToForeground(foreground)
    }

    SwitchToForeground(eventHwnd := 0) {
        if !this.Enabled || this.ShuttingDown
            return
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        nextWindow := this.Identity.Resolve(foreground)
        if !nextWindow.Count
            return
        hwnd := nextWindow["hwnd"]
        currentHwnd := MapGet(this.CurrentWindow, "hwnd", 0)
        if (currentHwnd = hwnd) {
            if this.ProfilePolicyRefreshNeeded {
                this.ProfilePolicyRefreshNeeded := false
                this.CurrentRule := this.MatchRule(nextWindow)
                desired := this.SelectDesiredState(nextWindow, this.CurrentRule)
                this.CurrentSource := MapGet(desired, "source", "")
                this.BeginBurst()
                if this.ObserveOnly {
                    this.CurrentState := this.ReadState(nextWindow)
                    this.Tray.Refresh(true)
                } else if !desired.Count {
                    this.CurrentState := this.ReadState(nextWindow)
                    this.CurrentSource := "observed"
                    this.Tray.Refresh(true)
                } else {
                    this.ApplyState(nextWindow, desired, "profile-catalog")
                }
                return
            }
            this.BeginBurst()
            return
        }
        if this.CurrentWindow.Count
            this.ObserveWindow(this.CurrentWindow, "leave", true)
        hwndKey := hwnd ""
        if this.SessionWindows.Has(hwndKey) {
            original := this.SessionWindows[hwndKey]
            nextWindow["identityKey"] := original["identityKey"]
            nextWindow["mode"] := original["mode"]
            nextWindow["normalizedTitle"] := original["normalizedTitle"]
        } else {
            this.SessionWindows[hwndKey] := StateClone(nextWindow)
        }
        this.CurrentWindow := nextWindow
        this.CurrentRule := this.MatchRule(nextWindow)
        desired := this.SelectDesiredState(nextWindow, this.CurrentRule)
        this.CurrentSource := MapGet(desired, "source", "")
        this.Logger.Info("Foreground: " nextWindow["exe"] " [" nextWindow["mode"] "]"
            . (this.CurrentRule.Count ? " rule=" this.CurrentRule["name"] : ""))
        this.BeginBurst()
        if this.ObserveOnly {
            this.CurrentState := this.ReadState(nextWindow)
            this.Tray.Refresh(true)
            return
        }
        if !desired.Count {
            this.CurrentState := this.ReadState(nextWindow)
            this.CurrentSource := "observed"
            this.Tray.Refresh(true)
            return
        }
        reason := MapGet(desired, "source", "") = "learned" ? "restore" : "default"
        this.ApplyState(nextWindow, desired, reason)
    }

    SelectDesiredState(windowInfo, matchedRule) {
        hwndKey := MapGet(windowInfo, "hwnd", 0) ""
        sessionState := Map()
        savedState := Map()
        defaultState := Map()
        if this.Config.AutoMemory {
            if this.SessionStates.Has(hwndKey)
                sessionState := this.SessionStates[hwndKey]
            savedState := this.Store.Find(windowInfo)
            if (savedState.Count && !HasKnownProfile(savedState))
                this.Logger.Debug("Ignored saved state with unknown profile for " MapGet(windowInfo, "exe", ""))
            defaultState := this.Config.GetNamedState(this.Config.DefaultState)
            if !defaultState.Count {
                this.Logger.Warn("Unknown defaultState '" this.Config.DefaultState "'; falling back to English US")
                defaultState := this.Config.GetNamedState("english-us")
            }
        }
        desired := KeyPersonaApp.ChooseDesiredState(
            this.Config.AutoMemory, sessionState, savedState, matchedRule, defaultState)
        if (this.Config.AutoMemory && desired.Count
            && MapGet(desired, "source", "") = "learned")
            this.SessionStates[hwndKey] := StateClone(desired)
        return desired
    }

    static ChooseDesiredState(autoMemory, sessionState, savedState, matchedRule, defaultState) {
        if (autoMemory && sessionState.Count && HasKnownProfile(sessionState))
            return StateClone(sessionState)
        if (autoMemory && savedState.Count && HasKnownProfile(savedState)) {
            state := StateClone(savedState)
            state["source"] := "learned"
            return state
        }
        if matchedRule.Count {
            state := StateClone(matchedRule["state"])
            state["source"] := "rule"
            return state
        }
        if !autoMemory || !defaultState.Count
            return Map()
        state := StateClone(defaultState)
        state["source"] := "default"
        return state
    }

    MatchRule(windowInfo) {
        windowRule := this.Config.GetWindowRule(windowInfo)
        if windowRule.Count
            return windowRule
        applicationRule := this.Rules.Match(windowInfo)
        if applicationRule.Count
            applicationRule["scope"] := "application"
        return applicationRule
    }

    RefreshRuleEngine() {
        this.Rules := RuleEngine(this.Config, this.Logger)
    }

    ApplyState(windowInfo, desiredState, reason := "restore") {
        if this.ObserveOnly || !windowInfo.Count || !desiredState.Count
            return
        hwnd := windowInfo["hwnd"]
        hwndKey := hwnd ""
        actual := this.ReadState(windowInfo)
        if !HasKnownProfile(actual) {
            this.CurrentState := actual
            this.Logger.Debug("Skip " reason " for " MapGet(windowInfo, "exe", "") ": current profile is unknown")
            this.Tray.Refresh()
            return
        }
        if StateMatches(actual, desiredState) {
            this.CurrentState := actual
            if this.Config.AutoMemory {
                this.SessionStates[hwndKey] := StateClone(desiredState)
                this.LastSamples[hwndKey] := StateSignature(actual)
                this.StableCounts[hwndKey] := 1
            }
            this.Logger.Debug("Skip " reason " for " MapGet(windowInfo, "exe", "") ": state already matches")
            this.Tray.Refresh()
            return
        }
        this.ApplyGeneration += 1
        generation := this.ApplyGeneration
        this.DesiredStates[hwndKey] := StateClone(desiredState)
        this.RetryAllowed[hwndKey] := this.Config.AutoMemory
            && MapGet(desiredState, "source", "") = "learned"
        if this.Config.AutoMemory {
            this.Suppressions[hwndKey] := TickCount64() + this.Config.ApplySuppressMs
            this.SessionStates[hwndKey] := StateClone(desiredState)
        }
        profileChanged := StrLower(MapGet(actual, "profile", "")) != StrLower(MapGet(desiredState, "profile", ""))
        if profileChanged
            this.Profiles.Switch(windowInfo, desiredState)
        delay := profileChanged ? 70 : 10
        this.Logger.Debug("Apply " reason " to " MapGet(windowInfo, "exe", "") ": " StateLabel(desiredState))
        SetTimer(ObjBindMethod(this, "FinishApply", generation, hwnd, 0), -delay)
    }

    FinishApply(generation, hwnd, retryCount) {
        if (generation != this.ApplyGeneration || this.ShuttingDown)
            return
        current := this.Identity.Resolve()
        if !current.Count || current["hwnd"] != hwnd
            return
        hwndKey := hwnd ""
        if !this.DesiredStates.Has(hwndKey)
            return
        desired := this.DesiredStates[hwndKey]
        profile := this.Profiles.ParseProfile(MapGet(desired, "profile", ""))
        actualProfile := this.Profiles.Read(current)
        if (profile.Count && profile["kind"] = "tip"
            && HasKnownProfile(actualProfile)
            && StrLower(actualProfile["profile"]) = StrLower(profile["id"]))
            this.Mode.Apply(current, desired)
        SetTimer(ObjBindMethod(this, "VerifyApply", generation, hwnd, retryCount), -160)
    }

    VerifyApply(generation, hwnd, retryCount) {
        if (generation != this.ApplyGeneration || this.ShuttingDown)
            return
        current := this.Identity.Resolve()
        if !current.Count || current["hwnd"] != hwnd
            return
        hwndKey := hwnd ""
        if !this.DesiredStates.Has(hwndKey)
            return
        desired := this.DesiredStates[hwndKey]
        actual := this.ReadState(current)
        this.CurrentState := actual
        if !HasKnownProfile(actual) {
            this.Logger.Debug("Apply verification skipped for " MapGet(current, "exe", "") ": current profile is unknown")
            this.CompleteApplyTracking(hwndKey)
            this.Tray.Refresh()
            return
        }
        if StateMatches(actual, desired) {
            if this.Config.AutoMemory {
                this.LastSamples[hwndKey] := StateSignature(actual)
                this.StableCounts[hwndKey] := 1
            }
            this.Logger.Debug("Apply verified for " current["exe"])
            this.CompleteApplyTracking(hwndKey)
            this.Tray.Refresh()
            return
        }
        if (retryCount < 1 && MapGet(this.RetryAllowed, hwndKey, false)) {
            this.Logger.Debug("Apply verification mismatch; retrying once")
            this.Profiles.Switch(current, desired)
            SetTimer(ObjBindMethod(this, "FinishApply", generation, hwnd, retryCount + 1), -90)
            return
        }
        this.Logger.Warn("Could not verify desired input state for " current["exe"]
            . "; actual=" StateLabel(actual) "; desired=" StateLabel(desired))
        this.CompleteApplyTracking(hwndKey)
        this.Tray.Refresh()
    }

    CompleteApplyTracking(hwndKey) {
        if this.DesiredStates.Has(hwndKey)
            this.DesiredStates.Delete(hwndKey)
        if this.RetryAllowed.Has(hwndKey)
            this.RetryAllowed.Delete(hwndKey)
    }

    ReadState(windowInfo) {
        profile := this.Profiles.Read(windowInfo)
        this.SyncDiscoveredProfiles()
        if (HasKnownProfile(profile)
            && !this.Profiles.Catalog.Has(StrLower(MapGet(profile, "profile", "")))) {
            profile["profile"] := MapGet(profile, "langId", "0000") ":unknown"
            profile["kind"] := "unknown"
        }
        mode := this.Mode.Read(windowInfo, MapGet(profile, "kind", "unknown"))
        return Map(
            "profile", MapGet(profile, "profile", "unknown"),
            "kind", MapGet(profile, "kind", "unknown"),
            "langId", MapGet(profile, "langId", "0000"),
            "hkl", MapGet(profile, "hkl", "0x0"),
            "imeOpen", MapGet(mode, "imeOpen", "unknown"),
            "conversion", MapGet(mode, "conversion", "unknown"),
            "sentence", MapGet(mode, "sentence", "unknown")
        )
    }

    RefreshInputProfiles(*) {
        this.Profiles.RefreshCatalog()
        return this.SyncDiscoveredProfiles()
    }

    RefreshCurrentStateForMenu(*) {
        if !this.CurrentWindow.Count
            return
        foreground := this.Identity.Resolve()
        if !foreground.Count || foreground["hwnd"] != this.CurrentWindow["hwnd"]
            return
        actual := this.ReadState(this.CurrentWindow)
        this.CurrentState := actual
        this.CurrentRule := this.MatchRule(this.CurrentWindow)
        if !this.Config.AutoMemory {
            this.CurrentSource := this.CurrentRule.Count
                && StateMatches(actual, this.CurrentRule["state"]) ? "rule" : "observed"
        }
    }

    SyncDiscoveredProfiles() {
        if (this.SyncedProfileRevision = this.Profiles.Revision)
            return 0
        result := this.Config.ReconcileDiscoveredStates(
            this.Profiles.LastRefreshSucceeded ? this.Profiles.Catalog : Map()
        )
        this.SyncedProfileRevision := this.Profiles.Revision
        removedRecords := result["authoritative"]
            ? this.Store.RemoveInvalidProfiles(result["validProfiles"]) : 0
        removedRuntime := result["authoritative"]
            ? this.RemoveInvalidRuntimeStates(result["validProfiles"]) : 0
        policyChanged := result["removedStates"] || result["removedRules"]
            || result["repointedRules"] || result["defaultChanged"]
            || removedRecords || removedRuntime
        if (result["added"] || policyChanged)
            this.RefreshRuleEngine()
        if removedRecords
            this.ScheduleFlush()
        if policyChanged {
            this.ProfilePolicyRefreshNeeded := true
            if this.CurrentWindow.Count {
                this.CurrentRule := this.MatchRule(this.CurrentWindow)
                desired := this.SelectDesiredState(this.CurrentWindow, this.CurrentRule)
                this.CurrentSource := MapGet(desired, "source", "")
            }
        }
        this.LogCatalogResult(result, removedRecords)
        return result["added"] + result["removedStates"] + result["removedRules"]
            + result["repointedRules"] + removedRecords + removedRuntime
    }

    RemoveInvalidRuntimeStates(validProfiles) {
        removed := 0
        for stateMap in [this.SessionStates, this.DesiredStates] {
            invalidKeys := []
            for hwndKey, state in stateMap {
                profileId := StrLower(Trim(MapGet(state, "profile", "") ""))
                if !validProfiles.Has(profileId)
                    invalidKeys.Push(hwndKey)
            }
            for hwndKey in invalidKeys {
                stateMap.Delete(hwndKey)
                removed += 1
            }
        }
        return removed
    }

    LogCatalogResult(result, removedRecords := 0) {
        changed := result["added"] + result["removedStates"] + result["removedRules"]
            + result["repointedRules"] + removedRecords
        if !changed && !result["defaultChanged"]
            return
        this.Logger.Info("Input profile reconciliation: added=" result["added"]
            . ", removedStates=" result["removedStates"]
            . ", removedRules=" result["removedRules"]
            . ", repointedRules=" result["repointedRules"]
            . ", removedMemories=" removedRecords
            . ", defaultChanged=" (result["defaultChanged"] ? "yes" : "no"))
    }

    Poll() {
        if !this.Enabled || !this.Config.AutoMemory || this.ShuttingDown
            return
        foreground := this.Identity.Resolve()
        if !foreground.Count
            return
        if (!this.CurrentWindow.Count || foreground["hwnd"] != this.CurrentWindow["hwnd"]) {
            this.QueueForegroundSwitch(foreground["hwnd"])
            return
        }
        if this.ProfilePolicyRefreshNeeded {
            this.SwitchToForeground(foreground["hwnd"])
            return
        }
        this.ObserveWindow(this.CurrentWindow, "poll", false)
        if (this.PollPeriod != this.Config.IdlePollMs && TickCount64() >= this.BurstUntil)
            this.SetPollPeriod(this.Config.IdlePollMs)
    }

    ObserveWindow(windowInfo, reason, leaving := false) {
        if !windowInfo.Count || !this.Config.AutoMemory
            return
        hwndKey := windowInfo["hwnd"] ""
        now := TickCount64()
        if (this.Suppressions.Has(hwndKey) && now < this.Suppressions[hwndKey])
            return
        actual := this.ReadState(windowInfo)
        if !HasKnownProfile(actual)
            return
        if this.ObserveOnly {
            if (!leaving && windowInfo["hwnd"] = MapGet(this.CurrentWindow, "hwnd", 0)) {
                this.CurrentState := actual
                this.CurrentRule := this.MatchRule(windowInfo)
                this.CurrentSource := this.CurrentRule.Count ? "rule" : "observed"
                this.Tray.Refresh()
            }
            return
        }
        matchedRule := this.MatchRule(windowInfo)
        signature := StateSignature(actual)
        if (this.LastSamples.Has(hwndKey) && this.LastSamples[hwndKey] = signature)
            this.StableCounts[hwndKey] := MapGet(this.StableCounts, hwndKey, 0) + 1
        else {
            this.LastSamples[hwndKey] := signature
            this.StableCounts[hwndKey] := 1
        }
        required := leaving ? 1 : 2
        if (this.StableCounts[hwndKey] < required)
            return
        oldState := this.SessionStates.Has(hwndKey) ? this.SessionStates[hwndKey] : Map()
        changed := !oldState.Count || StateSignature(oldState) != signature
        if changed {
            actual["source"] := "learned"
            this.SessionStates[hwndKey] := StateClone(actual)
            this.Store.Upsert(windowInfo, actual, "learned")
            this.ScheduleFlush()
            this.Logger.Info("Learned " windowInfo["exe"] ": " StateLabel(actual))
        } else {
            actual["source"] := MapGet(oldState, "source", "learned")
            this.SessionStates[hwndKey] := StateClone(actual)
        }
        if (!leaving && windowInfo["hwnd"] = MapGet(this.CurrentWindow, "hwnd", 0)) {
            this.CurrentState := actual
            this.CurrentRule := matchedRule
            this.CurrentSource := MapGet(actual, "source", "learned")
            this.Tray.Refresh()
        }
    }

    BeginBurst() {
        if !this.Enabled || !this.Config.AutoMemory
            return
        this.BurstUntil := TickCount64() + this.Config.BurstDurationMs
        this.SetPollPeriod(this.Config.ActivePollMs)
    }

    SetPollPeriod(period) {
        if (this.PollPeriod = period)
            return
        this.PollPeriod := period
        SetTimer(this.PollCallback, period)
    }

    ScheduleFlush() {
        SetTimer(this.FlushCallback, -this.Config.SaveDebounceMs)
    }

    FlushState(*) {
        this.Store.Flush()
    }

    ToggleEnabled(*) {
        this.Enabled := !this.Enabled
        if this.Enabled {
            this.Logger.Info("Enabled")
            if this.Config.AutoMemory
                this.SetPollPeriod(this.Config.ActivePollMs)
            this.QueueForegroundSwitch()
        } else {
            this.Logger.Info("Disabled")
            SetTimer(this.PollCallback, 0)
            this.PollPeriod := 0
            this.ForegroundSequence += 1
            this.PendingForegroundHwnd := 0
            this.PendingForegroundDue := 0
        }
        this.Tray.Refresh(true)
    }

    ToggleAutoMemory(*) {
        enabled := this.Config.SetAutoMemory(!this.Config.AutoMemory)
        if enabled && this.Enabled {
            this.BeginBurst()
        } else {
            SetTimer(this.PollCallback, 0)
            this.PollPeriod := 0
        }
        this.Logger.Info("Automatic memory " (enabled ? "enabled" : "disabled"))
        TrayTip(enabled
            ? "已开启自动记忆。手动切换后的输入法会保存到当前窗口。"
            : "已关闭自动记忆。只在进入窗口时执行用户规则，不会限制手动切换。",
            AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    SetCurrentState(stateName) {
        if !this.CurrentWindow.Count
            return
        state := this.Config.GetNamedState(stateName)
        if !state.Count
            return
        if !this.Config.SetWindowRule(this.CurrentWindow, stateName) {
            TrayTip("无法保存当前窗口的用户规则。", AppInfo.Name, "Iconx")
            return
        }
        this.RefreshRuleEngine()
        hwndKey := this.CurrentWindow["hwnd"] ""
        if this.Store.Remove(this.CurrentWindow)
            this.ScheduleFlush()
        if this.SessionStates.Has(hwndKey)
            this.SessionStates.Delete(hwndKey)
        if this.LastSamples.Has(hwndKey)
            this.LastSamples.Delete(hwndKey)
        if this.StableCounts.Has(hwndKey)
            this.StableCounts.Delete(hwndKey)
        state["source"] := "rule"
        this.CurrentRule := this.MatchRule(this.CurrentWindow)
        this.CurrentSource := "rule"
        this.ApplyState(this.CurrentWindow, state, "window-default")
        TrayTip("已设置当前窗口的默认输入法；旧自动记忆已清除。", AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    UseGlobalForCurrentWindow(*) {
        if !this.CurrentWindow.Count
            return
        saved := this.Store.Find(this.CurrentWindow)
        legacyManual := MapGet(saved, "source", "") = "manual"
        hasWindowRule := this.Config.GetWindowRule(this.CurrentWindow).Count > 0
        applicationRule := this.Rules.Match(this.CurrentWindow)
        if (!hasWindowRule && !applicationRule.Count && !legacyManual)
            return

        removedCount := 0
        if this.Config.RemoveWindowRule(this.CurrentWindow) {
            removedCount += 1
        }
        this.RefreshRuleEngine()
        Loop 20 {
            applicationRule := this.Rules.Match(this.CurrentWindow)
            if !applicationRule.Count
                break
            if !this.Config.RemoveApplicationRule(applicationRule["name"])
                break
            removedCount += 1
            this.RefreshRuleEngine()
        }
        if legacyManual {
            this.Store.Remove(this.CurrentWindow)
            this.ScheduleFlush()
            removedCount += 1
        }
        hwndKey := this.CurrentWindow["hwnd"] ""
        if (this.SessionStates.Has(hwndKey)
            && MapGet(this.SessionStates[hwndKey], "source", "") = "rule")
            this.SessionStates.Delete(hwndKey)
        this.CurrentRule := this.MatchRule(this.CurrentWindow)
        desired := this.SelectDesiredState(this.CurrentWindow, this.CurrentRule)
        this.CurrentSource := MapGet(desired, "source", "")
        if !this.ObserveOnly && desired.Count
            this.ApplyState(this.CurrentWindow, desired, "rule-removed")
        else if !desired.Count {
            this.CurrentState := this.ReadState(this.CurrentWindow)
            this.CurrentSource := "observed"
        }
        if removedCount
            TrayTip("已移除当前窗口的用户规则；自动记忆保持不变。", AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    SetDefaultState(stateName) {
        if !this.Config.SetDefaultState(stateName)
            return
        this.Logger.Info("Default state changed to " stateName)
        TrayTip("全局默认输入法已设置为 " stateName "。`n仅用于尚未记录的窗口。", AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    ToggleStartup(*) {
        try {
            enabled := this.Startup.Toggle()
            TrayTip(enabled ? "已启用当前用户登录时自动启动。" : "已关闭开机自启动。", AppInfo.Name, "Mute")
        } catch Error as toggleFailure {
            this.Logger.Error("Startup toggle failed: " toggleFailure.Message)
            TrayTip("无法修改开机自启动：" toggleFailure.Message, AppInfo.Name, "Iconx")
        }
        this.Tray.Refresh(true)
    }

    ToggleBacktickInChinese(*) {
        enabled := this.Config.SetBacktickInChinese(!this.Config.BacktickInChinese)
        this.Logger.Info("Chinese-mode backtick replacement " (enabled ? "enabled" : "disabled"))
        TrayTip(enabled ? "已开启：中文输入模式下，单独按反引号键将直接输入反引号。"
            : "已关闭中文模式反引号修正。", AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    ClearCurrentRecord(*) {
        if !this.CurrentWindow.Count
            return
        hwndKey := this.CurrentWindow["hwnd"] ""
        saved := this.Store.Find(this.CurrentWindow)
        sessionSource := this.SessionStates.Has(hwndKey)
            ? MapGet(this.SessionStates[hwndKey], "source", "") : ""
        hasSessionMemory := sessionSource = "learned" || sessionSource = "manual"
        if (!saved.Count && !hasSessionMemory) {
            TrayTip("当前窗口没有可清除的自动记忆。", AppInfo.Name, "Mute")
            return
        }
        if saved.Count
            this.Store.Remove(this.CurrentWindow)
        if this.SessionStates.Has(hwndKey)
            this.SessionStates.Delete(hwndKey)
        if this.LastSamples.Has(hwndKey)
            this.LastSamples.Delete(hwndKey)
        if this.StableCounts.Has(hwndKey)
            this.StableCounts.Delete(hwndKey)
        this.ScheduleFlush()
        rule := this.MatchRule(this.CurrentWindow)
        desired := this.SelectDesiredState(this.CurrentWindow, rule)
        this.CurrentSource := MapGet(desired, "source", "")
        if !this.ObserveOnly && desired.Count
            this.ApplyState(this.CurrentWindow, desired, "clear")
        else if !desired.Count {
            this.CurrentState := this.ReadState(this.CurrentWindow)
            this.CurrentSource := "observed"
        }
        this.Tray.Refresh(true)
    }

    ClearAllRecords(*) {
        if MsgBox("清除所有窗口的自动记忆？`n`n用户规则、命名输入法和全局默认设置会保留。",
            AppInfo.Name, "YesNo Icon!") != "Yes"
            return
        removed := this.Store.ClearAll()
        this.ApplyGeneration += 1
        this.SessionStates := Map()
        this.LastSamples := Map()
        this.StableCounts := Map()
        this.Suppressions := Map()
        this.DesiredStates := Map()
        this.RetryAllowed := Map()
        if !this.Store.Flush() {
            TrayTip("无法保存清除结果，请检查程序目录是否可写。", AppInfo.Name, "Iconx")
            this.Tray.Refresh(true)
            return
        }
        if this.CurrentWindow.Count {
            this.CurrentState := this.ReadState(this.CurrentWindow)
            this.CurrentRule := this.MatchRule(this.CurrentWindow)
            this.CurrentSource := "observed"
        }
        this.Logger.Info("Cleared all automatic memories: " removed " persisted record(s)")
        TrayTip("已清除所有自动记忆；用户规则和全局默认设置保持不变。", AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    ReloadConfiguration(*) {
        this.FlushState()
        Reload()
    }

    Shutdown(*) {
        if this.ShuttingDown
            return
        this.ShuttingDown := true
        try SetTimer(this.PollCallback, 0)
        try SetTimer(this.FlushCallback, 0)
        try this.Hook.Stop()
        try OnMessage(KeyPersonaApp.EVENT_MESSAGE, this.MessageCallback, 0)
        try this.BacktickKey.Dispose()
        try this.Tray.Dispose()
        try this.Store.Flush()
        this.Logger.Info(AppInfo.Name " stopped")
    }
}
