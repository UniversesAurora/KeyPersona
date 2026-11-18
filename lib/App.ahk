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
        this.NextWindowPrune := 0
        this.ObservationState := Map()
        this.VerifiedKeyboard := 0
        this.CandidateSignature := ""
        this.CandidateSince := 0
        this.Restore := InputRestoration(this)
        this.Enforcement := InputEnforcement()
        this.InputPolicyRefreshNeeded := false
        this.ExplicitApply := 0
        this.ForegroundHwnd := -1
        this.PendingForeground := Map()
        this.ForegroundRetryUntil := 0
        this.RestoreInterrupted := false
        this.ShownHwnd := 0
        this.FocusEventHwnd := 0
        this.WindowCheckQueued := false
        this.BurstUntil := 0
        this.PollPeriod := 0
        this.InputCheck := 0
        this.ShuttingDown := false
        this.EventGui := Gui("+ToolWindow -Caption")
        this.EventGui.Title := AppInfo.Name " Event Sink"
        this.EventGui.Show("Hide")
        this.MessageCallback := ObjBindMethod(this, "OnWinEventMessage")
        this.WindowCallback := ObjBindMethod(this, "HandleWindowEvents")
        this.ForegroundRetryCallback := ObjBindMethod(this, "HandleWindowEvents", true)
        this.ConfirmCallback := ObjBindMethod(this, "ConfirmObservation")
        this.PollCallback := ObjBindMethod(this, "Poll")
        this.InputCheckCallback := ObjBindMethod(this, "CheckInputGesture")
        this.FlushCallback := ObjBindMethod(this, "FlushState")
        this.Hook := WindowWinEventHook(this.EventGui.Hwnd, KeyPersonaApp.EVENT_MESSAGE)
        this.InputKeys := InputChangeKeys(this.EventGui.Hwnd, ObjBindMethod(this, "QueueInputCheck"))
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
            this.Logger.Warn("Some window readiness events unavailable; using foreground events and timed checks")
        this.Logger.Info(AppInfo.Name " started" (this.ObserveOnly ? " in observe-only mode" : ""))
        this.SyncDiscoveredProfiles()
        this.Punctuation.RefreshBindings()
        this.QueueWindowCheck()
    }

    OnWinEventMessage(wParam, lParam, message, receiverHwnd) {
        if this.ShuttingDown
            return 0
        if (lParam = WindowWinEventHook.EVENT_OBJECT_FOCUS) {
            if !this.Restore.Pending && !this.ExplicitApply && !this.PollPeriod && !this.PendingForeground.Count
                return 0
            this.FocusEventHwnd := wParam
        } else if (lParam = WindowWinEventHook.EVENT_OBJECT_SHOW) {
            this.ShownHwnd := wParam
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

    HandleWindowEvents(retry := false) {
        if !retry
            this.WindowCheckQueued := false
        if this.ShuttingDown
            return
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        focusEvent := this.FocusEventHwnd
        this.FocusEventHwnd := 0
        shown := this.ShownHwnd
        this.ShownHwnd := 0
        focusSignal := foreground && focusEvent
            && (foreground = focusEvent || DllCall("user32\IsChild", "Ptr", foreground, "Ptr", focusEvent, "Int"))
        if (foreground != this.ForegroundHwnd || this.InputPolicyRefreshNeeded
            || (foreground = MapGet(this.PendingForeground, "hwnd", 0) && (retry || shown = foreground || focusSignal))
            || (retry && !foreground)) {
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
        pending := Map()
        nextWindow := foreground ? this.Identity.Resolve(foreground, &pending) : Map()
        transient := !nextWindow.Count && !pending.Count && this.Identity.IsTransientForeground(foreground)
        if (foreground != previousForeground) {
            if transient && this.Restore.Pending
                this.RestoreInterrupted := true
            this.CancelInputCheck()
            this.Restore.Cancel()
            this.CandidateSignature := ""
            this.ForegroundRetryUntil := TickCount64() + 1500
        }
        if (DllCall("user32\GetForegroundWindow", "Ptr") != foreground) {
            this.ForegroundHwnd := -1
            this.QueueWindowCheck()
            return
        }
        if !nextWindow.Count {
            if !transient {
                if pending.Count && !KeyPersonaApp.IsSameTopLevelWindow(this.PendingForeground, pending)
                    this.Logger.Debug("Foreground window pending: hwnd=" pending["hwnd"])
                this.PendingForeground := pending
                this.RestoreInterrupted := false
                this.CurrentWindow := Map()
                this.CurrentState := Map()
                this.ObservationState := Map()
                this.Enforcement.SetTarget("", Map())
            }
            this.SetPollPeriod(0)
            remaining := this.ForegroundRetryUntil - TickCount64()
            if (pending.Count || !foreground) && remaining > 0
                SetTimer(this.ForegroundRetryCallback, -Min(remaining, remaining > 1250 ? 60 : 250))
            else
                SetTimer(this.ForegroundRetryCallback, 0)
            return
        }
        if KeyPersonaApp.IsSameTopLevelWindow(this.PendingForeground, nextWindow)
            this.Logger.Debug("Foreground window ready: hwnd=" nextWindow["hwnd"])
        this.PendingForeground := Map()
        SetTimer(this.ForegroundRetryCallback, 0)
        resumeRestore := this.RestoreInterrupted
        this.RestoreInterrupted := false
        this.PruneClosedWindows()
        sameWindow := KeyPersonaApp.IsSameTopLevelWindow(this.CurrentWindow, nextWindow)
            && this.CurrentWindow["class"] = nextWindow["class"]
            && this.CurrentWindow["appIdentity"] = nextWindow["appIdentity"]
        if sameWindow && !this.InputPolicyRefreshNeeded && !resumeRestore {
            this.CurrentWindow["title"] := nextWindow["title"]
            this.BeginBurst()
            if !this.ApplyQueuedSelection(this.CurrentWindow)
                this.ObserveCurrentWindow()
            return
        }
        this.InputPolicyRefreshNeeded := false
        hwndKey := nextWindow["hwnd"] ""
        original := MapGet(this.SessionWindows, hwndKey, Map())
        if !this.ReuseSessionIdentity(nextWindow, original) && this.SessionStates.Has(hwndKey)
            this.SessionStates.Delete(hwndKey)
        this.SessionWindows[hwndKey] := nextWindow
        this.Restore.Cancel()
        this.ObservationState := Map()
        this.CandidateSignature := ""
        this.CurrentWindow := nextWindow
        this.CurrentState := Map()
        matchedRule := this.MatchRule(nextWindow)
        if this.ApplyQueuedSelection(nextWindow)
            return
        desired := this.SelectDesiredState(nextWindow, matchedRule, true)
        this.SetEnforcedTarget(nextWindow, desired)
        this.BeginBurst()
        this.Logger.Debug("Foreground: " WindowIdentity.AppLabel(nextWindow) " [" nextWindow["mode"] "]"
            . (matchedRule.Count ? " rule=" matchedRule["name"] : ""))
        if this.ObserveOnly || !desired.Count || !this.CanSwitch(nextWindow) {
            if this.CanRemember(nextWindow)
                this.SetObservationBaseline(nextWindow, this.ReadState(nextWindow))
            return
        }
        reason := MapGet(desired, "source", "") = "learned" ? "restore" : "default"
        this.ApplyState(nextWindow, desired, reason, focusSignal)
    }

    DeferInterruptedRestore(windowInfo) {
        if KeyPersonaApp.IsSameTopLevelWindow(this.CurrentWindow, windowInfo)
            this.RestoreInterrupted := true
    }

    ReuseSessionIdentity(windowInfo, previous) {
        if !previous.Count || previous["pid"] != windowInfo["pid"] || previous["threadId"] != windowInfo["threadId"]
            || previous["class"] != windowInfo["class"] || previous["exe"] != windowInfo["exe"]
            || MapGet(previous, "appIdentity", "") != MapGet(windowInfo, "appIdentity", "")
            return false
        for field in ["identityKey", "legacyIdentityKey", "mode", "normalizedTitle", "memoryInitialized"] {
            if previous.Has(field)
                windowInfo[field] := previous[field]
        }
        return true
    }

    PruneClosedWindows() {
        now := TickCount64()
        if now < this.NextWindowPrune
            return
        this.NextWindowPrune := now + 30000
        closed := []
        for hwndKey, windowInfo in this.SessionWindows {
            if !this.Identity.IsCurrentWindow(windowInfo)
                closed.Push(hwndKey)
        }
        for hwndKey in closed {
            this.SessionWindows.Delete(hwndKey)
            if this.SessionStates.Has(hwndKey)
                this.SessionStates.Delete(hwndKey)
        }
    }

    SelectDesiredState(windowInfo, matchedRule, initialize := false) {
        hwndKey := MapGet(windowInfo, "hwnd", 0) ""
        sessionState := Map()
        savedState := Map()
        defaultState := Map()
        remember := this.CanRemember(windowInfo)
        if remember {
            sessionState := MapGet(this.SessionStates, hwndKey, Map())
            if !sessionState.Count && !MapGet(windowInfo, "memoryInitialized", false)
                savedState := this.Store.Find(windowInfo)
            defaultState := this.Config.GetNamedState(this.Config.DefaultState)
        }
        desired := KeyPersonaApp.ChooseDesiredState(remember, sessionState, savedState, matchedRule, defaultState)
        if remember && initialize {
            windowInfo["memoryInitialized"] := true
            if !sessionState.Count && MapGet(desired, "source", "") = "learned"
                this.SessionStates[hwndKey] := StateClone(desired)
        }
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
            && MapGet(left, "pid", 0) = MapGet(right, "pid", 0)
            && MapGet(left, "threadId", 0) = MapGet(right, "threadId", 0)
    }

    MatchRule(windowInfo) {
        windowRule := this.Config.GetWindowRule(windowInfo)
        if windowRule.Count
            return windowRule
        return this.MatchInheritedRule(windowInfo)
    }

    MatchInheritedRule(windowInfo) {
        applicationRule := this.Rules.Match(windowInfo)
        if MapGet(applicationRule, "rank", 0) < 4 {
            legacyRule := this.Config.GetWindowRule(windowInfo, true)
            if legacyRule.Count
                return legacyRule
        }
        if applicationRule.Count
            applicationRule["scope"] := "application"
        return applicationRule
    }

    RefreshRuleEngine() {
        this.Rules := RuleEngine(this.Config, this.Logger)
        this.Identity.Rules := this.Rules
    }

    ApplyState(windowInfo, desiredState, reason := "restore", focusSignal := false) {
        if !this.CanSwitch(windowInfo) || this.ShuttingDown || this.ObserveOnly || !desiredState.Count
            return
        this.ObservationState := Map()
        this.VerifiedKeyboard := 0
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

    ReadState(windowInfo, focus := unset, enforcedTarget := unset, desiredState := unset) {
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
            profileId := StrLower(profile["profile"])
            readDetails := IsSet(desiredState) ? ImeMode.NeedsDetailedMode(desiredState)
                : (InputProfiles.LanguageId(profileId) & 0x03FF) = 0x11 || this.Config.DetailedProfiles.Has(profileId)
                    || (KeyPersonaApp.SameInputProfile(this.ObservationState, profile)
                        && ImeMode.NeedsDetailedMode(this.ObservationState))
            mode := this.Mode.Read(windowInfo, MapGet(profile, "kind", "unknown"), focus, readDetails)
        } else {
            mode := Map()
            open := MapGet(enforcedTarget, "imeOpen", "unknown")
            if ((open = "0" || open = "1") && ImeMode.Supports(profile["kind"])
                && KeyPersonaApp.SameInputProfile(profile, enforcedTarget))
                mode["imeOpen"] := this.Mode.ReadOpenStatus(windowInfo, this.Config.MessageTimeoutMs, focus)
        }
        if (!this.Identity.IsForegroundFocus(windowInfo, focus)
            || profile["hkl"] != "0x" Hex(InputProfiles.GetThreadLayout(focus["threadId"])))
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

    CaptureMenuContext() {
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        pending := Map()
        windowInfo := foreground ? this.Identity.Resolve(foreground, &pending) : Map()
        transient := !windowInfo.Count && !pending.Count && this.Identity.IsTransientForeground(foreground)
        actual := Map()
        cached := false
        if transient {
            if this.Identity.IsCurrentWindow(this.PendingForeground) {
                candidate := this.PendingForeground
                windowInfo := this.Identity.Resolve(candidate["hwnd"], &pending)
                if !KeyPersonaApp.IsSameTopLevelWindow(windowInfo, candidate)
                    windowInfo := Map()
            } else if this.Identity.IsCurrentWindow(this.CurrentWindow) {
                windowInfo := this.Identity.AssignIdentity(StateClone(this.CurrentWindow))
                if windowInfo["appIdentity"] != this.CurrentWindow["appIdentity"] && windowInfo.Has("memoryInitialized")
                    windowInfo.Delete("memoryInitialized")
                actual := this.CurrentState
                cached := actual.Count > 0
            }
        }
        if windowInfo.Count {
            this.ReuseSessionIdentity(windowInfo, MapGet(this.SessionWindows, windowInfo["hwnd"] "", Map()))
            if !transient
                actual := this.ReadState(windowInfo)
        }
        return {window: windowInfo, actual: actual, cached: cached, waiting: pending.Count > 0}
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
        if (foreground != this.ForegroundHwnd || this.InputPolicyRefreshNeeded) {
            this.QueueWindowCheck()
            return
        }
        if !foreground || foreground != MapGet(this.CurrentWindow, "hwnd", 0)
            return
        if this.Restore.Pending && this.Restore.Pending.waitedForFocus
            && TickCount64() >= this.Restore.Pending.focusReadyUntil
            this.Restore.Advance()
        else
            this.ObserveCurrentWindow(true)
        if this.PollPeriod && !this.Enforcement.Target.Count && this.PollPeriod != this.Config.IdlePollMs
            && TickCount64() >= this.BurstUntil
            this.SetPollPeriod(this.Config.IdlePollMs)
    }

    ObserveCurrentWindow(periodic := false) {
        windowInfo := this.CurrentWindow
        if !windowInfo.Count || this.Restore.Pending
            return
        target := this.Enforcement.Target
        remember := this.CanRemember(windowInfo)
        if !remember && !target.Count
            return
        previous := this.ObservationState
        verified := this.VerifiedKeyboard
        if periodic && verified && verified.window = windowInfo && verified.target = target
            && this.CandidateSignature = "" && verified.revision = this.Profiles.Revision {
            focus := this.Identity.GetForegroundFocus(windowInfo)
            if focus.Count && focus["focused"] && focus["hwnd"] = verified.focusHwnd
                && focus["threadId"] = verified.threadId
                && InputProfiles.GetThreadLayout(focus["threadId"]) = verified.hkl
                return
        }
        actual := target.Count ? this.ReadState(windowInfo, focus?, target) : this.ReadState(windowInfo)
        if (this.ShuttingDown || this.Restore.Pending || this.Enforcement.Target != target
            || this.CanRemember(windowInfo) != remember
            || this.CurrentWindow != windowInfo || this.ObservationState != previous)
            return
        this.VerifiedKeyboard := 0
        if !HasKnownProfile(actual) {
            this.CurrentState := actual
            this.CandidateSignature := ""
            return
        }
        if actual.Has("hkl") && (!target.Count || StateMatches(actual, target))
            && this.Profiles.CanVerifyKeyboardWithLayout(actual) {
            this.VerifiedKeyboard := {window: windowInfo, target: target, hkl: Integer(actual["hkl"]),
                focusHwnd: actual["focusHwnd"], threadId: actual["focusThreadId"], revision: this.Profiles.Revision}
        }
        if this.ObserveOnly {
            this.SetObservationBaseline(windowInfo, actual)
            return
        }
        if target.Count {
            this.ObserveEnforcedState(windowInfo, actual, target)
            return
        }
        this.ObserveMemoryState(windowInfo, actual)
    }

    ObserveMemoryState(windowInfo, actual) {
        previous := this.ObservationState
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
    }

    QueueInputCheck() {
        if this.ShuttingDown || !this.PollPeriod || !this.CurrentWindow.Count
            return
        if this.Restore.Pending {
            this.Restore.NoteInputGesture(this.CurrentWindow)
            return
        }
        this.InputCheck := {window: this.CurrentWindow, followup: false}
        SetTimer(this.InputCheckCallback, -1)
    }

    CheckInputGesture() {
        pending := this.InputCheck
        if !pending
            return
        if this.ShuttingDown || this.Restore.Pending || !this.PollPeriod
            || pending.window != this.CurrentWindow
            || DllCall("user32\GetForegroundWindow", "Ptr") != pending.window["hwnd"] {
            this.CancelInputCheck()
            return
        }
        this.ObserveCurrentWindow()
        if this.InputCheck != pending
            return
        ; Layout activation can complete after the shortcut has already been released.
        if !pending.followup && !this.Restore.Pending && this.CandidateSignature = "" {
            pending.followup := true
            SetTimer(this.InputCheckCallback, -80)
        } else {
            this.InputCheck := 0
        }
    }

    CancelInputCheck() {
        this.InputCheck := 0
        SetTimer(this.InputCheckCallback, 0)
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
        if !period
            this.CancelInputCheck()
        if !this.ObserveOnly && !this.InputKeys.SetEnabled(period > 0 && this.CurrentWindow.Count > 0)
            this.Logger.Debug("Input shortcut notifications unavailable; polling is still active")
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

    ToggleAppForce(exe, *) {
        mode := !this.Config.IsAppInputForced(exe) ? "1"
            : this.Config.GetInheritedAppInputOption(exe, "force") ? "0" : "inherit"
        this.SetAppInputOption(exe, "force", mode)
    }

    SetAppPathIsolation(windowInfo, enabled, *) {
        Critical "On"
        if !this.ValidateMenuTarget(windowInfo) || !WindowIdentity.CanIsolateInstallation(windowInfo)
            return
        path := windowInfo["path"]
        try changed := this.Config.SetPathIsolation(path, enabled)
        catch Error as failure {
            this.ReportSettingsError(failure)
            return
        }
        if !changed
            return
        this.RefreshRuleEngine()
        pathKey := KeyPersonaConfig.AppPathKey(path)
        affected := []
        for hwndKey, sessionWindow in this.SessionWindows {
            if KeyPersonaConfig.AppPathKey(MapGet(sessionWindow, "path", "")) = pathKey
                affected.Push(hwndKey)
        }
        for hwndKey in affected {
            this.SessionWindows.Delete(hwndKey)
            if this.SessionStates.Has(hwndKey)
                this.SessionStates.Delete(hwndKey)
        }
        if this.ExplicitApply && KeyPersonaConfig.AppPathKey(MapGet(this.ExplicitApply.window, "path", "")) = pathKey
            this.ExplicitApply := 0
        if KeyPersonaConfig.AppPathKey(MapGet(this.CurrentWindow, "path", "")) = pathKey {
            this.Restore.Cancel()
            this.CancelInputCheck()
            this.RestoreInterrupted := false
            this.ObservationState := Map()
            this.VerifiedKeyboard := 0
            this.CandidateSignature := ""
            this.Enforcement.SetTarget("", Map())
            this.InputPolicyRefreshNeeded := true
        }
        this.Punctuation.RefreshBindings()
        this.QueueWindowCheck()
    }

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
        this.CancelInputCheck()
        this.ExplicitApply := 0
        this.ObservationState := Map()
        this.CandidateSignature := ""
        if !this.CurrentWindow.Count {
            this.SetPollPeriod(0)
            this.QueueWindowCheck()
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
    }

    ValidateMenuTarget(windowInfo) {
        if this.Identity.IsCurrentWindow(windowInfo)
            && DllCall("user32\IsWindowVisible", "Ptr", windowInfo["hwnd"], "Int")
            return true
        TrayTip("该窗口已关闭。", AppInfo.Name, "Mute")
        return false
    }

    AfterTargetEdit(windowInfo, desired, reason) {
        if KeyPersonaApp.IsSameTopLevelWindow(windowInfo, this.CurrentWindow) {
            this.Restore.Cancel()
            this.ExplicitApply := 0
            this.ObservationState := Map()
            this.CandidateSignature := ""
            this.SetEnforcedTarget(windowInfo, desired)
            this.BeginBurst()
        }
        if desired.Count
            this.QueueExplicitApply(windowInfo, desired, reason)
    }

    ReportSettingsError(failure) {
        this.Logger.Error("Could not save settings: " failure.Message)
        TrayTip("无法保存设置。请检查程序目录是否可写。", AppInfo.Name, "Iconx")
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
        try {
            if !this.Config.RemoveWindowRule(windowInfo)
                throw Error("Could not remove the window rule")
        } catch Error as failure {
            this.ReportSettingsError(failure)
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
        try SetTimer(this.ForegroundRetryCallback, 0)
        try SetTimer(this.ConfirmCallback, 0)
        try SetTimer(this.PollCallback, 0)
        try this.CancelInputCheck()
        try this.InputKeys.SetEnabled(false)
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
