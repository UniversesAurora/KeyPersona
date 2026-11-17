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
        this.Registrations := []
        for rule in PunctuationCatalog.Rules {
            condition := ObjBindMethod(this, "ShouldReplace", rule["id"])
            HotIf(condition)
            try {
                for binding in rule["bindings"] {
                    callback := ObjBindMethod(this, "TypeSymbol", rule, binding)
                    Hotkey(binding["key"], callback)
                    this.Registrations.Push(Map("key", binding["key"], "condition", condition))
                }
            } finally {
                HotIf()
            }
        }
    }

    ShouldReplace(id, *) {
        if (!this.App.Enabled || this.App.ShuttingDown
            || !this.App.Config.PunctuationEnabled
            || !MapGet(this.App.Config.PunctuationConvert, id, false))
            return false
        ; Shift selects the punctuation variant; other shortcut modifiers pass through.
        if (GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P")
            || GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
            return false
        window := this.App.Identity.Resolve()
        if !window.Count
            return false
        profile := this.App.Profiles.Read(window)
        imeOpen := IsChineseLanguageState(profile) ? this.App.Mode.ReadOpenStatus(window, 30) : "unknown"
        return ShouldReplacePunctuationState(profile, imeOpen)
    }

    TypeSymbol(rule, binding, *) {
        window := this.App.Identity.Resolve()
        if !window.Count
            return
        closingText := ""
        if (binding["opening"] && rule["close"] != ""
            && this.App.Config.ShouldPairPunctuation(MapGet(window, "exe", ""), rule["id"]))
            closingText := rule["close"]
        ; One send buffers physical input while the pair and cursor move are inserted.
        SendInput(PunctuationCatalog.SendSequence(binding["text"], closingText))
    }

    Dispose() {
        for registration in this.Registrations {
            HotIf(registration["condition"])
            try Hotkey(registration["key"], "Off")
            finally HotIf()
        }
    }
}
