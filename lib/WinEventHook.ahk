#Requires AutoHotkey v2.0

class WindowWinEventHook {
    static EVENT_SYSTEM_FOREGROUND := 0x0003
    static EVENT_OBJECT_SHOW := 0x8002
    static EVENT_OBJECT_FOCUS := 0x8005
    static WINEVENT_SKIPOWNPROCESS := 0x0002

    __New(receiverHwnd, messageId) {
        this.ReceiverHwnd := receiverHwnd
        this.MessageId := messageId
        this.Callback := CallbackCreate(ObjBindMethod(this, "OnWinEvent"),, 7)
        this.Hooks := []
        this.LastFocusHwnd := 0
        this.LastFocusObject := 0
        this.LastFocusChild := 0
    }

    Start() {
        optionalHooksAvailable := true
        for event in [WindowWinEventHook.EVENT_SYSTEM_FOREGROUND, WindowWinEventHook.EVENT_OBJECT_SHOW,
            WindowWinEventHook.EVENT_OBJECT_FOCUS] {
            hook := DllCall("user32\SetWinEventHook", "UInt", event, "UInt", event,
                "Ptr", 0, "Ptr", this.Callback, "UInt", 0, "UInt", 0,
                "UInt", WindowWinEventHook.WINEVENT_SKIPOWNPROCESS, "Ptr")
            if !hook {
                if (event != WindowWinEventHook.EVENT_SYSTEM_FOREGROUND) {
                    optionalHooksAvailable := false
                    continue
                }
                errorCode := A_LastError
                this.Stop()
                throw OSError(errorCode, "SetWinEventHook")
            }
            this.Hooks.Push(hook)
        }
        return optionalHooksAvailable
    }

    OnWinEvent(hook, event, hwnd, objectId, childId, eventThread, eventTime) {
        if !hwnd
            return
        if (event = WindowWinEventHook.EVENT_OBJECT_FOCUS) {
            if (hwnd = this.LastFocusHwnd && objectId = this.LastFocusObject && childId = this.LastFocusChild)
                return
            this.LastFocusHwnd := hwnd
            this.LastFocusObject := objectId
            this.LastFocusChild := childId
        } else if (event = WindowWinEventHook.EVENT_OBJECT_SHOW) {
            if objectId || childId || hwnd != DllCall("user32\GetForegroundWindow", "Ptr")
                return
        } else {
            this.LastFocusHwnd := 0
        }
        DllCall("user32\PostMessageW", "Ptr", this.ReceiverHwnd, "UInt", this.MessageId,
            "Ptr", hwnd, "Ptr", event, "Int")
    }

    Stop() {
        for hook in this.Hooks
            DllCall("user32\UnhookWinEvent", "Ptr", hook)
        this.Hooks := []
        if this.Callback {
            CallbackFree(this.Callback)
            this.Callback := 0
        }
    }
}
