#Requires AutoHotkey v2.0

class WindowIdentity {
    __New(config, logger) {
        this.Config := config
        this.Logger := logger
        this.CurrentPid := DllCall("kernel32\GetCurrentProcessId", "UInt")
    }

    Resolve(hwnd := 0) {
        if !hwnd
            hwnd := DllCall("user32\GetForegroundWindow", "Ptr")
        if !hwnd || !DllCall("user32\IsWindow", "Ptr", hwnd, "Int")
            return Map()
        root := DllCall("user32\GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")
        if !root
            root := hwnd
        pid := 0
        threadId := DllCall("user32\GetWindowThreadProcessId", "Ptr", root, "UInt*", &pid, "UInt")
        if !pid || pid = this.CurrentPid
            return Map()
        path := this.QueryProcessPath(pid)
        if (path = "") {
            try path := WinGetProcessPath("ahk_id " root)
        }
        exe := ""
        if (path != "")
            SplitPath(path, &exe)
        if (exe = "") {
            try exe := WinGetProcessName("ahk_id " root)
        }
        className := ""
        title := ""
        try className := WinGetClass("ahk_id " root)
        try title := WinGetTitle("ahk_id " root)
        className := this.NormalizeClass(className)
        if this.IsIgnored(exe, className, root)
            return Map()
        normalizedTitle := this.NormalizeTitle(exe, title)
        mode := this.IsWindowMode(exe) ? "window" : "app"
        identityKey := StrLower(exe)
        if (mode = "window")
            identityKey .= "|" StrLower(className) "|" StrLower(normalizedTitle)
        return Map(
            "hwnd", root,
            "sourceHwnd", hwnd,
            "pid", pid,
            "threadId", threadId,
            "path", path,
            "exe", exe,
            "class", className,
            "title", title,
            "normalizedTitle", normalizedTitle,
            "mode", mode,
            "identityKey", identityKey
        )
    }

    IsWindowMode(exe) {
        exe := StrLower(exe)
        for item in this.Config.WindowModeExe {
            if (StrLower(item) = exe)
                return true
        }
        return false
    }

    IsIgnored(exe, className, hwnd) {
        if !DllCall("user32\IsWindowVisible", "Ptr", hwnd, "Int")
            return true
        exeLower := StrLower(exe)
        for item in this.Config.IgnoreExe {
            if (StrLower(item) = exeLower)
                return true
        }
        try {
            if (this.Config.IgnoreClassRegex != "" && RegExMatch(className, this.Config.IgnoreClassRegex))
                return true
        }
        return false
    }

    NormalizeClass(className) {
        return RegExReplace(className, "i)^HwndWrapper\[([^;]+);([^;]+);.*\]$", "HwndWrapper[$1;$2]")
    }

    NormalizeTitle(exe, title) {
        title := RegExReplace(Trim(title), "\s+", " ")
        exe := StrLower(exe)
        if (exe = "msedge.exe") {
            title := RegExReplace(title, "i)\s+-\s+[^-]*Microsoft.? Edge$", "")
            title := RegExReplace(title, "i)\s+and \d+ more pages?$", "")
            title := RegExReplace(title, "\s+和另外\s*\d+\s*个页面$", "")
        } else if (exe = "chrome.exe") {
            title := RegExReplace(title, "i)\s+-\s+Google Chrome$", "")
        } else if (exe = "explorer.exe") {
            title := RegExReplace(title, "\s+和\s*\d+\s*个其他选项卡\s*-\s*文件资源管理器$", "")
            title := RegExReplace(title, "\s*-\s*文件资源管理器$", "")
        }
        return title
    }

    GetFocusTarget(windowInfo) {
        threadId := MapGet(windowInfo, "threadId", 0)
        root := MapGet(windowInfo, "hwnd", 0)
        if !threadId
            return Map("hwnd", root, "threadId", 0)
        size := A_PtrSize = 8 ? 72 : 48
        info := Buffer(size, 0)
        NumPut("UInt", size, info, 0)
        ok := DllCall("user32\GetGUIThreadInfo", "UInt", threadId, "Ptr", info, "Int")
        focusOffset := A_PtrSize = 8 ? 16 : 12
        focus := ok ? NumGet(info, focusOffset, "Ptr") : 0
        return Map("hwnd", focus ? focus : root, "threadId", threadId)
    }

    QueryProcessPath(pid) {
        process := DllCall("kernel32\OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
        if !process
            return ""
        try {
            chars := 32768
            pathBytes := Buffer(chars * 2, 0)
            if DllCall("kernel32\QueryFullProcessImageNameW", "Ptr", process, "UInt", 0, "Ptr", pathBytes, "UInt*", &chars, "Int")
                return StrGet(pathBytes, chars, "UTF-16")
            return ""
        } finally {
            DllCall("kernel32\CloseHandle", "Ptr", process)
        }
    }
}
