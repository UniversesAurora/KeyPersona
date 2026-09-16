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

    Read(windowInfo, profileKind := "tip") {
        if (profileKind != "tip")
            return Map("imeOpen", "unknown", "conversion", "unknown", "sentence", "unknown")
        imeWindow := this.GetImeWindow(windowInfo)
        if !imeWindow
            return Map("imeOpen", "unknown", "conversion", "unknown", "sentence", "unknown")
        open := this.Control(imeWindow, ImeMode.IMC_GETOPENSTATUS, 0)
        conversion := this.Control(imeWindow, ImeMode.IMC_GETCONVERSIONMODE, 0)
        sentence := this.Control(imeWindow, ImeMode.IMC_GETSENTENCEMODE, 0)
        return Map(
            "imeOpen", open["ok"] ? (open["value"] ? "1" : "0") : "unknown",
            "conversion", conversion["ok"] ? "0x" Hex(conversion["value"]) : "unknown",
            "sentence", sentence["ok"] ? "0x" Hex(sentence["value"]) : "unknown"
        )
    }

    ReadOpenStatus(windowInfo, timeoutMs := 30) {
        imeWindow := this.GetImeWindow(windowInfo)
        if !imeWindow
            return "unknown"
        open := this.Control(imeWindow, ImeMode.IMC_GETOPENSTATUS, 0, timeoutMs)
        return open["ok"] ? (open["value"] ? "1" : "0") : "unknown"
    }

    Apply(windowInfo, desiredState) {
        imeWindow := this.GetImeWindow(windowInfo)
        if !imeWindow
            return false
        success := true
        open := StrLower(MapGet(desiredState, "imeOpen", "unknown") "")
        if (open = "0" || open = "1") {
            currentOpen := this.Control(imeWindow, ImeMode.IMC_GETOPENSTATUS, 0)
            if (!currentOpen["ok"] || currentOpen["value"] != Integer(open)) {
                result := this.Control(imeWindow, ImeMode.IMC_SETOPENSTATUS, Integer(open))
                success := success && result["ok"]
            }
        }
        conversion := this.ParseMode(MapGet(desiredState, "conversion", "preserve"))
        if (conversion != "") {
            capability := this.Control(imeWindow, ImeMode.IMC_GETCONVERSIONMODE, 0)
            if (capability["ok"] && capability["value"] != conversion) {
                result := this.Control(imeWindow, ImeMode.IMC_SETCONVERSIONMODE, conversion)
                success := success && result["ok"]
            }
        }
        sentence := this.ParseMode(MapGet(desiredState, "sentence", "preserve"))
        if (sentence != "") {
            capability := this.Control(imeWindow, ImeMode.IMC_GETSENTENCEMODE, 0)
            if (capability["ok"] && capability["value"] != sentence) {
                result := this.Control(imeWindow, ImeMode.IMC_SETSENTENCEMODE, sentence)
                success := success && result["ok"]
            }
        }
        return success
    }

    GetImeWindow(windowInfo) {
        focus := this.Identity.GetFocusTarget(windowInfo)
        target := MapGet(focus, "hwnd", MapGet(windowInfo, "hwnd", 0))
        imeWindow := target ? DllCall("imm32\ImmGetDefaultIMEWnd", "Ptr", target, "Ptr") : 0
        if !imeWindow {
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
