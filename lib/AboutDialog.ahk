#Requires AutoHotkey v2.0

class AboutDialog {
    static PanelWidth := 300
    static PanelColor := 0xF5F7FA
    static WM_SETCURSOR := 0x0020

    __New() {
        this.Window := ""
        this.ProjectIcon := 0
        this.ProjectBrush := 0
        this.ProjectIconSize := Round(20 * A_ScreenDPI / 96)
        this.ProjectCursorCallback := ""
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

        panel := this.CreatePanel()
        this.Window := panel
        panel.Show("w" AboutDialog.PanelWidth " h300 Center")
        panel["CloseButton"].Focus()
    }

    CreatePanel() {
        panel := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", "关于 " AppInfo.Name)
        panel.BackColor := Format("{:06X}", AboutDialog.PanelColor)
        panel.MarginX := 20
        panel.MarginY := 18

        iconSource := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\" AppInfo.IconFile
        panel.AddPicture("x118 y18 w64 h64 Icon1", iconSource)

        panel.SetFont("s16 w600", "Segoe UI")
        panel.AddText("x20 y94 w260 Center", AppInfo.Name)
        panel.SetFont("s9 norm", "Segoe UI")
        panel.AddText("x20 y126 w260 Center c4A5568", "版本 " ApplicationVersion())
        panel.SetFont("s10 norm", "Microsoft YaHei UI")
        panel.AddText("x20 y158 w260 Center", AppInfo.Description)
        panel.SetFont("s9 norm", "Segoe UI")
        panel.AddText("x20 y182 w260 Center c687582", "基于 AutoHotkey v2")
        panel.SetFont("s9 norm", "Microsoft YaHei UI")
        this.AddCenteredLink(panel, 202, "AuthorLink",
            '作者：' AppInfo.Author ' <a href="' AppInfo.AuthorUrl '">' AppInfo.AuthorHandle '</a>')
        this.AddProjectLink(panel)

        closeButton := panel.AddButton("x105 y254 w90 h28 vCloseButton Default", "确定")
        closeButton.OnEvent("Click", ObjBindMethod(this, "CloseFromButton"))
        panel.OnEvent("Escape", ObjBindMethod(this, "CloseGui"))
        panel.OnEvent("Close", ObjBindMethod(this, "CloseGui"))
        return panel
    }

    AddCenteredLink(panel, y, name, text) {
        link := panel.AddLink("x20 y" y " v" name, text)
        link.GetPos(,, &width)
        link.Move(Round((AboutDialog.PanelWidth - width) / 2))
    }

    AddProjectLink(panel) {
        if !this.ProjectIcon {
            source := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\" AppInfo.RepositoryIconFile
            icon := A_IsCompiled ? "Icon-" AppInfo.RepositoryIconId : "Icon1"
            size := this.ProjectIconSize
            this.ProjectIcon := LoadPicture(source, icon " w" size " h" size, &imageType)
        }
        if !this.ProjectIcon {
            this.AddCenteredLink(panel, 224, "ProjectLink", '<a href="' AppInfo.RepositoryUrl '">GitHub</a>')
            return
        }
        ; BS_ICON displays the icon while the button retains its accessible name.
        projectButton := panel.AddButton("x132 y222 w36 h26 vProjectLink +0x40", "GitHub")
        SendMessage(0xF7, 1, this.ProjectIcon, projectButton) ; BM_SETIMAGE, IMAGE_ICON
        projectButton.OnEvent("Click", ObjBindMethod(this, "OpenProject"))
        if !this.ProjectBrush {
            rgb := AboutDialog.PanelColor
            colorRef := ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | (rgb >> 16)
            this.ProjectBrush := DllCall("gdi32\CreateSolidBrush", "UInt", colorRef, "Ptr")
        }
        if this.ProjectBrush
            projectButton.OnNotify(-12, ObjBindMethod(this, "DrawProjectLink")) ; NM_CUSTOMDRAW
        this.StopProjectCursor()
        hand := DllCall("user32\LoadCursorW", "Ptr", 0, "Ptr", 32649, "Ptr") ; IDC_HAND
        if hand {
            this.ProjectCursorCallback := ObjBindMethod(this, "SetProjectCursor", projectButton.Hwnd, hand)
            OnMessage(AboutDialog.WM_SETCURSOR, this.ProjectCursorCallback)
        }
    }

    SetProjectCursor(buttonHwnd, hand, targetHwnd, hitTest, *) {
        if (targetHwnd != buttonHwnd || (hitTest & 0xFFFF) != 1) ; HTCLIENT
            return
        DllCall("user32\SetCursor", "Ptr", hand, "Ptr")
        return 1
    }

    StopProjectCursor() {
        if IsObject(this.ProjectCursorCallback) {
            OnMessage(AboutDialog.WM_SETCURSOR, this.ProjectCursorCallback, 0)
            this.ProjectCursorCallback := ""
        }
    }

    DrawProjectLink(button, notification) {
        ; NMCUSTOMDRAW has a pointer-aligned HDC after NMHDR and dwDrawStage.
        if NumGet(notification, 3 * A_PtrSize, "UInt") != 1 ; CDDS_PREPAINT
            return
        deviceOffset := 4 * A_PtrSize
        device := NumGet(notification, deviceOffset, "Ptr")
        bounds := notification + deviceOffset + A_PtrSize
        left := NumGet(bounds, 0, "Int")
        top := NumGet(bounds, 4, "Int")
        width := NumGet(bounds, 8, "Int") - left
        height := NumGet(bounds, 12, "Int") - top
        size := this.ProjectIconSize
        DllCall("user32\FillRect", "Ptr", device, "Ptr", bounds, "Ptr", this.ProjectBrush)
        DllCall("user32\DrawIconEx", "Ptr", device, "Int", left + (width - size) // 2,
            "Int", top + (height - size) // 2, "Ptr", this.ProjectIcon, "Int", size, "Int", size,
            "UInt", 0, "Ptr", 0, "UInt", 3)
        if (DllCall("user32\GetFocus", "Ptr") = button.Hwnd
            && !(SendMessage(0x129, 0, 0, button) & 1)) ; WM_QUERYUISTATE, UISF_HIDEFOCUS
            DllCall("user32\DrawFocusRect", "Ptr", device, "Ptr", bounds)
        return 4 ; CDRF_SKIPDEFAULT
    }

    OpenProject(*) {
        try Run(AppInfo.RepositoryUrl)
        catch Error
            TrayTip("无法打开 GitHub 项目链接。", AppInfo.Name, "Iconx")
    }

    CloseFromButton(control, *) {
        this.CloseGui(control.Gui)
    }

    CloseGui(panel, *) {
        this.StopProjectCursor()
        try panel.Destroy()
        this.Window := ""
    }

    Dispose() {
        if IsObject(this.Window)
            this.CloseGui(this.Window)
        else
            this.StopProjectCursor()
        if this.ProjectIcon {
            DllCall("user32\DestroyIcon", "Ptr", this.ProjectIcon)
            this.ProjectIcon := 0
        }
        if this.ProjectBrush {
            DllCall("gdi32\DeleteObject", "Ptr", this.ProjectBrush)
            this.ProjectBrush := 0
        }
    }
}
