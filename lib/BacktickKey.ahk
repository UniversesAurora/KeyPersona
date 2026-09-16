#Requires AutoHotkey v2.0

class BacktickKeyController {
    __New(app) {
        this.App := app
        this.ConditionCallback := ObjBindMethod(this, "ShouldReplace")
        this.TypeCallback := ObjBindMethod(this, "TypeBacktick")
        HotIf(this.ConditionCallback)
        Hotkey("$SC029", this.TypeCallback)
        HotIf()
    }

    ShouldReplace(*) {
        if !this.App.Enabled || !this.App.Config.BacktickInChinese || this.App.ShuttingDown
            return false
        window := this.App.Identity.Resolve()
        if !window.Count
            return false
        profile := this.App.Profiles.Read(window)
        imeOpen := IsChineseLanguageState(profile) ? this.App.Mode.ReadOpenStatus(window, 30) : "unknown"
        return ShouldReplaceBacktickState(profile, imeOpen,
            this.App.Config.BacktickInChinese, this.App.Enabled)
    }

    TypeBacktick(*) {
        SendText(Chr(96))
    }

    Dispose() {
        try {
            HotIf(this.ConditionCallback)
            Hotkey("$SC029", "Off")
            HotIf()
        }
    }
}
