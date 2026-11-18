#Requires AutoHotkey v2.0

class KeyPersonaApp {
    static EVENT_MESSAGE := 0x8001

    __New(baseDir, observeOnly := false) {
        this.ObserveOnly := observeOnly
        if !observeOnly
            LegacyMigration.MigrateRuntimeFiles(baseDir)
        this.Config := KeyPersonaConfig(baseDir, observeOnly)
        this.Logger := Logger(this.Config.LogPath, this.Config.LogLevel)
        this.Startup := StartupManager(this.Logger, this.Config.RunAsAdmin)
        this.Rules := RuleEngine(this.Config, this.Logger)
        this.Identity := WindowIdentity(this.Config, this.Rules)
        this.Profiles := InputProfiles(this.Identity, this.Logger)
        this.SyncedProfileRevision := -1
        this.ProfileSyncInProgress := false
        this.FailedProfileRevision := -1
        this.ProfileCleanupRevision := -1
        this.ProfileSyncCallback := ObjBindMethod(this, "RefreshInputProfiles")
        this.Mode := ImeMode(this.Identity, this.Config)
        this.Store := StateStore(this.Config.StatePath, this.Logger)
        this.CurrentWindow := Map()
        this.CurrentState := Map()
        this.SessionStates := Map()
        this.SessionWindows := Map()
        this.ObservationState := Map()
        this.CandidateSignature := ""
        this.CandidateSince := 0
        this.Restore := InputRestoration(this)
        this.Enforcement := InputEnforcement()
        this.ProfilePolicyRefreshNeeded := false
        this.ExplicitApply := 0
        this.ForegroundHwnd := -1
        this.FocusEventHwnd := 0
        this.WindowCheckQueued := false
        this.BurstUntil := 0
        this.PollPeriod := 0
        this.Started := false
        this.ShuttingDown := false
        this.EventGui := Gui("+ToolWindow -Caption")
        this.EventGui.Title := AppInfo.Name " Event Sink"
        this.EventGui.Show("Hide")
        this.MessageCallback := ObjBindMethod(this, "OnWinEventMessage")
        this.WindowCallback := ObjBindMethod(this, "HandleWindowEvents")
        this.ConfirmCallback := ObjBindMethod(this, "ConfirmObservation")
        this.PollCallback := ObjBindMethod(this, "Poll")
        this.FlushCallback := ObjBindMethod(this, "FlushState")
        this.Hook := WindowWinEventHook(this.EventGui.Hwnd, KeyPersonaApp.EVENT_MESSAGE)
        this.Punctuation := PunctuationController(this)
        this.Tray := TrayMenuController(this)
        this.Tray := observeOnly ? 0 : TrayMenuController(this)
    }

    Start() {
        if !this.ObserveOnly {
            try this.Startup.MigrateLegacy()
            catch Error as migrationError
                this.Logger.Error("Startup migration failed: " migrationError.Message)
        }
        OnMessage(KeyPersonaApp.EVENT_MESSAGE, this.MessageCallback)
        if !this.Hook.Start()
            this.Logger.Warn("Control focus events unavailable; using foreground events and timed checks")
        this.Started := true
        this.Logger.Info(AppInfo.Name " started" (this.ObserveOnly ? " in observe-only mode" : ""))
        this.SyncDiscoveredProfiles()
        this.Punctuation.RefreshBindings()
        this.QueueWindowCheck()
    }

    OnWinEventMessage(wParam, lParam, message, receiverHwnd) {
        if this.ShuttingDown
            return 0
        if (lParam = WindowWinEventHook.EVENT_SYSTEM_FOREGROUND) {
            if (wParam != this.ForegroundHwnd) {
                this.Restore.Cancel()
                this.CandidateSignature := ""
            }
        } else if (lParam = WindowWinEventHook.EVENT_OBJECT_FOCUS) {
            if !this.Restore.Pending && !this.ExplicitApply && !this.PollPeriod
                return 0
            this.FocusEventHwnd := wParam
        }
        this.QueueWindowCheck()
        return 0
    }

    QueueWindowCheck() {
        if this.WindowCheckQueued || this.ShuttingDown
            return
        this.WindowCheckQueued := true
        SetTimer(this.WindowCallback, -1)
    }

    HandleWindowEvents() {
        this.WindowCheckQueued := false
        if !this.Enabled || this.ShuttingDown
            return
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        focusEvent := this.FocusEventHwnd
        this.FocusEventHwnd := 0
        focusSignal := foreground && focusEvent
            && (foreground = focusEvent || DllCall("user32\IsChild", "Ptr", foreground, "Ptr", focusEvent, "Int"))
        if (foreground != this.ForegroundHwnd || this.ProfilePolicyRefreshNeeded) {
            this.SwitchToForeground(foreground, focusSignal)
            return
        }
        if !foreground || foreground != MapGet(this.CurrentWindow, "hwnd", 0)
            return
        if this.ApplyQueuedSelection(this.CurrentWindow)
            return
        if focusSignal && this.Restore.Pending
            this.Restore.Advance(true)
        else if focusSignal
            this.ObserveCurrentWindow()
    }

    SwitchToForeground(foreground, focusSignal := false) {
        previousForeground := this.ForegroundHwnd
        this.ForegroundHwnd := foreground
        if (foreground != previousForeground) {
            this.Restore.Cancel()
            this.CandidateSignature := ""
        }
        nextWindow := foreground ? this.Identity.Resolve(foreground) : Map()
        if (DllCall("user32\GetForegroundWindow", "Ptr") != foreground) {
            this.ForegroundHwnd := -1
            this.QueueWindowCheck()
            return
        }
        if !nextWindow.Count {
            this.SetPollPeriod(!foreground && (this.Config.AutoMemory || this.Enforcement.Target.Count)
                ? this.Config.IdlePollMs : 0)
            return
        }
        sameWindow := KeyPersonaApp.IsSameTopLevelWindow(this.CurrentWindow, nextWindow)
            && this.CurrentWindow["pid"] = nextWindow["pid"] && this.CurrentWindow["threadId"] = nextWindow["threadId"]
        if sameWindow && !this.ProfilePolicyRefreshNeeded {
            this.BeginBurst()
            if !this.ApplyQueuedSelection(this.CurrentWindow)
                this.ObserveCurrentWindow()
            return
        }
        this.ProfilePolicyRefreshNeeded := false
        hwndKey := nextWindow["hwnd"] ""
        original := MapGet(this.SessionWindows, hwndKey, Map())
        if original.Count && original["pid"] = nextWindow["pid"]
            && original["threadId"] = nextWindow["threadId"] && original["class"] = nextWindow["class"] {
            nextWindow["identityKey"] := original["identityKey"]
            nextWindow["mode"] := original["mode"]
            nextWindow["normalizedTitle"] := original["normalizedTitle"]
        } else {
            if this.SessionStates.Has(hwndKey)
                this.SessionStates.Delete(hwndKey)
            this.SessionWindows[hwndKey] := StateClone(nextWindow)
        }
        this.Restore.Cancel()
        this.ObservationState := Map()
        this.CandidateSignature := ""
        this.CurrentWindow := nextWindow
        this.CurrentState := Map()
        matchedRule := this.MatchRule(nextWindow)
        if this.ApplyQueuedSelection(nextWindow)
            return
        desired := this.SelectDesiredState(nextWindow, this.CurrentRule)
        this.SetEnforcedTarget(nextWindow, desired)
        this.BeginBurst()
            . (matchedRule.Count ? " rule=" matchedRule["name"] : ""))
        if this.ObserveOnly || !desired.Count || !this.CanSwitch(nextWindow) {
            if this.CanRemember(nextWindow)
                this.SetObservationBaseline(nextWindow, this.ReadState(nextWindow))
            return
        }
        reason := MapGet(desired, "source", "") = "learned" ? "restore" : "default"
        this.ApplyState(nextWindow, desired, reason, focusSignal)
    }

    SelectDesiredState(windowInfo, matchedRule) {
        hwndKey := MapGet(windowInfo, "hwnd", 0) ""
        sessionState := Map()
        savedState := Map()
        defaultState := Map()
        remember := this.CanRemember(windowInfo)
        if remember {
            if this.SessionStates.Has(hwndKey)
                sessionState := this.SessionStates[hwndKey]
            savedState := this.Store.Find(windowInfo)
            if (savedState.Count && !HasKnownProfile(savedState))
                this.Logger.Debug("Ignored saved state with unknown profile for " MapGet(windowInfo, "exe", ""))
            defaultState := this.Config.GetNamedState(this.Config.DefaultState)
        }
        desired := KeyPersonaApp.ChooseDesiredState(
            remember, sessionState, savedState, matchedRule, defaultState)
        if (remember && desired.Count
            && MapGet(desired, "source", "") = "learned")
            this.SessionStates[hwndKey] := StateClone(desired)
        return desired
    }

    CanRemember(windowInfo) {
        return windowInfo.Count && this.Config.ResolveAppInputOption(WindowIdentity.AppSelectorFor(windowInfo), "autoMemory")
    }

    CanSwitch(windowInfo) {
        return windowInfo.Count && this.Config.ResolveAppInputOption(WindowIdentity.AppSelectorFor(windowInfo), "autoSwitch")
    }

    SetEnforcedTarget(windowInfo, desired) {
        exe := WindowIdentity.AppSelectorFor(windowInfo)
        this.Enforcement.SetTarget(exe, this.CanSwitch(windowInfo) && this.Config.IsAppInputForced(exe) ? desired : Map())
    }

    static ChooseDesiredState(autoMemory, sessionState, savedState, matchedRule, defaultState) {
        if autoMemory && sessionState.Count && HasKnownProfile(sessionState)
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

    static IsSameTopLevelWindow(left, right) {
        leftHwnd := MapGet(left, "hwnd", 0)
        return leftHwnd && leftHwnd = MapGet(right, "hwnd", 0)
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

    ApplyState(windowInfo, desiredState, reason := "restore", focusSignal := false) {
        if !this.CanSwitch(windowInfo) || this.ShuttingDown || this.ObserveOnly || !desiredState.Count
            return
        this.ObservationState := Map()
        this.CandidateSignature := ""
        target := this.Enforcement.Target
        this.Restore.Begin(windowInfo, target.Count ? target : desiredState,
            target.Count ? "enforce" : reason, focusSignal)
    }

    static SameInputProfile(left, right) {
        return HasKnownProfile(left) && StrLower(MapGet(left, "profile", "")) = StrLower(MapGet(right, "profile", ""))
    }

    static CompareObservation(previous, actual) {
        merged := StateClone(actual)
        if !KeyPersonaApp.SameInputProfile(previous, actual)
            return {state: merged, changed: true}
        changed := false
        for field in ["imeOpen", "conversion", "sentence"] {
            before := MapGet(previous, field, "unknown")
            after := MapGet(actual, field, "unknown")
            if (after = "unknown")
                merged[field] := before
            else if (before != "unknown" && !ModeValuesEqual(before, after))
                changed := true
        }
        return {state: merged, changed: changed}
    }

    ReadState(windowInfo, focus := unset, enforcedTarget := unset) {
        if !IsSet(focus)
            focus := this.Identity.GetForegroundFocus(windowInfo)
        if !focus.Count || !focus["focused"] || !this.Identity.IsForegroundFocus(windowInfo, focus)
            return Map()
        profile := this.Profiles.Read(windowInfo, focus)
        this.SyncDiscoveredProfiles()
        if (HasKnownProfile(profile)
            && !this.Profiles.Catalog.Has(StrLower(MapGet(profile, "profile", "")))) {
            profile["profile"] := MapGet(profile, "langId", "0000") ":unknown"
            profile["kind"] := "unknown"
        }
        if !IsSet(enforcedTarget) {
            mode := this.Mode.Read(windowInfo, MapGet(profile, "kind", "unknown"), focus)
        } else {
            mode := Map()
            open := MapGet(enforcedTarget, "imeOpen", "unknown")
            if ((open = "0" || open = "1") && ImeMode.Supports(profile["kind"])
                && KeyPersonaApp.SameInputProfile(profile, enforcedTarget))
                mode["imeOpen"] := this.Mode.ReadOpenStatus(windowInfo, this.Config.MessageTimeoutMs, focus)
        }
        if (!this.Identity.IsForegroundFocus(windowInfo, focus)
            || profile["hkl"] != "0x" Hex(DllCall("user32\GetKeyboardLayout", "UInt", focus["threadId"], "Ptr")))
            return Map()
        return Map(
            "profile", MapGet(profile, "profile", "unknown"),
            "kind", MapGet(profile, "kind", "unknown"),
            "langId", MapGet(profile, "langId", "0000"),
            "hkl", MapGet(profile, "hkl", "0x0"),
            "imeOpen", MapGet(mode, "imeOpen", "unknown"),
            "conversion", MapGet(mode, "conversion", "unknown"),
            "sentence", MapGet(mode, "sentence", "unknown"),
            "focusHwnd", focus["hwnd"],
            "focusThreadId", focus["threadId"]
        )
    }

    RefreshInputProfiles(*) {
        this.Profiles.RefreshCatalog()
        return this.SyncDiscoveredProfiles(true)
    }

    RefreshCurrentStateForMenu(*) {
        if !this.CurrentWindow.Count
            return
        foreground := this.Identity.Resolve()
        if !KeyPersonaApp.IsSameTopLevelWindow(this.CurrentWindow, foreground)
            return
        actual := this.ReadState(this.CurrentWindow)
        if !actual.Count
            return
        this.CurrentState := actual
        this.CurrentRule := this.MatchRule(this.CurrentWindow)
        if !this.CanRemember(this.CurrentWindow) && !this.Enforcement.Target.Count {
            this.CurrentSource := this.CurrentRule.Count
                && StateMatches(actual, this.CurrentRule["state"]) ? "rule" : "observed"
        }
    }

    ResolveMenuPolicy(context) {
        windowInfo := context.window
        context.rule := windowInfo.Count ? this.MatchRule(windowInfo) : Map()
        context.desired := windowInfo.Count ? this.SelectDesiredState(windowInfo, context.rule) : Map()
        return context
    }

    SetObservationBaseline(windowInfo, actualState) {
        if !KeyPersonaApp.IsSameTopLevelWindow(this.CurrentWindow, windowInfo)
            return
        this.ObservationState := this.CanRemember(windowInfo) && HasKnownProfile(actualState)
            ? StateClone(actualState) : Map()
        this.CandidateSignature := ""
        this.CurrentState := actualState
    }

    SyncDiscoveredProfiles(refreshed := false) {
        revision := this.Profiles.Revision
        if this.ObserveOnly || this.ShuttingDown || this.ProfileSyncInProgress || this.SyncedProfileRevision = revision
            || (!refreshed && (this.FailedProfileRevision = revision || this.ProfileCleanupRevision = revision))
            return 0
        if this.ProfileCleanupRevision != revision && this.Profiles.LastRefreshSucceeded && this.CatalogMissingSavedProfile() {
            this.ProfileCleanupRevision := revision
            SetTimer(this.ProfileSyncCallback, -3000)
            return 0
        }
        this.ProfileSyncInProgress := true
        try return this.ReconcileProfileRevision(revision)
        catch Error as failure {
            this.FailedProfileRevision := revision
            this.Logger.Error("Could not update input profile settings: " failure.Message)
            SetTimer(this.ProfileSyncCallback, -10000)
            return 0
        } finally this.ProfileSyncInProgress := false
    }

    CatalogMissingSavedProfile() {
        catalog := this.Profiles.Catalog
        for entries in [this.Config.NamedStates, this.Store.Records] {
            for _, state in entries {
                if !catalog.Has(StrLower(MapGet(state, "profile", "")))
                    return true
            }
        }
        return false
    }

    ReconcileProfileRevision(revision) {
        result := this.Config.ReconcileDiscoveredStates(this.Profiles.Catalog, this.Profiles.LastRefreshSucceeded)
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
            this.InputPolicyRefreshNeeded := true
            this.QueueWindowCheck()
        }
        this.LogCatalogResult(result, removedRecords)
        this.SyncedProfileRevision := revision
        this.FailedProfileRevision := -1
        this.ProfileCleanupRevision := -1
        SetTimer(this.ProfileSyncCallback, 0)
        return result["added"] + result["removedStates"] + result["removedRules"]
            + result["repointedRules"] + removedRecords + removedRuntime
    }

    RemoveInvalidRuntimeStates(validProfiles) {
        invalidKeys := []
        for hwndKey, state in this.SessionStates {
            if !validProfiles.Has(StrLower(MapGet(state, "profile", "")))
                invalidKeys.Push(hwndKey)
        }
        for hwndKey in invalidKeys
            this.SessionStates.Delete(hwndKey)
        if this.Restore.Pending && !validProfiles.Has(StrLower(MapGet(this.Restore.Pending.desired, "profile", "")))
            this.Restore.Cancel()
        if this.ObservationState.Count && !validProfiles.Has(StrLower(this.ObservationState["profile"])) {
            this.ObservationState := Map()
            this.CandidateSignature := ""
        }
        return invalidKeys.Length
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
        if !this.PollPeriod || this.ShuttingDown
            return
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        if (foreground != this.ForegroundHwnd || this.ProfilePolicyRefreshNeeded) {
            this.QueueWindowCheck()
            return
        }
        if !foreground || foreground != MapGet(this.CurrentWindow, "hwnd", 0)
            return
        this.ObserveCurrentWindow()
        if !this.Enforcement.Target.Count && this.PollPeriod != this.Config.IdlePollMs
            && TickCount64() >= this.BurstUntil
            this.SetPollPeriod(this.Config.IdlePollMs)
    }

    ObserveCurrentWindow() {
        windowInfo := this.CurrentWindow
        if !windowInfo.Count || this.Restore.Pending
            return
        target := this.Enforcement.Target
        remember := this.CanRemember(windowInfo)
        if !remember && !target.Count
            return
        previous := this.ObservationState
        actual := target.Count ? this.ReadState(windowInfo,, target) : this.ReadState(windowInfo)
        if (!this.Enabled || this.Restore.Pending || this.Enforcement.Target != target
            || this.CanRemember(windowInfo) != remember
            || this.CurrentWindow != windowInfo || this.ObservationState != previous)
            return
        if !HasKnownProfile(actual) {
            this.CandidateSignature := ""
            return
        }
        if this.ObserveOnly {
            this.SetObservationBaseline(windowInfo, actual)
            return
        }
        if target.Count {
            this.ObserveEnforcedState(windowInfo, actual, target)
            return
        }
        if (!previous.Count || previous["focusHwnd"] != actual["focusHwnd"]
            || MapGet(previous, "focusThreadId", 0) != MapGet(actual, "focusThreadId", 0)) {
            this.SetObservationBaseline(windowInfo, actual)
            return
        }
        comparison := KeyPersonaApp.CompareObservation(previous, actual)
        if comparison.changed {
            signature := StateSignature(comparison.state)
            now := TickCount64()
            if (signature != this.CandidateSignature) {
                this.CandidateSignature := signature
                this.CandidateSince := now
                this.ScheduleObservationCheck(60)
                return
            }
            if (now - this.CandidateSince < 60) {
                this.ScheduleObservationCheck(60 - (now - this.CandidateSince))
                return
            }
            remembered := comparison.state
            remembered["source"] := "learned"
            this.SessionStates[windowInfo["hwnd"] ""] := StateClone(remembered)
            if this.Store.Upsert(windowInfo, remembered, "learned")
                this.ScheduleFlush()
            this.Logger.Info("Learned " windowInfo["exe"] ": " StateLabel(remembered))
        }
        this.SetObservationBaseline(windowInfo, comparison.state)
        this.CurrentState := actual
    }

    ObserveEnforcedState(windowInfo, actual, target) {
        now := TickCount64()
        matches := StateMatches(actual, target)
        if matches && this.Enforcement.Failures
            this.Enforcement.NoteResult(actual, now)
        if this.Enforcement.ShouldRestore(actual, now) {
            this.ApplyState(windowInfo, target, "enforce", true)
            return
        }
        this.CurrentState := actual
        this.CurrentSource := matches ? MapGet(target, "source", "observed") : "observed"
        this.Tray.Refresh()
    }

    ScheduleObservationCheck(delay) {
        SetTimer(this.ConfirmCallback, -Max(1, delay))
    }

    ConfirmObservation() {
        if this.PollPeriod && !this.ShuttingDown && this.CandidateSignature != ""
            this.ObserveCurrentWindow()
    }

    BeginBurst() {
        if this.Enforcement.Target.Count {
            this.SetPollPeriod(this.Config.ForcePollMs)
            return
        }
        if !this.CanRemember(this.CurrentWindow) {
            this.SetPollPeriod(0)
            return
        }
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
        if !this.Store.Flush() && !this.ShuttingDown
            SetTimer(this.FlushCallback, -Max(10000, this.Config.SaveDebounceMs))
    }

    ToggleEnabled(*) {
        wasSwitching := this.CanSwitch(this.CurrentWindow)
        try this.Config.SetAutoSwitch(!this.Config.Enabled)
        catch Error as failure {
            this.ReportSettingsError(failure)
            return
        }
        this.RefreshCurrentInputPolicy(!wasSwitching && this.CanSwitch(this.CurrentWindow))
    }

    ToggleAutoMemory(*) {
        try enabled := this.Config.SetAutoMemory(!this.Config.AutoMemory)
        catch Error as failure {
            this.ReportSettingsError(failure)
            return
        }
        this.RefreshCurrentInputPolicy()
        this.Logger.Info("Automatic memory " (enabled ? "enabled" : "disabled"))
        TrayTip(enabled
            ? "已开启全局自动记忆。各应用继续使用自己的输入法设置。"
            : "已关闭全局自动记忆。应用覆盖继续生效。",
            AppInfo.Name, "Mute")
    }

    ToggleAppInputOption(exe, option, *) {
        enabled := option = "excludeMemory" ? !this.Config.IsAppMemoryExcluded(exe) : !this.Config.IsAppInputForced(exe)
        try saved := this.Config.SetAppInputOption(exe, option, enabled)
        catch Error as failure {
            this.Logger.Error("Could not save input settings for " exe ": " failure.Message)
            saved := false
        }
        if !saved {
            TrayTip("无法保存此应用的输入法设置。", AppInfo.Name, "Iconx")
    SetAppInputOption(exe, option, mode, *) {
        if this.Config.GetAppInputOption(exe, option) = mode
            return
        wasSwitching := this.CanSwitch(this.CurrentWindow)
        try saved := this.Config.SetAppInputOption(exe, option, mode)
        catch Error as failure {
            this.ReportSettingsError(failure)
            return
        }
        if !saved
            return
        if WindowIdentity.AppSelectorFor(this.CurrentWindow) = exe
            this.RefreshCurrentInputPolicy(!wasSwitching && this.CanSwitch(this.CurrentWindow))
    }

    RefreshCurrentInputPolicy(reapply := false) {
        this.Restore.Cancel()
        this.ObservationState := Map()
        this.CandidateSignature := ""
        if !this.CurrentWindow.Count
            return
        }
        window := this.CurrentWindow
        desired := this.SelectDesiredState(window, this.MatchRule(window), true)
        this.SetEnforcedTarget(window, desired)
        this.BeginBurst()
        if reapply && desired.Count
            this.QueueExplicitApply(window, desired, "policy-enabled")
        else
            this.ObserveCurrentWindow()
    }

    SetCurrentState(windowInfo, stateName, *) {
        if !this.ValidateMenuTarget(windowInfo)
            return
        rule := this.Config.GetWindowRule(windowInfo)
        if MapGet(rule, "stateName", "") = stateName
            return
        state := this.Config.GetNamedState(stateName = "@global" ? this.Config.DefaultState : stateName)
        if !state.Count
            return
        try {
            if !this.Config.SetWindowRule(windowInfo, stateName)
                throw Error("Could not save the window rule")
        } catch Error as failure {
            this.ReportSettingsError(failure)
            return
        }
        this.RefreshRuleEngine()
        this.ForgetWindow(windowInfo)
        state["source"] := "rule"
        this.AfterTargetEdit(windowInfo, state, "window-default")
        TrayTip(this.CanSwitch(windowInfo) ? "已设置默认输入法，返回窗口后应用。" : "已保存默认输入法。",
            AppInfo.Name, "Mute")
        this.Tray.Refresh(true)
    }

    QueueExplicitApply(windowInfo, state, reason) {
        if !this.CanSwitch(windowInfo) || this.ObserveOnly
            return
        this.ExplicitApply := {
            window: windowInfo, state: StateClone(state), reason: reason, until: TickCount64() + 2000
        }
        this.QueueWindowCheck()
    }

    ApplyQueuedSelection(windowInfo) {
        selection := this.ExplicitApply
        if !selection
            return false
        this.ExplicitApply := 0
        if (!this.CanSwitch(windowInfo) || !KeyPersonaApp.IsSameTopLevelWindow(selection.window, windowInfo)
            || TickCount64() > selection.until
            || (!this.CanRemember(windowInfo) && MapGet(selection.state, "source", "") != "rule"))
            return false
        this.SetEnforcedTarget(windowInfo, selection.state)
        this.BeginBurst()
        this.ApplyState(windowInfo, selection.state, selection.reason, true)
        return true
    }

    UseInheritedWindowRule(windowInfo, *) {
        if !this.ValidateMenuTarget(windowInfo) || !this.Config.GetWindowRule(windowInfo).Count
            return
        saved := this.Store.Find(this.CurrentWindow)
        legacyManual := MapGet(saved, "source", "") = "manual"
        hasWindowRule := this.Config.GetWindowRule(this.CurrentWindow).Count > 0
        applicationRule := this.Rules.Match(this.CurrentWindow)
        if (!hasWindowRule && !applicationRule.Count && !legacyManual)
            return
        }
        this.RefreshRuleEngine()
        desired := this.SelectDesiredState(windowInfo, this.MatchRule(windowInfo))
        this.AfterTargetEdit(windowInfo, desired, "rule-removed")
        TrayTip("已移除此规则，恢复继承设置。", AppInfo.Name, "Mute")
    }

    SetDefaultState(stateName, *) {
        if this.Config.DefaultState = stateName
            return
        try {
            if !this.Config.SetDefaultState(stateName)
                return
        } catch Error as failure {
            this.ReportSettingsError(failure)
            return
        }
        this.RefreshCurrentInputPolicy()
        this.Logger.Info("Default state changed to " stateName)
        TrayTip("全局默认：" this.Tray.ShortState(this.Config.GetNamedState(stateName)), AppInfo.Name, "Mute")
    }

    ToggleRunAsAdmin(*) {
        try {
            if !this.Config.RunAsAdmin && !A_IsAdmin {
                if !this.Store.Flush()
                    throw Error("无法保存输入法记忆，暂缓重启。")
                ElevationManager.RequestRestart(RuntimeBaseDir(), true)
                ExitApp()
            }
            enabled := !this.Config.RunAsAdmin
            this.ApplyAdminPreference(enabled)
            TrayTip(enabled ? "以后将以管理员身份启动。" : "下次启动将使用默认权限。",
                AppInfo.Name, "Mute")
        } catch Error as failure {
            this.Logger.Warn("Administrator preference change did not complete: " failure.Message)
            TrayTip("未更改管理员设置。" failure.Message, AppInfo.Name, "Iconx")
        }
    }

    ApplyAdminPreference(enabled) {
        previous := this.Config.RunAsAdmin
        if previous = enabled
            return
        this.Startup.ChangeAdminMode(enabled)
        try this.Config.SetRunAsAdmin(enabled)
        catch Error as failure {
            try this.Startup.ChangeAdminMode(previous)
            throw failure
        }
    }

    ToggleStartup(*) {
        try {
            enabled := this.Startup.Toggle()
            TrayTip(enabled ? "已启用当前用户登录时自动启动。" : "已关闭开机自启动。", AppInfo.Name, "Mute")
        } catch Error as toggleFailure {
            this.Logger.Error("Startup toggle failed: " toggleFailure.Message)
            TrayTip("无法修改开机自启动：" toggleFailure.Message, AppInfo.Name, "Iconx")
        }
    }

    HasWindowMemory(windowInfo) {
        return this.SessionStates.Has(MapGet(windowInfo, "hwnd", 0) "") || this.Store.Find(windowInfo).Count
    }

    ForgetWindow(windowInfo) {
        hwndKey := windowInfo["hwnd"] ""
        if this.SessionStates.Has(hwndKey)
            this.SessionStates.Delete(hwndKey)
        if this.SessionWindows.Has(hwndKey)
            this.SessionWindows[hwndKey]["memoryInitialized"] := true
        windowInfo["memoryInitialized"] := true
        if this.Store.Remove(windowInfo) && !this.Store.Flush() {
            this.ScheduleFlush()
            TrayTip("记忆暂未写入磁盘，将再次尝试保存。", AppInfo.Name, "Mute")
        }
        this.Tray.Refresh(true)
    }

    ClearCurrentRecord(windowInfo, *) {
        if !this.ValidateMenuTarget(windowInfo) || !this.HasWindowMemory(windowInfo)
            return
        this.ForgetWindow(windowInfo)
        this.AfterTargetEdit(windowInfo, this.SelectDesiredState(windowInfo, this.MatchRule(windowInfo)), "clear")
    }

    }

    ClearAllRecords(*) {
        if MsgBox("清除所有窗口的自动记忆？`n`n用户规则、命名输入法和全局默认设置会保留。",
            AppInfo.Name, "YesNo Icon!") != "Yes"
            return
        removed := this.Store.ClearAll()
        this.Restore.Cancel()
        this.ExplicitApply := 0
        this.SessionStates := Map()
        this.ObservationState := Map()
        this.CandidateSignature := ""
        if !this.Store.Flush() {
            this.ScheduleFlush()
            TrayTip("无法保存清除结果，请检查程序目录是否可写。", AppInfo.Name, "Iconx")
            return
        }
        this.RefreshCurrentInputPolicy()
        this.Logger.Info("Cleared all automatic memories: " removed " persisted record(s)")
        TrayTip("已清除所有自动记忆；用户规则和全局默认设置保持不变。", AppInfo.Name, "Mute")
    }

    ReloadConfiguration(*) {
        if this.Store.Flush()
            Reload()
        else
            TrayTip("无法保存输入法记忆，暂缓重新加载。", AppInfo.Name, "Iconx")
    }

    Shutdown(*) {
        if this.ShuttingDown
            return
        this.ShuttingDown := true
        this.Restore.Cancel()
        this.ExplicitApply := 0
        try SetTimer(this.WindowCallback, 0)
        try SetTimer(this.ConfirmCallback, 0)
        try SetTimer(this.PollCallback, 0)
        try SetTimer(this.FlushCallback, 0)
        try SetTimer(this.ProfileSyncCallback, 0)
        try this.Hook.Stop()
        try OnMessage(KeyPersonaApp.EVENT_MESSAGE, this.MessageCallback, 0)
        try this.Punctuation.Dispose()
        try this.Tray.Dispose()
        if !this.ObserveOnly
            try this.Store.Flush()
        this.Logger.Info(AppInfo.Name " stopped")
    }
}
