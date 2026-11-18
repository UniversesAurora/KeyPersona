#Requires AutoHotkey v2.0

class PunctuationCatalog {
    static Rules := PunctuationCatalog.BuildRules()

    static BuildRules() {
        rules := []
        this.Add(rules, "comma", "逗号 ， → ,", "common", "SC033", ",")
        this.Add(rules, "period", "句号 。 → .", "common", "SC034", ".")
        this.Add(rules, "backslash", "顿号 、 → \", "common", "SC02B", "\")
        this.Add(rules, "semicolon", "分号 ； → " Chr(59), "common", "SC027", Chr(59))
        this.Add(rules, "colon", "冒号 ： → :", "common", "+SC027", ":")
        this.Add(rules, "question", "问号 ？ → ?", "common", "+SC035", "?")
        this.Add(rules, "exclamation", "感叹号 ！ → !", "common", "+SC002", "!")
        this.Add(rules, "parentheses", "圆括号 （） → ()", "pairs", "+SC00A", "(", ")", "+SC00B")
        this.Add(rules, "square", "方括号 【】 → []", "pairs", "SC01A", "[", "]", "SC01B")
        this.Add(rules, "braces", "花括号 ｛｝ → {}", "pairs", "+SC01A", "{", "}", "+SC01B")
        this.Add(rules, "angles", "书名号 《》 → <>", "pairs", "+SC033", "<", ">", "+SC034")
        this.Add(rules, "singleQuote", "单引号 ‘ ’ → ' '", "pairs", "SC028", "'", "'")
        quote := Chr(34)
        this.Add(rules, "doubleQuote", "双引号 “ ” → " quote " " quote, "pairs", "+SC028", quote, quote)
        this.Add(rules, "backtick", "反引号 · → " Chr(96), "pairs", "SC029", Chr(96), Chr(96))
        this.Add(rules, "tilde", "波浪号 ～ → ~", "other", "+SC029", "~")
        this.Add(rules, "at", "＠ → @", "other", "+SC003", "@")
        this.Add(rules, "hash", "＃ → #", "other", "+SC004", "#")
        this.Add(rules, "dollar", "人民币符号 ￥ → $", "other", "+SC005", "$")
        this.Add(rules, "percent", "％ → %", "other", "+SC006", "%")
        this.Add(rules, "caret", "省略号 …… → ^", "other", "+SC007", "^")
        this.Add(rules, "ampersand", "＆ → &&", "other", "+SC008", "&")
        this.Add(rules, "asterisk", "＊ → *", "other", "+SC009", "*")
        this.Add(rules, "minus", "减号 － → -", "other", "SC00C", "-")
        this.Add(rules, "underscore", "破折号 —— → _", "other", "+SC00C", "_")
        this.Add(rules, "equals", "等号 ＝ → =", "other", "SC00D", "=")
        this.Add(rules, "plus", "加号 ＋ → +", "other", "+SC00D", "+")
        this.Add(rules, "pipe", "竖线 ｜ → |", "other", "+SC02B", "|")
        this.Add(rules, "slash", "斜杠 ／ → /", "other", "SC035", "/")
        return rules
    }

    static Add(rules, id, label, group, key, text, close := "", closeKey := "") {
        bindings := [Map("key", "$" key, "text", text, "opening", true)]
        if (closeKey != "")
            bindings.Push(Map("key", "$" closeKey, "text", close, "opening", false))
        rules.Push(Map("id", id, "label", label, "group", group,
            "close", close, "bindings", bindings))
    }

    static Find(id) {
        for rule in this.Rules {
            if (rule["id"] = id)
                return rule
        }
        return Map()
    }

    static SendSequence(text, closingText := "") {
        sequence := ""
        Loop Parse, text closingText
            sequence .= "{U+" Format("{:04X}", Ord(A_LoopField)) "}"
        if (closingText != "")
            sequence .= "{Left " StrLen(closingText) "}"
        return sequence
    }
}

class PunctuationController {
    __New(app) {
        this.App := app
        this.Registrations := Map()
        this.Permits := Map()
        this.Window := Map()
    }

    RefreshBindings() {
        this.Permits := Map()
        this.Window := Map()
        for rule in PunctuationCatalog.Rules {
            id := rule["id"]
            enabled := !this.App.ObserveOnly && this.App.Config.HasPunctuationConversion(id)
            if enabled || this.Registrations.Has(id)
                this.SetBindingEnabled(rule, enabled)
        }
    }

    SetBindingEnabled(rule, enabled) {
        id := rule["id"]
        registration := MapGet(this.Registrations, id, 0)
        if !registration {
            registration := {enabled: false, condition: ObjBindMethod(this, "ShouldReplace", id), installed: false}
            this.Registrations[id] := registration
        }
        if registration.enabled = enabled
            return
        HotIf(registration.condition)
        try {
            for binding in rule["bindings"] {
                if !registration.installed
                    Hotkey(binding["key"], ObjBindMethod(this, "TypeSymbol", rule, binding))
                else
                    Hotkey(binding["key"], enabled ? "On" : "Off")
            }
            registration.installed := true
            registration.enabled := enabled
        } finally HotIf()
    }

    ShouldReplace(id, *) {
        this.Permits[id] := 0
        if this.App.ShuttingDown
            return false
        if GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P")
            || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
            return false
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        if !foreground
            return false
        if foreground != MapGet(this.Window, "hwnd", 0) || !this.App.Identity.IsCurrentWindow(this.Window)
            this.Window := this.App.Identity.Resolve(foreground)
        windowInfo := this.Window
        if !windowInfo.Count || !this.App.Config.ShouldConvertPunctuation(WindowIdentity.AppSelectorFor(windowInfo), id)
            return false
        focus := this.App.Identity.GetForegroundFocus(windowInfo)
        if !focus.Count || !focus["focused"]
            return false
        profile := this.App.Profiles.Read(windowInfo, focus, false)
        if !IsChineseLanguageState(profile) || !ImeMode.Supports(profile["kind"])
            || !this.App.Profiles.Catalog.Has(StrLower(profile["profile"]))
            return false
        imeOpen := this.App.Mode.ReadOpenStatus(windowInfo, 20, focus)
        if !ShouldReplacePunctuationState(profile, imeOpen) || !this.App.Identity.IsForegroundFocus(windowInfo, focus)
            return false
        this.Permits[id] := {window: windowInfo, focus: focus, hkl: profile["hkl"], expires: TickCount64() + 120}
        return true
    }

    TypeSymbol(rule, binding, *) {
        id := rule["id"]
        permit := MapGet(this.Permits, id, 0)
        this.Permits[id] := 0
        if !permit || this.App.ShuttingDown || TickCount64() > permit.expires
            return
        if !this.App.Identity.IsForegroundFocus(permit.window, permit.focus)
            || permit.hkl != "0x" Hex(DllCall("user32\GetKeyboardLayout", "UInt", permit.focus["threadId"], "Ptr"))
            return
        exe := WindowIdentity.AppSelectorFor(permit.window)
        if !this.App.Config.ShouldConvertPunctuation(exe, id)
            return
        closingText := binding["opening"] && this.App.Config.ShouldPairPunctuation(exe, id) ? rule["close"] : ""
        SendInput(PunctuationCatalog.SendSequence(binding["text"], closingText))
    }

    Dispose() {
        for rule in PunctuationCatalog.Rules {
            if this.Registrations.Has(rule["id"])
                this.SetBindingEnabled(rule, false)
        }
    }
}
