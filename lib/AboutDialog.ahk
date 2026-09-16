#Requires AutoHotkey v2.0

class AboutDialog {
    __New() {
        this.Window := ""
    }

    Show(*) {
        if IsObject(this.Window) {
            try {
                if WinExist("ahk_id " this.Window.Hwnd) {
                    this.Window.Show()
                    WinActivate("ahk_id " this.Window.Hwnd)
                    return
                }
            }
            this.Window := ""
        }

        panel := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", "关于 IME Memory")
        panel.BackColor := "F5F7FA"
        panel.MarginX := 20
        panel.MarginY := 18

        iconSource := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\assets\ime-memory.ico"
        panel.AddPicture("x118 y18 w64 h64 Icon1", iconSource)

        panel.SetFont("s16 w600", "Segoe UI")
        panel.AddText("x20 y94 w260 Center", "IME Memory")
        panel.SetFont("s9 norm", "Segoe UI")
        panel.AddText("x20 y126 w260 Center c4A5568", "版本 " ApplicationVersion())
        panel.SetFont("s10 norm", "Microsoft YaHei UI")
        panel.AddText("x20 y158 w260 Center", "按窗口记忆并自动恢复输入法状态")
        panel.SetFont("s9 norm", "Segoe UI")
        panel.AddText("x20 y184 w260 Center c687582", "AutoHotkey v2 · Windows API")

        closeButton := panel.AddButton("x105 y220 w90 h28 Default", "确定")
        closeButton.OnEvent("Click", ObjBindMethod(this, "CloseFromButton"))
        panel.OnEvent("Escape", ObjBindMethod(this, "CloseGui"))
        panel.OnEvent("Close", ObjBindMethod(this, "CloseGui"))
        this.Window := panel
        panel.Show("w300 h266 Center")
    }

    CloseFromButton(control, *) {
        this.CloseGui(control.Gui)
    }

    CloseGui(panel, *) {
        try panel.Destroy()
        this.Window := ""
    }

    Dispose() {
        if IsObject(this.Window)
            this.CloseGui(this.Window)
    }
}

