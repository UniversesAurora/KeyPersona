#Requires AutoHotkey v2.0

class WindowIdentity {
    __New(config, rules := 0) {
        this.Config := config
        this.Rules := rules
        this.CurrentPid := DllCall("kernel32\GetCurrentProcessId", "UInt")
    }

    Resolve(hwnd := 0, &pending := unset) {
        windowInfo := this.ReadWindowInfo(hwnd, &pending)
        if !windowInfo.Count
            return windowInfo

        selector := windowInfo["classSelector"]
        useOnlyClass := selector != "" && this.Rules && this.Rules.ClassOnlyRules.Length
            && this.Rules.Match(windowInfo, true).Count
        if !useOnlyClass
            this.ReadProcessIdentity(windowInfo)

        if windowInfo["exe"] = "" && selector != "" && (useOnlyClass
            || (this.Rules && this.Rules.Match(windowInfo).Count)
            || this.Config.AppInputPolicies.Has(StrLower(selector)))
            windowInfo["exe"] := selector

        exe := windowInfo["exe"]
        if !this.IsWindowVisible(windowInfo["hwnd"]) {
            pending := windowInfo
            return Map()
        }
        if this.IsIgnored(exe, windowInfo["class"])
            return Map()
        if exe = "" {
            pending := windowInfo
            return Map()
        }
        return this.AssignIdentity(windowInfo)
    }

    AssignIdentity(windowInfo) {
        exe := windowInfo["exe"]
        normalizedTitle := this.NormalizeTitle(exe, windowInfo["title"])
        mode := this.IsWindowMode(exe) ? "window" : "app"
        packageFamily := MapGet(windowInfo, "packageFamily", "")
        appSelector := WindowIdentity.AppSelector(exe, packageFamily)
        sharedIdentity := StrLower(exe)
        pathIdentity := this.Rules && this.Rules.UsesPathIdentity(windowInfo) ? "path:" StrLower(windowInfo["path"]) : ""
        binding := packageFamily = "" && this.Config.AppIdentitiesByPath.Count
            ? MapGet(this.Config.AppIdentitiesByPath, KeyPersonaConfig.AppPathKey(windowInfo["path"]), 0) : 0
        appId := binding && binding.enabled ? binding.id : ""
        inheritedIdentity := ""
        if appId != "" {
            appSelector := "app:" appId
            appIdentity := appSelector
            inheritedIdentity := sharedIdentity
        } else if packageFamily != "" {
            appIdentity := "package:" appSelector
            inheritedIdentity := pathIdentity != "" ? pathIdentity : sharedIdentity
        } else {
            appIdentity := pathIdentity != "" ? pathIdentity : sharedIdentity
        }
        suffix := ""
        if mode = "window"
            suffix := "|" StrLower(windowInfo["class"]) "|" StrLower(normalizedTitle)
        windowInfo["normalizedTitle"] := normalizedTitle
        windowInfo["mode"] := mode
        windowInfo["appSelector"] := appSelector
        windowInfo["appIdentity"] := appIdentity
        windowInfo["appId"] := appId
        windowInfo["identityKey"] := appIdentity suffix
        windowInfo["legacyIdentityKey"] := inheritedIdentity = "" ? "" : inheritedIdentity suffix
        return windowInfo
    }

    static AppSelector(exe, packageFamily := "") {
        return StrLower(packageFamily = "" ? exe : exe "|" packageFamily)
    }

    static CanIsolateInstallation(windowInfo) {
        return MapGet(windowInfo, "packageFamily", "") = ""
            && KeyPersonaConfig.AppPathKey(MapGet(windowInfo, "path", "")) != ""
    }

    static AppSelectorFor(windowInfo) {
        return MapGet(windowInfo, "appSelector", StrLower(MapGet(windowInfo, "exe", "")))
    }

    static AppLabel(windowInfo) {
        exe := MapGet(windowInfo, "exe", "")
        family := MapGet(windowInfo, "packageFamily", "")
        return family = "" ? exe : exe " · " RegExReplace(family, "_[^_]+$")
    }

    ReadWindowInfo(hwnd := 0, &pending := unset) {
        pending := Map()
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
        if !this.IsWindowVisible(root) {
            pending := Map("hwnd", root, "pid", pid, "threadId", threadId)
            return Map()
        }

        classText := Buffer(512, 0)
        classLength := DllCall("user32\GetClassNameW", "Ptr", root, "Ptr", classText, "Int", 256, "Int")
        rawClass := classLength ? StrGet(classText, classLength, "UTF-16") : ""
        title := ""
        try title := WinGetTitle("ahk_id " root)
        return Map("hwnd", root, "pid", pid, "threadId", threadId, "path", "", "exe", "",
            "class", this.NormalizeClass(rawClass), "classSelector", rawClass != "" ? "class:" rawClass : "",
            "title", title)
    }

    ReadProcessIdentity(windowInfo) {
        root := windowInfo["hwnd"]
        path := ""
        process := DllCall("kernel32\OpenProcess", "UInt", 0x1000, "Int", false, "UInt", windowInfo["pid"], "Ptr")
        if process {
            try {
                path := this.QueryProcessPath(process)
                windowInfo["packageFamily"] := this.QueryPackageFamily(process)
            } finally {
                DllCall("kernel32\CloseHandle", "Ptr", process)
            }
        }
        if path = "" {
            try path := WinGetProcessPath("ahk_id " root)
        }
        exe := ""
        if path != ""
            SplitPath(path, &exe)
        if exe = "" {
            try exe := WinGetProcessName("ahk_id " root)
        }
        windowInfo["path"] := path
        windowInfo["exe"] := exe
    }

    IsCurrentWindow(windowInfo) {
        hwnd := MapGet(windowInfo, "hwnd", 0)
        if !hwnd
            return false
        pid := 0
        threadId := DllCall("user32\GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid, "UInt")
        return pid = windowInfo["pid"] && threadId = windowInfo["threadId"]
    }

    IsTrayWindow(hwnd) {
        if !hwnd
            return false
        if hwnd = A_ScriptHwnd
            return true
        try return RegExMatch(WinGetClass("ahk_id " hwnd),
            "i)^(Shell_(Secondary)?TrayWnd|TopLevelWindowForOverflowXamlIsland|NotifyIconOverflowWindow|XamlExplorerHostIslandWindow)$") > 0
        return false
    }

    IsTransientForeground(hwnd) {
        return !hwnd || this.IsTrayWindow(hwnd) || this.IsInputOverlay(hwnd)
    }

    IsInputOverlay(hwnd) {
        if !hwnd
            return false
        try return RegExMatch(WinGetClass("ahk_id " hwnd), "i)^(IME|MSCTFIME UI|tooltips_class32)$") > 0
            || RegExMatch(WinGetProcessName("ahk_id " hwnd), "i)^(TextInputHost|ctfmon)\.exe$") > 0
        return false
    }

    IsWindowMode(exe) {
        exe := StrLower(exe)
        for item in this.Config.WindowModeExe {
            if (StrLower(item) = exe)
                return true
        }
        return false
    }

    IsIgnored(exe, className) {
        exeLower := StrLower(exe)
        if ((exeLower = "explorer.exe" || InStr(exeLower, "class:") = 1) && RegExMatch(className,
            "i)^(Progman|WorkerW|Shell_(Secondary)?TrayWnd|TopLevelWindowForOverflowXamlIsland|NotifyIconOverflowWindow|XamlExplorerHostIslandWindow)$"))
            return true
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

    IsWindowVisible(hwnd) {
        return DllCall("user32\IsWindowVisible", "Ptr", hwnd, "Int") != 0
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

    GetFocusTarget(windowInfo, foreground := false) {
        threadId := MapGet(windowInfo, "threadId", 0)
        root := MapGet(windowInfo, "hwnd", 0)
        if !threadId
            return Map("hwnd", root, "threadId", 0, "focused", false)
        size := A_PtrSize = 8 ? 72 : 48
        info := Buffer(size, 0)
        NumPut("UInt", size, info, 0)
        ok := DllCall("user32\GetGUIThreadInfo", "UInt", foreground ? 0 : threadId, "Ptr", info, "Int")
        focusOffset := A_PtrSize = 8 ? 16 : 12
        focus := ok ? NumGet(info, focusOffset, "Ptr") : 0
        if focus && DllCall("user32\GetAncestor", "Ptr", focus, "UInt", 2, "Ptr") = root {
            focusThread := DllCall("user32\GetWindowThreadProcessId", "Ptr", focus, "Ptr", 0, "UInt")
            if focusThread
                return Map("hwnd", focus, "threadId", focusThread, "focused", true)
        }
        return Map("hwnd", root, "threadId", threadId, "focused", false)
    }

    GetForegroundFocus(windowInfo) {
        foreground := DllCall("user32\GetForegroundWindow", "Ptr")
        if !foreground || foreground != MapGet(windowInfo, "hwnd", 0)
            return Map()
        return this.GetFocusTarget(windowInfo, true)
    }

    IsForegroundFocus(windowInfo, focus) {
        current := this.GetForegroundFocus(windowInfo)
        return current.Count && WindowIdentity.SameFocus(current, focus)
    }

    static SameFocus(left, right) {
        return left["hwnd"] = right["hwnd"] && left["threadId"] = right["threadId"]
            && left["focused"] = right["focused"]
    }

    QueryProcessPath(process) {
        chars := 32768
        pathBytes := Buffer(chars * 2, 0)
        if DllCall("kernel32\QueryFullProcessImageNameW", "Ptr", process, "UInt", 0, "Ptr", pathBytes, "UInt*", &chars, "Int")
            return StrGet(pathBytes, chars, "UTF-16")
        return ""
    }

    QueryPackageFamily(process) {
        ; PACKAGE_FAMILY_NAME_MAX_LENGTH plus the terminating null.
        chars := 65
        nameBuffer := Buffer(chars * 2, 0)
        if DllCall("kernel32\GetPackageFamilyName", "Ptr", process, "UInt*", &chars, "Ptr", nameBuffer, "Int") = 0
            return StrGet(nameBuffer, "UTF-16")
        return ""
    }
}
