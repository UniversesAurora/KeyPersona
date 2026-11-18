#Requires AutoHotkey v2.0

class InputEnforcement {
    __New() {
        this.Target := Map()
        this.Key := ""
        this.Failures := 0
        this.RetryAt := 0
    }

    SetTarget(exe, desired) {
        this.Target := HasKnownProfile(desired)
            ? Map("profile", desired["profile"], "imeOpen", MapGet(desired, "imeOpen", "unknown"),
                "source", MapGet(desired, "source", "observed")) : Map()
        key := this.Target.Count ? StrLower(exe) "|" StateSignature(this.Target) : ""
        if (key != this.Key) {
            this.Key := key
            this.Failures := 0
            this.RetryAt := 0
        }
    }

    HasDrift(actual) {
        if !this.Target.Count || !HasKnownProfile(actual)
            return false
        return !KeyPersonaApp.SameInputProfile(actual, this.Target)
            || InputRestoration.HasKnownModeMismatch(actual, this.Target)
    }

    ShouldRestore(actual, now) {
        return now >= this.RetryAt && this.HasDrift(actual)
    }

    NoteRequest(now) {
        this.RetryAt := Max(this.RetryAt, now + 180)
    }

    NoteResult(actual, now) {
        if HasKnownProfile(actual) && StateMatches(actual, this.Target) {
            if this.Failures
                this.RetryAt := 0
            this.Failures := 0
            return
        }
        this.Failures := Min(this.Failures + 1, 6)
        this.RetryAt := Max(this.RetryAt, now + 500 * (2 ** (this.Failures - 1)))
    }
}
