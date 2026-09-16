#Requires AutoHotkey v2.0

class ForegroundWinEventHook {
    static EVENT_SYSTEM_FOREGROUND := 0x0003
    static WINEVENT_OUTOFCONTEXT := 0x0000
    static WINEVENT_SKIPOWNPROCESS := 0x0002

    __New(receiverHwnd, messageId, logger) {
        this.ReceiverHwnd := receiverHwnd
        this.MessageId := messageId
        this.Logger := logger
        this.Callback := CallbackCreate(ObjBindMethod(this, "OnWinEvent"),, 7)
        this.Hook := 0
    }

    Start() {
        this.Hook := DllCall("user32\SetWinEventHook",
            "UInt", ForegroundWinEventHook.EVENT_SYSTEM_FOREGROUND,
            "UInt", ForegroundWinEventHook.EVENT_SYSTEM_FOREGROUND,
            "Ptr", 0,
            "Ptr", this.Callback,
            "UInt", 0,
            "UInt", 0,
            "UInt", ForegroundWinEventHook.WINEVENT_OUTOFCONTEXT | ForegroundWinEventHook.WINEVENT_SKIPOWNPROCESS,
            "Ptr")
        if !this.Hook
            throw OSError(A_LastError, "SetWinEventHook")
    }

    OnWinEvent(hook, event, hwnd, objectId, childId, eventThread, eventTime) {
        DllCall("user32\PostMessageW", "Ptr", this.ReceiverHwnd, "UInt", this.MessageId, "Ptr", hwnd, "Ptr", event, "Int")
    }

    Stop() {
        if this.Hook {
            DllCall("user32\UnhookWinEvent", "Ptr", this.Hook)
            this.Hook := 0
        }
        if this.Callback {
            CallbackFree(this.Callback)
            this.Callback := 0
        }
    }
}
