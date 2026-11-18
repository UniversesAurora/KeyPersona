#Requires AutoHotkey v2.0

class ImeMode {
    static WM_IME_CONTROL := 0x0283
    static IMC_GETCONVERSIONMODE := 0x0001
    static IMC_SETCONVERSIONMODE := 0x0002
    static IMC_GETSENTENCEMODE := 0x0003
    static IMC_SETSENTENCEMODE := 0x0004
    static IMC_GETOPENSTATUS := 0x0005
    static IMC_SETOPENSTATUS := 0x0006

    __New(identity, config, logger) {
        this.Identity := identity
        this.Config := config
        this.Logger := logger
    }

    static Supports(profileKind) {
        return profileKind = "tip" || profileKind = "ime"
    }

    static HasModePresets(profile) {
        primaryLanguage := MapGet(profile, "langId", 0) & 0x03FF
        return ImeMode.Supports(MapGet(profile, "kind", "")) && (primaryLanguage = 0x04 || primaryLanguage = 0x11)
    }

    static ModeLabel(profileId, open) {
        if (open != "0" && open != "1")
            return ""
        if RegExMatch(profileId, "i)^([0-9a-f]{4}):", &language)
            && (Integer("0x" language[1]) & 0x03FF) = 0x11
            return open = "1" ? "启用日文输入" : "直接输入"
        if IsChineseLanguageState(Map("profile", profileId))
            return open = "1" ? "中文" : "英文"
        return open = "1" ? "输入法开启" : "输入法关闭"
    }

    Read(windowInfo, profileKind := "tip", focus := unset) {
        state := Map("imeOpen", "unknown", "conversion", "unknown", "sentence", "unknown")
        if !ImeMode.Supports(profileKind)
            return state
        imeWindow := this.GetImeWindow(windowInfo, focus?)
        if !imeWindow
            return state
        deadline := TickCount64() + this.Config.MessageTimeoutMs
        for query in [["imeOpen", ImeMode.IMC_GETOPENSTATUS], ["conversion", ImeMode.IMC_GETCONVERSIONMODE],
            ["sentence", ImeMode.IMC_GETSENTENCEMODE]] {
            field := query[1]
            remaining := deadline - TickCount64()
            if (remaining <= 0)
                break
            response := this.Control(imeWindow, query[2], 0, remaining)
            if !response["ok"]
                break
            state[field] := field = "imeOpen" ? (response["value"] ? "1" : "0") : "0x" Hex(response["value"])
        }
        return state
    }

    ReadOpenStatus(windowInfo, timeoutMs := 30, focus := unset) {
        imeWindow := this.GetImeWindow(windowInfo, focus?)
        if !imeWindow
            return "unknown"
        open := this.Control(imeWindow, ImeMode.IMC_GETOPENSTATUS, 0, timeoutMs)
        return open["ok"] ? (open["value"] ? "1" : "0") : "unknown"
    }

    Apply(windowInfo, desiredState, focus := unset) {
        imeWindow := this.GetImeWindow(windowInfo, focus?)
        if !imeWindow
            return false
        success := true
        open := StrLower(MapGet(desiredState, "imeOpen", "unknown") "")
        if (open = "0" || open = "1") {
            currentOpen := this.Control(imeWindow, ImeMode.IMC_GETOPENSTATUS, 0)
            if !currentOpen["ok"]
                success := false
            else if (!!currentOpen["value"] != Integer(open))
                success := this.SetMode(windowInfo, imeWindow, ImeMode.IMC_SETOPENSTATUS, Integer(open), focus?)
        }
        conversion := this.ParseMode(MapGet(desiredState, "conversion", "preserve"))
        if (conversion != "") {
            capability := this.Control(imeWindow, ImeMode.IMC_GETCONVERSIONMODE, 0)
            if (capability["ok"] && capability["value"] != conversion) {
                changed := this.SetMode(windowInfo, imeWindow, ImeMode.IMC_SETCONVERSIONMODE, conversion, focus?)
                success := success && changed
            }
        }
        sentence := this.ParseMode(MapGet(desiredState, "sentence", "preserve"))
        if (sentence != "") {
            capability := this.Control(imeWindow, ImeMode.IMC_GETSENTENCEMODE, 0)
            if (capability["ok"] && capability["value"] != sentence) {
                changed := this.SetMode(windowInfo, imeWindow, ImeMode.IMC_SETSENTENCEMODE, sentence, focus?)
                success := success && changed
            }
        }
        return success
    }

    SetMode(windowInfo, imeWindow, command, value, focus := unset) {
        if IsSet(focus) && !this.Identity.IsForegroundFocus(windowInfo, focus)
            return false
        return this.Control(imeWindow, command, value)["ok"]
    }

    GetImeWindow(windowInfo, focus := unset) {
        if !IsSet(focus)
            focus := this.Identity.GetFocusTarget(windowInfo)
        target := focus["hwnd"]
        imeWindow := target ? DllCall("imm32\ImmGetDefaultIMEWnd", "Ptr", target, "Ptr") : 0
        if !imeWindow && focus["threadId"] = MapGet(windowInfo, "threadId", 0) {
            root := MapGet(windowInfo, "hwnd", 0)
            imeWindow := root ? DllCall("imm32\ImmGetDefaultIMEWnd", "Ptr", root, "Ptr") : 0
        }
        return imeWindow
    }

    Control(imeWindow, command, value, timeoutMs := "") {
        result := 0
        if (timeoutMs = "")
            timeoutMs := this.Config.MessageTimeoutMs
        DllCall("kernel32\SetLastError", "UInt", 0)
        ok := DllCall("user32\SendMessageTimeoutW",
            "Ptr", imeWindow,
            "UInt", ImeMode.WM_IME_CONTROL,
            "Ptr", command,
            "Ptr", value,
            "UInt", 0x2,
            "UInt", timeoutMs,
            "Ptr*", &result,
            "Ptr")
        return Map("ok", !!ok, "value", result, "error", A_LastError)
    }

    ParseMode(value) {
        value := StrLower(Trim(value ""))
        if (value = "" || value = "unknown" || value = "preserve")
            return ""
        if RegExMatch(value, "^0x[0-9a-f]+$")
            return Integer(value)
        return IsNumber(value) ? Integer(value) : ""
    }
}
