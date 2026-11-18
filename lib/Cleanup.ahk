#Requires AutoHotkey v2.0

class InvalidEntryScan {
    __New(doc) {
        this.Doc := doc
        this.Paths := Map()
        this.Packages := Map()
    }

    FindConfig() {
        items := Map()
        for section in this.Doc.SectionOrder {
            if this.Doc.RepeatedSections.Has(section)
                continue
            values := this.Doc.Sections[section]
            problem := ""
            if RegExMatch(section, "i)^app-identity\.") {
                problem := this.PathProblem(MapGet(values, "path", ""))
            } else if RegExMatch(section, "i)^(rule|window-rule)\.", &kind) {
                if kind[1] = "window-rule" {
                    problem := this.IdentityProblem(IniUnescape(MapGet(values, "identityKey", "")))
                } else {
                    problem := this.PathProblem(MapGet(values, "path", ""))
                    if problem = ""
                        problem := this.PackageProblem(MapGet(values, "packageFamily", ""))
                }
                state := MapGet(values, "state", "")
                if problem = "" && state != "" && state != "@global" && !this.Doc.Sections.Has("state." state)
                    problem := "找不到输入法状态 " state
            } else if RegExMatch(section, "i)^(input-app|punctuation-app)\.") {
                appId := MapGet(values, "appId", "")
                problem := appId != "" ? this.AppProblem(appId) : this.PackageProblem(MapGet(values, "packageFamily", ""))
            }
            if problem != ""
                items[section] := "[" section "]  " problem
        }
        return items
    }

    FindMemory(records) {
        items := Map()
        for identityKey in records {
            problem := this.IdentityProblem(identityKey)
            if problem != ""
                items[identityKey] := identityKey "  " problem
        }
        return items
    }

    IdentityProblem(identityKey) {
        if identityKey = ""
            return ""
        parts := StrSplit(identityKey, "|",, 3)
        first := parts[1]
        if InStr(first, "app:") = 1
            return this.AppProblem(SubStr(first, 5))
        if InStr(first, "path:") = 1
            return this.PathProblem(SubStr(first, 6))
        if InStr(first, "package:") = 1 && parts.Length >= 2
            return this.PackageProblem(parts[2])
        return ""
    }

    AppProblem(id) {
        if id = ""
            return ""
        section := "app-identity." id
        if !this.Doc.Sections.Has(section)
            return "找不到应用身份 " id
        if this.Doc.RepeatedSections.Has(section)
            return ""
        return this.PathProblem(this.Doc.Get(section, "path", ""))
    }

    PathProblem(path) {
        path := StrReplace(Trim(path), "/", "\")
        key := KeyPersonaConfig.AppPathKey(path)
        ; Check fixed local drives. Network and removable locations may be offline.
        if !RegExMatch(key, "^[a-z]:\\")
            return ""
        if !this.Paths.Has(path)
            this.Paths[path] := this.IsMissingPath(path) ? "找不到 EXE " path : ""
        return this.Paths[path]
    }

    IsMissingPath(path) {
        root := SubStr(KeyPersonaConfig.AppPathKey(path), 1, 3)
        if DllCall("kernel32\GetDriveTypeW", "WStr", root, "UInt") != 3
            return false
        attrs := DllCall("kernel32\GetFileAttributesW", "WStr", path, "UInt")
        status := A_LastError
        if attrs != 0xFFFFFFFF || (status != 2 && status != 3)
            return false
        ; A local path may run through a disconnected mount or junction.
        current := InStr(path, "\\?\") = 1 ? SubStr(path, 5) : path
        loop {
            SplitPath(current,, &parent)
            if StrLen(parent) <= 3 || parent = current
                break
            attrs := DllCall("kernel32\GetFileAttributesW", "WStr", parent, "UInt")
            status := A_LastError
            if attrs = 0xFFFFFFFF {
                if status != 2 && status != 3
                    return false
            } else if attrs & 0x1400 { ; FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_OFFLINE
                return false
            }
            current := parent
        }
        return DllCall("kernel32\GetDriveTypeW", "WStr", root, "UInt") = 3
    }

    PackageProblem(family) {
        key := StrLower(family)
        if !RegExMatch(key, "^[a-z0-9][a-z0-9.-]{2,49}_[0-9a-hj-km-np-tv-z]{13}$")
            return ""
        if !this.Packages.Has(key) {
            count := 0
            chars := 0
            status := DllCall("kernel32\GetPackagesByPackageFamily", "WStr", family,
                "UInt*", &count, "Ptr", 0, "UInt*", &chars, "Ptr", 0, "Int")
            this.Packages[key] := status = 0 && count = 0 ? "当前用户未安装应用包 " family : ""
        }
        return this.Packages[key]
    }
}

class InvalidEntryCleanup {
    __New(app) {
        this.App := app
        this.Dialog := 0
    }

    Scan(scope) {
        source := FileRead(this.App.Config.Path, "UTF-8")
        scan := InvalidEntryScan(IniDocument.Parse(source))
        return {source: source, items: scope = "config" ? scan.FindConfig() : scan.FindMemory(this.App.Store.Records)}
    }

    Show(scope, *) {
        try {
            snapshot := this.Scan(scope)
            this.Close()
            if !snapshot.items.Count {
                TrayTip(scope = "config" ? "没有找到可清理的失效配置。" : "没有找到可清理的失效记忆。", AppInfo.Name, "Mute")
                return
            }
            title := scope = "config" ? "清除失效配置" : "清除失效记忆"
            dialog := Gui("+ToolWindow -MinimizeBox -MaximizeBox", title " · " AppInfo.Name)
            this.Dialog := dialog
            dialog.SetFont("s10", "Segoe UI")
            dialog.AddText("w570", "将清除以下 " snapshot.items.Count " 项。程序搬家时，可先更新配置里的路径。")
            lines := []
            for _, line in snapshot.items
                lines.Push(line)
            dialog.AddEdit("w570 r12 ReadOnly", JoinValues(lines, "`r`n"))
            dialog.AddButton("w95", "清除").OnEvent("Click", ObjBindMethod(this, "Apply", scope, snapshot))
            cancel := dialog.AddButton("x+8 w95 Default", "取消")
            cancel.OnEvent("Click", ObjBindMethod(this, "Close"))
            dialog.OnEvent("Escape", ObjBindMethod(this, "Close"))
            dialog.OnEvent("Close", ObjBindMethod(this, "Close"))
            dialog.Show()
            cancel.Focus()
        } catch Error as failure {
            this.Close()
            this.ReportFailure(failure)
        }
    }

    Apply(scope, snapshot, *) {
        this.Close()
        Critical "On"
        try {
            current := this.Scan(scope)
            if scope = "config" && !(current.source == snapshot.source) {
                TrayTip("配置已更新，请重新检查。", AppInfo.Name, "Mute")
                return
            }
            keys := []
            for key in snapshot.items {
                if current.items.Has(key)
                    keys.Push(key)
            }
            if !keys.Length {
                TrayTip("这些条目已不需要清理。", AppInfo.Name, "Mute")
                return
            }
            if scope = "config" {
                changes := []
                for key in keys
                    changes.Push([key])
                if !this.App.Config.WriteChanges(changes, current.source) {
                    TrayTip("配置已更新，请重新检查。", AppInfo.Name, "Mute")
                    return
                }
                this.App.Config.Reload()
                this.App.RefreshRuleEngine()
                this.App.Punctuation.RefreshBindings()
                this.App.ForegroundHwnd := -1
                this.App.QueueWindowCheck()
            } else if !this.App.ClearInvalidMemory(keys) {
                TrayTip("清除结果暂未写入磁盘，将再次尝试保存。", AppInfo.Name, "Iconx")
                return
            }
            TrayTip("已清除 " keys.Length (scope = "config" ? " 项失效配置。" : " 条失效记忆。"), AppInfo.Name, "Mute")
        } catch Error as failure {
            this.ReportFailure(failure)
        }
    }

    Close(*) {
        if this.Dialog {
            this.Dialog.Destroy()
            this.Dialog := 0
        }
    }

    ReportFailure(failure) {
        this.App.Logger.Error("Invalid entry cleanup failed: " failure.Message)
        TrayTip("清理失败，请检查程序目录和配置文件。", AppInfo.Name, "Iconx")
    }
}
