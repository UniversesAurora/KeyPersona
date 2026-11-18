#Requires AutoHotkey v2.0

class InputRestoration {
    __New(app) {
        this.App := app
        this.Pending := 0
        this.Callback := ObjBindMethod(this, "Advance")
    }

    Begin(windowInfo, desiredState, reason, focusSignal) {
        this.Cancel()
        now := TickCount64()
        settleMs := this.App.Config.ForegroundSettleMs
        this.Pending := {
            window: windowInfo, desired: StateClone(desiredState), reason: reason,
            phase: "settle", focus: Map(), matchedFocus: Map(), beforeWrite: Map(),
            advancing: false, requested: false, retried: false,
            settleUntil: now + settleMs, checkUntil: now + Max(200, settleMs * 2),
            retryUntil: now + this.App.Config.ApplySuppressMs
        }
        this.Advance(focusSignal)
    }

    IsCurrent(pending) {
        return this.App.Enabled && !this.App.ShuttingDown && this.Pending = pending
    }

    Cancel() {
        this.Pending := 0
        SetTimer(this.Callback, 0)
    }

    ScheduleCheck(delay) {
        SetTimer(this.Callback, -Max(1, delay))
    }

    Advance(focusSignal := false) {
        pending := this.Pending
        if !pending || pending.advancing || !this.IsCurrent(pending)
            return
        pending.advancing := true
        try this.AdvancePending(pending, focusSignal)
        finally pending.advancing := false
    }

    AdvancePending(pending, focusSignal) {
        focus := this.App.Identity.GetForegroundFocus(pending.window)
        if !focus.Count {
            this.Cancel()
            return
        }
        now := TickCount64()
        settling := pending.phase = "settle"
        if settling && !focusSignal && now < pending.settleUntil {
            this.ScheduleCheck(pending.settleUntil - now)
            return
        }
        if !focus["focused"] {
            if settling && now < pending.checkUntil
                this.ScheduleCheck(Min(30, pending.checkUntil - now))
            else
                this.Complete(pending, Map())
            return
        }
        actual := this.App.ReadState(pending.window, focus)
        if !this.IsCurrent(pending)
            return
        now := TickCount64()
        if HasKnownProfile(actual) && StateMatches(actual, pending.desired) {
            if settling && now < pending.settleUntil && focus["hwnd"] = pending.window["hwnd"] {
                ; A launcher can focus its host before handing input to the search field.
                pending.matchedFocus := focus
                this.ScheduleCheck(pending.settleUntil - now)
                return
            }
            this.Complete(pending, actual)
            return
        }
        if !settling && !WindowIdentity.SameFocus(focus, pending.focus) {
            this.Complete(pending, actual)
            return
        }
        if HasKnownProfile(actual) {
            sameProfile := KeyPersonaApp.SameInputProfile(actual, pending.desired)
            if settling {
                if !focusSignal && pending.matchedFocus.Count && WindowIdentity.SameFocus(focus, pending.matchedFocus) {
                    this.Complete(pending, actual)
                    return
                }
                pending.focus := focus
                if !sameProfile {
                    this.Request(pending, actual, "profile")
                    return
                }
            }
            if (settling || pending.phase = "profile") && sameProfile {
                if InputRestoration.HasKnownModeMismatch(actual, pending.desired) {
                    this.Request(pending, actual, "mode")
                    return
                }
            } else if !settling {
                if KeyPersonaApp.CompareObservation(pending.beforeWrite, actual).changed {
                    this.Complete(pending, actual)
                    return
                }
                if (now >= pending.checkUntil && now < pending.retryUntil && pending.requested
                    && !pending.retried && pending.reason != "enforce" && this.App.CanRemember(pending.window)
                    && MapGet(pending.desired, "source", "") = "learned") {
                    pending.retried := true
                    this.Request(pending, actual, pending.phase)
                    return
                }
            }
        }
        if now < pending.checkUntil
            this.ScheduleCheck(Min(40, pending.checkUntil - now))
        else
            this.Complete(pending, actual)
    }

    static HasKnownModeMismatch(actual, desired) {
        if !ImeMode.Supports(MapGet(actual, "kind", ""))
            return false
        for field in ["imeOpen", "conversion", "sentence"] {
            wanted := MapGet(desired, field, "unknown")
            value := MapGet(actual, field, "unknown")
            if wanted != "" && wanted != "unknown" && wanted != "preserve" && value != "unknown" && value != wanted
                return true
        }
        return false
    }

    Request(pending, actual, phase) {
        if !this.IsCurrent(pending)
            return
        if (pending.reason = "enforce" && pending.phase = "settle"
            && !this.App.Enforcement.ShouldRestore(actual, TickCount64())) {
            this.Complete(pending, actual)
            return
        }
        pending.phase := phase
        pending.beforeWrite := actual
        if (pending.reason = "enforce")
            this.App.Enforcement.NoteRequest(TickCount64())
        this.App.Logger.Debug("Apply " pending.reason " (" phase ") to " pending.window["exe"]
            . ": " StateLabel(pending.desired) " focus=" pending.focus["hwnd"]
            . " thread=" pending.focus["threadId"])
        pending.requested := phase = "profile"
            ? this.App.Profiles.Switch(pending.window, pending.desired, pending.focus)
            : this.App.Mode.Apply(pending.window, pending.desired, pending.focus)
        if this.IsCurrent(pending) {
            pending.checkUntil := TickCount64() + 160
            this.ScheduleCheck(25)
        }
    }

    Complete(pending, actual) {
        if !this.IsCurrent(pending)
            return
        this.Cancel()
        if (pending.reason = "enforce" && pending.phase != "settle")
            this.App.Enforcement.NoteResult(actual, TickCount64())
        if !actual.Count
            return
        source := HasKnownProfile(actual) && StateMatches(actual, pending.desired)
            ? MapGet(pending.desired, "source", "observed") : "observed"
        this.App.Logger.Debug("Finished " pending.reason " for " pending.window["exe"]
            . ": actual=" StateLabel(actual) ", target=" StateLabel(pending.desired) ", source=" source)
        this.App.SetObservationBaseline(pending.window, actual, source)
        this.App.Tray.Refresh()
    }
}
