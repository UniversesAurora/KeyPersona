#Requires AutoHotkey v2.0

class StartupManager {
    static RunKey := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run"
    static ValueName := "IME Memory"

    __New(logger) {
        this.Logger := logger
    }

    CommandLine() {
        quote := Chr(34)
        if A_IsCompiled
            return quote A_ScriptFullPath quote " --startup"
        return quote A_AhkPath quote " " quote A_ScriptFullPath quote " --startup"
    }

    IsEnabled() {
        configured := this.RegisteredCommand()
        if (configured = "")
            return false
        return StrLower(Trim(configured)) = StrLower(this.CommandLine())
    }

    IsRegistered() {
        return this.RegisteredCommand() != ""
    }

    RegisteredCommand() {
        try return RegRead(StartupManager.RunKey, StartupManager.ValueName)
        return ""
    }

    Enable() {
        command := this.CommandLine()
        RegWrite(command, "REG_SZ", StartupManager.RunKey, StartupManager.ValueName)
        if !this.IsEnabled()
            throw Error("Windows startup registration could not be verified")
        this.Logger.Info("Startup enabled")
        return true
    }

    Disable() {
        try RegDelete(StartupManager.RunKey, StartupManager.ValueName)
        if this.IsRegistered()
            throw Error("Windows startup registration could not be removed")
        this.Logger.Info("Startup disabled")
        return false
    }

    Toggle() {
        return this.IsEnabled() ? this.Disable() : this.Enable()
    }
}
