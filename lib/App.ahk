#Requires AutoHotkey v2.0

class ImeMemoryApp {
    static EVENT_MESSAGE := 0x8001

    __New(baseDir, observeOnly := false) {
        this.BaseDir := baseDir
        this.ObserveOnly := observeOnly
        this.Config := ImeMemoryConfig(baseDir)
        this.Logger := Logger(this.Config.LogPath, this.Config.LogLevel)
        this.Identity := WindowIdentity(this.Config, this.Logger)
        this.Profiles := InputProfiles(this.Identity, this.Config, this.Logger)
        this.Mode := ImeMode(this.Identity, this.Config, this.Logger)
        this.Rules := RuleEngine(this.Config, this.Logger)
        this.Store := StateStore(this.Config.StatePath, this.Logger)
        this.Enabled := this.Config.Enabled
        this.CurrentWindow := Map()
        this.CurrentState := Map()
        this.CurrentRule := Map()
        this.SessionStates := Map()
        this.SessionWindows := Map()
        this.LastSamples := Map()
        this.StableCounts := Map()
        this.Suppressions := Map()
        this.DesiredStates := Map()
        this.ApplyGeneration := 0
        this.BurstUntil := 0
        this.PollPeriod := 0
        this.Started := false
        this.ShuttingDown := false
        this.EventGui := Gui("+ToolWindow -Caption")
        this.EventGui.Title := "IME Memory Event Sink"
        this.EventGui.Show("Hide")
        this.MessageCallback := ObjBindMethod(this, "OnWinEventMessage")
        this.PollCallback := ObjBindMethod(this, "Poll")
        this.FlushCallback := ObjBindMethod(this, "FlushState")
        this.Hook := ForegroundWinEventHook(this.EventGui.Hwnd, ImeMemoryApp.EVENT_MESSAGE, this.Logger)
        this.Tray := TrayMenuController(this)
    }

    Start() {
        OnMessage(ImeMemoryApp.EVENT_MESSAGE, this.MessageCallback)
        this.Hook.Start()
        this.Started := true
        this.Logger.Info("IME Memory started" (this.ObserveOnly ? " in observe-only mode" : ""))
        this.Tray.Refresh(true)
        if this.Enabled {
            this.SetPollPeriod(this.Config.ActivePollMs)
            SetTimer(ObjBindMethod(this, "SwitchToForeground"), -20)
        }
    }

    OnWinEventMessage(wParam, lParam, message, receiverHwnd) {
        if !this.Enabled || this.ShuttingDown
            return 0
        SetTimer(ObjBindMethod(this, "SwitchToForeground", wParam), -15)
        return 0
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
        this.CurrentRule := this.Rules.Match(nextWindow)
        desired := this.SelectDesiredState(nextWindow, this.CurrentRule)
        this.Logger.Info("Foreground: " nextWindow["exe"] " [" nextWindow["mode"] "]"
            . (this.CurrentRule.Count ? " rule=" this.CurrentRule["name"] : ""))
        this.BeginBurst()
        if this.ObserveOnly {
            this.CurrentState := this.ReadState(nextWindow)
            this.Tray.Refresh(true)
            return
        }
        this.ApplyState(nextWindow, desired, this.CurrentRule.Count ? "rule" : "restore")
    }

    SelectDesiredState(windowInfo, matchedRule) {
        hwndKey := MapGet(windowInfo, "hwnd", 0) ""
        if matchedRule.Count
            return StateClone(matchedRule["state"])
        if this.SessionStates.Has(hwndKey)
            return StateClone(this.SessionStates[hwndKey])
        saved := this.Store.Find(windowInfo)
        if (saved.Count && HasKnownProfile(saved)) {
            this.SessionStates[hwndKey] := StateClone(saved)
            return saved
        }
        if saved.Count
            this.Logger.Debug("Ignored saved state with unknown profile for " MapGet(windowInfo, "exe", ""))
        state := this.Config.GetNamedState(this.Config.DefaultState)
        if !state.Count {
            this.Logger.Warn("Unknown defaultState '" this.Config.DefaultState "'; falling back to English US")
            state := this.Config.GetNamedState("english-us")
        }
        this.SessionStates[hwndKey] := StateClone(state)
        return state
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
            this.SessionStates[hwndKey] := StateClone(desiredState)
            this.LastSamples[hwndKey] := StateSignature(actual)
            this.StableCounts[hwndKey] := 1
            this.Logger.Debug("Skip " reason " for " MapGet(windowInfo, "exe", "") ": state already matches")
            this.Tray.Refresh()
            return
        }
        this.ApplyGeneration += 1
        generation := this.ApplyGeneration
        this.DesiredStates[hwndKey] := StateClone(desiredState)
        this.Suppressions[hwndKey] := TickCount64() + this.Config.ApplySuppressMs
        this.SessionStates[hwndKey] := StateClone(desiredState)
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
            this.Tray.Refresh()
            return
        }
        if StateMatches(actual, desired) {
            this.LastSamples[hwndKey] := StateSignature(actual)
            this.StableCounts[hwndKey] := 1
            this.Logger.Debug("Apply verified for " current["exe"])
            this.Tray.Refresh()
            return
        }
        if (retryCount < 1) {
            this.Logger.Debug("Apply verification mismatch; retrying once")
            this.Profiles.Switch(current, desired)
            SetTimer(ObjBindMethod(this, "FinishApply", generation, hwnd, retryCount + 1), -90)
            return
        }
        this.Logger.Warn("Could not verify desired input state for " current["exe"]
            . "; actual=" StateLabel(actual) "; desired=" StateLabel(desired))
        this.Tray.Refresh()
    }

    ReadState(windowInfo) {
        profile := this.Profiles.Read(windowInfo)
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

    Poll() {
        if !this.Enabled || this.ShuttingDown
            return
        foreground := this.Identity.Resolve()
        if !foreground.Count
            return
        if (!this.CurrentWindow.Count || foreground["hwnd"] != this.CurrentWindow["hwnd"]) {
            this.SwitchToForeground(foreground["hwnd"])
            return
        }
        this.ObserveWindow(this.CurrentWindow, "poll", false)
        if (this.PollPeriod != this.Config.IdlePollMs && TickCount64() >= this.BurstUntil)
            this.SetPollPeriod(this.Config.IdlePollMs)
    }

    ObserveWindow(windowInfo, reason, leaving := false) {
        if !windowInfo.Count
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
                this.CurrentRule := this.Rules.Match(windowInfo)
                this.Tray.Refresh()
            }
            return
        }
        matchedRule := this.Rules.Match(windowInfo)
        if matchedRule.Count {
            if (!leaving && !this.ObserveOnly && !StateMatches(actual, matchedRule["state"]))
                this.ApplyState(windowInfo, matchedRule["state"], "force-rule")
            if (!leaving && windowInfo["hwnd"] = MapGet(this.CurrentWindow, "hwnd", 0)) {
                this.CurrentState := actual
                this.CurrentRule := matchedRule
                this.Tray.Refresh()
            }
            return
        }
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
        this.SessionStates[hwndKey] := StateClone(actual)
        if changed {
            this.Store.Upsert(windowInfo, actual)
            this.ScheduleFlush()
            this.Logger.Info("Learned " windowInfo["exe"] ": " StateLabel(actual))
        }
        if (!leaving && windowInfo["hwnd"] = MapGet(this.CurrentWindow, "hwnd", 0)) {
            this.CurrentState := actual
            this.CurrentRule := Map()
            this.Tray.Refresh()
        }
    }

    BeginBurst() {
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
            this.SetPollPeriod(this.Config.ActivePollMs)
            this.SwitchToForeground()
        } else {
            this.Logger.Info("Disabled")
            SetTimer(this.PollCallback, 0)
            this.PollPeriod := 0
        }
        this.Tray.Refresh(true)
    }

    SetCurrentState(stateName) {
        if !this.CurrentWindow.Count
            return
        if this.CurrentRule.Count {
            TrayTip("当前窗口命中了强制规则，不能用自动记忆覆盖。", "IME Memory")
            return
        }
        state := this.Config.GetNamedState(stateName)
        if !state.Count
            return
        hwndKey := this.CurrentWindow["hwnd"] ""
        this.SessionStates[hwndKey] := StateClone(state)
        this.Store.Upsert(this.CurrentWindow, state)
        this.ScheduleFlush()
        this.ApplyState(this.CurrentWindow, state, "tray")
        this.Tray.Refresh(true)
    }

    ClearCurrentRecord(*) {
        if !this.CurrentWindow.Count
            return
        hwndKey := this.CurrentWindow["hwnd"] ""
        this.Store.Remove(this.CurrentWindow)
        if this.SessionStates.Has(hwndKey)
            this.SessionStates.Delete(hwndKey)
        this.ScheduleFlush()
        rule := this.Rules.Match(this.CurrentWindow)
        desired := this.SelectDesiredState(this.CurrentWindow, rule)
        if !this.ObserveOnly
            this.ApplyState(this.CurrentWindow, desired, "clear")
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
        try OnMessage(ImeMemoryApp.EVENT_MESSAGE, this.MessageCallback, 0)
        try this.Store.Flush()
        this.Logger.Info("IME Memory stopped")
    }
}
