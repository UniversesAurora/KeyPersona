#Requires AutoHotkey v2.0

class InputChangeKeys {
    static WM_INPUT := 0x00FF
    static SHIFT := 1
    static CTRL := 2
    static ALT := 4
    static WIN := 8

    __New(hwnd, onGesture) {
        this.Hwnd := hwnd
        this.OnGesture := onGesture
        this.MessageCallback := ObjBindMethod(this, "OnInput")
        this.Registered := false
        this.HeaderSize := 8 + 2 * A_PtrSize
        this.Packet := Buffer(this.HeaderSize + 16)
        this.Reset()
    }

    SetEnabled(enabled) {
        if (enabled = this.Registered)
            return true
        device := Buffer(8 + A_PtrSize, 0)
        flags := enabled ? 0x100 : 0x01 ; RIDEV_INPUTSINK or RIDEV_REMOVE
        NumPut("UShort", 1, "UShort", 6, "UInt", flags, "Ptr", enabled ? this.Hwnd : 0, device)
        if !DllCall("user32\RegisterRawInputDevices", "Ptr", device, "UInt", 1, "UInt", device.Size, "Int")
            return false
        this.Registered := enabled
        this.Reset()
        OnMessage(InputChangeKeys.WM_INPUT, this.MessageCallback, enabled ? 1 : 0)
        return true
    }

    Reset() {
        this.Modifiers := 0
        this.CleanChord := false
        this.WinSpace := false
    }

    OnInput(inputCode, inputHandle, message, receiverHwnd) {
        if !this.Registered || receiverHwnd != this.Hwnd
            return
        ; For foreground raw input, leave cleanup to the default window procedure.
        if (inputCode & 0xFF) != 1
            return
        length := this.Packet.Size
        bytes := DllCall("user32\GetRawInputData", "Ptr", inputHandle, "UInt", 0x10000003,
            "Ptr", this.Packet, "UInt*", &length, "UInt", this.HeaderSize, "UInt")
        if bytes != this.Packet.Size || NumGet(this.Packet, 0, "UInt") != 1
            return 0
        flags := NumGet(this.Packet, this.HeaderSize + 2, "UShort")
        key := NumGet(this.Packet, this.HeaderSize + 6, "UShort")
        if this.IsSwitchGesture(key, flags & 1)
            this.OnGesture.Call()
        return 0
    }

    IsSwitchGesture(key, released) {
        modifier := InputChangeKeys.ModifierBit(key)
        if !modifier {
            if released
                return key = 0x20 && this.WinSpace
            if key = 0x20 && this.Modifiers = InputChangeKeys.WIN
                this.WinSpace := true
            else
                this.WinSpace := false
            this.CleanChord := false
            return false
        }

        if !released {
            if !this.Modifiers
                this.CleanChord := true
            this.Modifiers |= modifier
            return false
        }

        before := this.Modifiers
        this.Modifiers &= ~modifier
        if modifier = InputChangeKeys.WIN && this.WinSpace {
            this.WinSpace := false
            return true
        }
        if !(before & modifier) || !this.CleanChord
            return false
        this.CleanChord := false
        switch before {
            case InputChangeKeys.SHIFT, InputChangeKeys.SHIFT | InputChangeKeys.CTRL,
                InputChangeKeys.SHIFT | InputChangeKeys.ALT:
                return true
        }
        return false
    }

    static ModifierBit(key) {
        switch key {
            case 0x10, 0xA0, 0xA1: return InputChangeKeys.SHIFT
            case 0x11, 0xA2, 0xA3: return InputChangeKeys.CTRL
            case 0x12, 0xA4, 0xA5: return InputChangeKeys.ALT
            case 0x5B, 0x5C: return InputChangeKeys.WIN
            default: return 0
        }
    }
}
