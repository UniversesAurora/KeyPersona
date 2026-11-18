#Requires AutoHotkey v2.0

class StartupManager {
    static LegacyRunKey := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run"
    static ValueName := AppInfo.StartupValueName
    static ShortcutName := AppInfo.StartupShortcutName

    __New(logger, adminMode := false) {
        this.Logger := logger
        this.AdminMode := adminMode
        this.Sid := ""
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
        return this.AdminMode ? this.IsTaskEnabled() : this.IsShortcutEnabled()
    }

    IsShortcutEnabled() {
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

    LegacyCommand() {
        for valueName in AppInfo.LegacyStartupValueNames {
            try {
                value := RegRead(StartupManager.LegacyRunKey, valueName)
                if (value != "")
                    return value
            }
        }
        return ""
    }

    HasLegacyRegistration() {
        if (this.LegacyCommand() != "")
            return true
        for shortcutName in AppInfo.LegacyStartupShortcutNames {
            if FileExist(A_Startup "\" shortcutName)
                return true
        }
        return false
    }

    GetSid() {
        if this.Sid = ""
            this.Sid := ElevationManager.AccountSid()
        return this.Sid
    }

    TaskName() {
        return AppInfo.Name "-" this.GetSid()
    }

    OpenScheduler() {
        scheduler := ComObject("Schedule.Service")
        scheduler.Connect()
        return scheduler
    }

    GetElevatedTask(folder := unset) {
        if !IsSet(folder) {
            scheduler := this.OpenScheduler()
            folder := scheduler.GetFolder("\")
        }
        try return folder.GetTask(this.TaskName())
        catch Error as failure {
            if !StartupManager.IsMissingTask(failure)
                throw failure
            return 0
        }
    }

    static IsMissingTask(failure) {
        return (failure is OSError && (failure.Number & 0xFFFFFFFF) = 0x80070002)
            || RegExMatch(failure.Message, "i)^\(0x80070002\)")
    }

    TaskUsesCurrentAccount(definition) {
        sid := this.GetSid()
        return ElevationManager.ResolveAccountSid(definition.Principal.UserId) = sid
            && ElevationManager.ResolveAccountSid(definition.Triggers.Item(1).UserId) = sid
    }

    IsTaskEnabled(task := unset) {
        try {
            if !IsSet(task)
                task := this.GetElevatedTask()
            if !task || !task.Enabled
                return false
            definition := task.Definition
            if definition.Actions.Count != 1 || definition.Triggers.Count != 1
                return false
            action := definition.Actions.Item(1)
            trigger := definition.Triggers.Item(1)
            return definition.Principal.RunLevel = 1 && definition.Principal.LogonType = 3
                && this.TaskUsesCurrentAccount(definition)
                && trigger.Type = 9 && trigger.Enabled && action.Type = 0
                && StrLower(action.Path) = StrLower(this.TargetPath())
                && StrLower(action.Arguments) = StrLower(this.Arguments())
                && StrLower(action.WorkingDirectory) = StrLower(this.WorkingDirectory())
        }
        return false
    }

    MakeTaskDefinition(scheduler) {
        definition := scheduler.NewTask(0)
        sid := this.GetSid()
        definition.RegistrationInfo.Description := AppInfo.Name " (current-user logon)"
        definition.Principal.UserId := sid
        definition.Principal.LogonType := 3 ; TASK_LOGON_INTERACTIVE_TOKEN
        definition.Principal.RunLevel := 1 ; TASK_RUNLEVEL_HIGHEST
        definition.Settings.Enabled := true
        definition.Settings.DisallowStartIfOnBatteries := false
        definition.Settings.StopIfGoingOnBatteries := false
        definition.Settings.ExecutionTimeLimit := "PT0S"
        definition.Settings.MultipleInstances := 2 ; TASK_INSTANCES_IGNORE_NEW
        trigger := definition.Triggers.Create(9) ; TASK_TRIGGER_LOGON
        trigger.UserId := sid
        action := definition.Actions.Create(0) ; TASK_ACTION_EXEC
        action.Path := this.TargetPath()
        action.Arguments := this.Arguments()
        action.WorkingDirectory := this.WorkingDirectory()
        return definition
    }

    EnableElevatedTask() {
        scheduler := this.OpenScheduler()
        folder := scheduler.GetFolder("\")
        task := folder.RegisterTaskDefinition(this.TaskName(), this.MakeTaskDefinition(scheduler),
            6, this.GetSid(), ComValue(0, 0), 3)
        if !this.IsTaskEnabled(task) {
            try folder.DeleteTask(this.TaskName(), 0)
            throw Error("Windows 计划任务校验失败。")
        }
        try this.RemoveShortcut()
        catch Error as failure {
            try folder.DeleteTask(this.TaskName(), 0)
            throw failure
        }
    }

    RemoveElevatedTask() {
        scheduler := this.OpenScheduler()
        folder := scheduler.GetFolder("\")
        if this.GetElevatedTask(folder)
            folder.DeleteTask(this.TaskName(), 0)
    }

    RemoveShortcut() {
        shortcut := this.ShortcutPath()
        if FileExist(shortcut)
            FileDelete(shortcut)
    }

    ChangeAdminMode(enabled) {
        previous := this.AdminMode
        if previous = enabled
            return
        hadStartup := this.IsShortcutEnabled() || this.IsTaskEnabled() || this.HasLegacyRegistration()
        this.AdminMode := enabled
        try {
            if hadStartup
                this.Enable()
        } catch Error as failure {
            this.AdminMode := previous
            throw failure
        }
    }

    Enable() {
        if this.AdminMode
            this.EnableElevatedTask()
        else
            this.EnableShortcut()
        this.RemoveLegacyRegistrations()
        if this.HasLegacyRegistration() {
            if this.AdminMode {
                try this.RemoveElevatedTask()
            } else {
                try this.RemoveShortcut()
            }
            throw Error("旧自启动入口无法移除。")
        }
        this.Logger.Info("Startup enabled" (this.AdminMode ? " via elevated logon task" : " via Startup folder"))
        return true
    }

    EnableShortcut() {
        shortcut := this.ShortcutPath()
        icon := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\" AppInfo.IconFile
        FileCreateShortcut(
            this.TargetPath(),
            shortcut,
            this.WorkingDirectory(),
            this.Arguments(),
            AppInfo.Name,
            icon
        )
        if !this.IsShortcutEnabled() {
            try FileDelete(shortcut)
            throw Error("Windows 自启动快捷方式校验失败。")
        }
        if A_IsAdmin {
            try this.RemoveElevatedTask()
            catch Error as failure {
                try this.RemoveShortcut()
                throw failure
            }
        }
    }

    Disable() {
        if this.AdminMode || A_IsAdmin
            this.RemoveElevatedTask()
        this.RemoveShortcut()
        this.RemoveLegacyRegistrations()
        if FileExist(this.ShortcutPath()) || this.HasLegacyRegistration()
            throw Error("Windows startup registration could not be removed")
        this.Logger.Info("Startup disabled")
        return false
    }

    MigrateLegacy() {
        if this.AdminMode && !this.IsTaskEnabled() && this.IsShortcutEnabled() {
            this.Enable()
            return true
        }
        if !this.AdminMode && A_IsAdmin && this.IsTaskEnabled() {
            this.Enable()
            return true
        }
        if !A_IsCompiled || !this.HasLegacyRegistration()
            return false
        if this.IsEnabled() {
            this.RemoveLegacyRegistrations()
            return true
        }
        this.Enable()
        this.Logger.Info("Migrated startup registration from Run to the Startup folder")
        return true
    }

    RemoveLegacyRegistrations() {
        try RegDelete(StartupManager.LegacyRunKey, StartupManager.ValueName)
        for valueName in AppInfo.LegacyStartupValueNames
            try RegDelete(StartupManager.LegacyRunKey, valueName)
        for shortcutName in AppInfo.LegacyStartupShortcutNames {
            legacyShortcut := A_Startup "\" shortcutName
            if FileExist(legacyShortcut)
                try FileDelete(legacyShortcut)
        }
    }

    Toggle() {
        return this.IsEnabled() ? this.Disable() : this.Enable()
    }
}
