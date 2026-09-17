#Requires AutoHotkey v2.0

class LegacyMigration {
    static MigrateRuntimeFiles(baseDir) {
        for oldName in AppInfo.LegacyLogFiles {
            oldPath := baseDir "\" oldName
            newPath := baseDir "\" AppInfo.LogFile
            if FileExist(oldPath) && !FileExist(newPath)
                FileMove(oldPath, newPath)
        }
        LegacyMigration.ReplaceTexts(baseDir "\" AppInfo.ConfigFile, Map(
            "; IME Memory 用户配置。", "; " AppInfo.Name " 用户配置。",
            "tools\ime-probe.ahk", "tools\KeyPersona-probe.ahk",
            "ignoreExe=ime-memory.exe,", "ignoreExe="
        ))
        stateReplacements := Map(
            "; Managed by IME Memory.", "; Managed by " AppInfo.Name ".",
            "IME Memory", AppInfo.Name,
            "ime-memory", AppInfo.Slug
        )
        LegacyMigration.ReplaceTexts(baseDir "\" AppInfo.StateFile, stateReplacements)
        LegacyMigration.ReplaceTexts(baseDir "\" AppInfo.StateFile ".bak", stateReplacements)
        LegacyMigration.ReplaceTexts(baseDir "\" AppInfo.LogFile, Map(
            "IME Memory", AppInfo.Name,
            "ime-memory", AppInfo.Slug
        ))
    }

    static ReplaceTexts(path, replacements) {
        if !FileExist(path)
            return false
        try text := FileRead(path, "UTF-8")
        catch
            return false
        updated := text
        for oldText, newText in replacements
            updated := StrReplace(updated, oldText, newText)
        if (updated = text)
            return false
        tempPath := path ".rename." DllCall("kernel32\GetCurrentProcessId", "UInt")
        try {
            try FileDelete(tempPath)
            FileAppend(updated, tempPath, "UTF-8")
            if !DllCall("kernel32\MoveFileExW", "WStr", tempPath, "WStr", path, "UInt", 0x1 | 0x8, "Int")
                throw OSError(A_LastError, "MoveFileExW")
            return true
        } catch {
            try FileDelete(tempPath)
            return false
        }
    }
}
