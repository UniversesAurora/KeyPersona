#Requires AutoHotkey v2.0

class StartupManager {
    static LegacyRunKey := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run"
    static ValueName := "IME Memory"
    static ShortcutName := "IME Memory.lnk"

    __New(logger) {
        this.Logger := logger
    }

    ShortcutPath() {
        return A_Startup "\" StartupManager.ShortcutName
    }

    TargetPath() {
        return A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    }

    Arguments() {
        quote := Chr(34)
        return A_IsCompiled ? "--startup" : quote A_ScriptFullPath quote " --startup"
    }

    WorkingDirectory() {
        return A_IsCompiled ? A_ScriptDir : RuntimeBaseDir()
    }

    CommandLine() {
        return Chr(34) this.TargetPath() Chr(34) " " this.Arguments()
    }

    IsEnabled() {
        shortcut := this.ShortcutPath()
        if !FileExist(shortcut)
            return false
        try {
            FileGetShortcut(shortcut, &target, &workingDirectory, &arguments)
            return StrLower(target) = StrLower(this.TargetPath())
                && StrLower(Trim(arguments)) = StrLower(Trim(this.Arguments()))
                && StrLower(Trim(workingDirectory)) = StrLower(Trim(this.WorkingDirectory()))
        }
        return false
    }

    IsRegistered() {
        return FileExist(this.ShortcutPath()) || this.LegacyCommand() != ""
    }

    LegacyCommand() {
        try return RegRead(StartupManager.LegacyRunKey, StartupManager.ValueName)
        return ""
    }

    Enable() {
        shortcut := this.ShortcutPath()
        icon := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\assets\ime-memory.ico"
        FileCreateShortcut(
            this.TargetPath(),
            shortcut,
            this.WorkingDirectory(),
            this.Arguments(),
            "IME Memory",
            icon
        )
        if !this.IsEnabled() {
            try FileDelete(shortcut)
            throw Error("Windows startup shortcut could not be verified")
        }
        this.RemoveLegacyRun()
        if (this.LegacyCommand() != "") {
            try FileDelete(shortcut)
            throw Error("Legacy startup registration could not be removed")
        }
        this.Logger.Info("Startup enabled with the current-user Startup folder")
        return true
    }

    Disable() {
        shortcut := this.ShortcutPath()
        if FileExist(shortcut)
            FileDelete(shortcut)
        this.RemoveLegacyRun()
        if this.IsRegistered()
            throw Error("Windows startup registration could not be removed")
        this.Logger.Info("Startup disabled")
        return false
    }

    MigrateLegacy() {
        if !A_IsCompiled || this.LegacyCommand() = ""
            return false
        if this.IsEnabled() {
            this.RemoveLegacyRun()
            return true
        }
        this.Enable()
        this.Logger.Info("Migrated startup registration from Run to the Startup folder")
        return true
    }

    RemoveLegacyRun() {
        try RegDelete(StartupManager.LegacyRunKey, StartupManager.ValueName)
    }

    Toggle() {
        return this.IsEnabled() ? this.Disable() : this.Enable()
    }
}
