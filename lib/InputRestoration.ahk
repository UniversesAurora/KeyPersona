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
            phase: "settle", focus: Map(), waitForControl: false, waitedForFocus: false, beforeWrite: Map(),
            advancing: false, requested: false, retried: false, handedOff: false,
            lastRead: 0, gesture: 0, verifyAfter: 0,
            settleUntil: now + settleMs, focusUntil: now + Max(200, settleMs * 2),
            checkUntil: now + Max(200, settleMs * 2),
            focusReadyUntil: now + Max(1500, settleMs * 3),
            retryUntil: now + this.App.Config.ApplySuppressMs
        }
        this.Advance(focusSignal)
    }

    IsCurrent(pending) {
        return this.Pending = pending && !this.App.ShuttingDown && this.App.CanSwitch(pending.window)
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

    NoteInputGesture(window) {
        pending := this.Pending
        if !pending || pending.window != window || pending.reason = "enforce" || !this.IsCurrent(pending)
            return
        if pending.lastRead && !pending.gesture
            pending.gesture := {sample: pending.lastRead, until: TickCount64() + 120}
        if pending.gesture
            this.ScheduleCheck(1)
    }

    AdvancePending(pending, focusSignal) {
        focus := this.App.Identity.GetForegroundFocus(pending.window)
        if !focus.Count {
            this.App.DeferInterruptedRestore(pending.window)
            this.Cancel()
            return
        }
        now := TickCount64()
        settling := pending.phase = "settle"
        if settling && !focusSignal && !pending.gesture && now < pending.settleUntil {
            this.ScheduleCheck(pending.settleUntil - now)
            return
        }
        if !focus["focused"] {
            waitUntil := settling ? pending.focusReadyUntil
                : pending.reason != "enforce" && pending.focus["hwnd"] = pending.window["hwnd"] ? pending.focusUntil : 0
            if settling
                pending.waitedForFocus := true
            if now < waitUntil
                this.ScheduleCheck(Min(now < pending.checkUntil ? 30 : 100, waitUntil - now))
            else if !settling
                this.Complete(pending, Map())
            return
        }
        if pending.waitedForFocus {
            pending.waitedForFocus := false
            pending.checkUntil := Max(now + 160, pending.checkUntil)
            pending.focusUntil := Max(now + 160, pending.focusUntil)
        }
        actual := this.App.ReadState(pending.window, focus,, pending.desired)
        if !this.IsCurrent(pending)
            return
        now := TickCount64()
        known := HasKnownProfile(actual)
        matches := known && StateMatches(actual, pending.desired)
        gesture := pending.gesture
        if gesture {
            if !WindowIdentity.SameFocus(gesture.sample.focus, focus) {
                pending.gesture := 0
            } else {
                if known && !matches && this.IsManualChange(pending, gesture.sample.state, actual) {
                    this.Complete(pending, actual, gesture.sample.state)
                    return
                }
                if now < gesture.until {
                    this.ScheduleCheck(Min(25, gesture.until - now))
                    return
                }
                pending.gesture := 0
            }
        }
        if known
            pending.lastRead := {focus: focus, state: actual}
        root := pending.window["hwnd"]
        if focus["hwnd"] = root && pending.reason != "enforce"
            && (settling || pending.focus["hwnd"] = root) {
            if now < pending.focusUntil && matches
                pending.waitForControl := true
            if pending.waitForControl {
                if now < pending.focusUntil
                    this.ScheduleCheck(pending.focusUntil - now)
                else
                    this.Complete(pending, actual)
                return
            }
        }
        if matches {
            this.Complete(pending, actual)
            return
        }
        if settling && pending.handedOff && !WindowIdentity.SameFocus(focus, pending.focus) {
            this.Complete(pending, actual)
            return
        }
        if !settling && !WindowIdentity.SameFocus(focus, pending.focus) {
            if pending.reason = "enforce" || pending.focus["hwnd"] != root
                || focus["hwnd"] = root || now >= pending.focusUntil {
                this.Complete(pending, actual)
                return
            }
            if pending.phase = "profile" && pending.requested && focus["threadId"] = pending.focus["threadId"]
                && now < pending.verifyAfter {
                this.ScheduleCheck(pending.verifyAfter - now)
                return
            }
            ; A launcher may expose its editing control after the host gets focus.
            pending.phase := "settle"
            settling := true
            pending.waitForControl := false
            pending.checkUntil := Max(now + 40, pending.checkUntil)
            pending.focus := focus
            pending.handedOff := true
            pending.retried := true
        }
        if known {
            sameProfile := KeyPersonaApp.SameInputProfile(actual, pending.desired)
            if settling {
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

    IsManualChange(pending, before, actual) {
        if !KeyPersonaApp.CompareObservation(before, actual).changed
            return false
        if pending.phase = "settle" || !KeyPersonaApp.SameInputProfile(actual, pending.desired)
            return true
        if !KeyPersonaApp.SameInputProfile(before, actual)
            return false
        for field in ["imeOpen", "conversion", "sentence"] {
            wanted := MapGet(pending.desired, field, "unknown")
            value := MapGet(actual, field, "unknown")
            if value != "unknown" && ModeValuesEqual(value, wanted)
                && !ModeValuesEqual(value, MapGet(before, field, "unknown"))
                return false
        }
        return true
    }

    static HasKnownModeMismatch(actual, desired) {
        if !ImeMode.Supports(MapGet(actual, "kind", ""))
            return false
        for field in ["imeOpen", "conversion", "sentence"] {
            wanted := MapGet(desired, field, "unknown")
            value := MapGet(actual, field, "unknown")
            if wanted != "" && wanted != "unknown" && wanted != "preserve" && value != "unknown" && !ModeValuesEqual(value, wanted)
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
        canWrite := ObjBindMethod(this, "CanWrite", pending, MapGet(actual, "hkl", ""))
        pending.requested := phase = "profile"
            ? this.App.Profiles.Switch(pending.window, pending.desired, pending.focus, canWrite)
            : this.App.Mode.Apply(pending.window, pending.desired, pending.focus, canWrite)
        if this.IsCurrent(pending) {
            now := TickCount64()
            pending.verifyAfter := now + 25
            pending.checkUntil := now + 160
            this.ScheduleCheck(25)
        }
    }

    CanWrite(pending, beforeHkl) {
        if !this.IsCurrent(pending) || pending.gesture
            || !this.App.Identity.IsForegroundFocus(pending.window, pending.focus)
            return false
        return beforeHkl = "0x" Hex(DllCall("user32\GetKeyboardLayout", "UInt", pending.focus["threadId"], "Ptr"))
    }

    Complete(pending, actual, manualBaseline := unset) {
        if !this.IsCurrent(pending)
            return
        this.Cancel()
        if (pending.reason = "enforce" && pending.phase != "settle")
            this.App.Enforcement.NoteResult(actual, TickCount64())
        source := HasKnownProfile(actual) && StateMatches(actual, pending.desired)
            ? MapGet(pending.desired, "source", "observed") : "observed"
        this.App.Logger.Debug("Finished " pending.reason " for " pending.window["exe"]
            . ": actual=" StateLabel(actual) ", target=" StateLabel(pending.desired) ", source=" source)
        if IsSet(manualBaseline) && this.App.CanRemember(pending.window) {
            this.App.SetObservationBaseline(pending.window, manualBaseline)
            this.App.ObserveMemoryState(pending.window, actual)
        } else {
            this.App.SetObservationBaseline(pending.window, actual)
        }
    }
}
