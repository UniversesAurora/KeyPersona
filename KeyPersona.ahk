#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
Persistent

#Include lib\AppInfo.ahk
#Include lib\LegacyMigration.ahk
#Include lib\Utils.ahk
#Include lib\Config.ahk
#Include lib\ElevationManager.ahk
#Include lib\StartupManager.ahk
#Include lib\AboutDialog.ahk
#Include lib\StateStore.ahk
#Include lib\WindowIdentity.ahk
#Include lib\Rules.ahk
#Include lib\InputProfiles.ahk
#Include lib\ImeMode.ahk
#Include lib\InputRestoration.ahk
#Include lib\InputEnforcement.ahk
#Include lib\Punctuation.ahk
#Include lib\WinEventHook.ahk
#Include lib\InputChangeKeys.ahk
#Include lib\Cleanup.ahk
#Include lib\TrayMenu.ahk
#Include lib\App.ahk
#Include lib\SelfTest.ahk

SetWorkingDir(A_ScriptDir)
if !A_IsCompiled && FileExist(A_ScriptDir "\" AppInfo.IconFile)
    TraySetIcon(A_ScriptDir "\" AppInfo.IconFile)
OnError(GlobalErrorHandler)

if HasArgument("--self-test") {
    ExitApp(RunSelfTests(A_ScriptDir))
}

observeOnly := HasArgument("--observe-only")
if observeOnly
    A_IconHidden := true
smokeSeconds := ArgumentValue("--smoke-seconds=", 0)
appBaseDir := RuntimeBaseDir()
try {
    if !observeOnly {
        parentPid := ParseInt(ArgumentText("--admin-parent="), 0, 0)
        if parentPid
            ElevationManager.WaitForHandoff(parentPid, ArgumentText("--admin-owner="))
        if !AcquireRuntimeLock(appBaseDir)
            ExitApp()
        if !A_IsAdmin {
            launchConfig := IniDocument.Load(appBaseDir "\" AppInfo.ConfigFile)
            if ParseBool(launchConfig.Get("general", "runAsAdmin", "0")) {
                ElevationManager.RequestRestart(appBaseDir)
                ExitApp()
            }
        }
    }
    global KEYPERSONA_APP := KeyPersonaApp(appBaseDir, observeOnly)
    OnExit(ObjBindMethod(KEYPERSONA_APP, "Shutdown"))
    if !observeOnly && A_IsAdmin && parentPid && HasArgument("--enable-admin") {
        try KEYPERSONA_APP.ApplyAdminPreference(true)
        catch Error as adminSetupError {
            KEYPERSONA_APP.Logger.Error("Could not save administrator preference: " adminSetupError.Message)
            TrayTip("本次以管理员身份运行。未能保存设置。" adminSetupError.Message, AppInfo.Name, "Iconx")
        }
    }
    KEYPERSONA_APP.Start()
    if (smokeSeconds > 0)
        SetTimer((*) => ExitApp(), -smokeSeconds * 1000)
} catch Error as startupError {
    try KEYPERSONA_APP.Logger.Error("Fatal startup error: " startupError.Message " at " startupError.File ":" startupError.Line)
    FileAppend(AppInfo.Name " startup failed: " startupError.Message "`n", "**", "UTF-8")
    if !observeOnly
        TrayTip("启动失败。" startupError.Message, AppInfo.Name, "Iconx")
    ExitApp(1)
}

AcquireRuntimeLock(baseDir) {
    normalized := StrLower(RTrim(baseDir, "\"))
    mutexName := "Local\" AppInfo.Name "." Fnv1a32(normalized) "." Fnv1a32(normalized "|" StrLen(normalized))
    existing := DllCall("kernel32\OpenMutexW", "UInt", 0x100000, "Int", false, "WStr", mutexName, "Ptr")
    if existing {
        DllCall("kernel32\CloseHandle", "Ptr", existing)
        return false
    }
    handle := DllCall("kernel32\CreateMutexW", "Ptr", 0, "Int", false, "WStr", mutexName, "Ptr")
    status := A_LastError
    if !handle
        throw OSError(status, "CreateMutexW")
    if (status = 183) {
        DllCall("kernel32\CloseHandle", "Ptr", handle)
        return false
    }
    ; The handle stays open until process exit so shutdown can flush before handover.
    return true
}

HasArgument(expected) {
    for arg in A_Args {
        if (arg = expected)
            return true
    }
    return false
}

ArgumentText(prefix) {
    for arg in A_Args {
        if (SubStr(arg, 1, StrLen(prefix)) = prefix)
            return SubStr(arg, StrLen(prefix) + 1)
    }
    return ""
}

ArgumentValue(prefix, defaultValue) {
    return ParseInt(ArgumentText(prefix), defaultValue, 0, 3600)
}

RuntimeBaseDir() {
    if A_IsCompiled
        return A_ScriptDir
    SplitPath(A_ScriptDir, &sourceFolder, &parentFolder)
    if (StrLower(sourceFolder) = "src")
        return parentFolder
    return A_ScriptDir
}

GlobalErrorHandler(thrown, mode) {
    message := "Unhandled error: " thrown.Message "`n"
        . "What: " thrown.What "`n"
        . "File: " thrown.File "`n"
        . "Line: " thrown.Line "`n"
        . "Mode: " mode "`n"
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message, RuntimeBaseDir() "\" AppInfo.ErrorLogFile, "UTF-8")
    try FileAppend(message, "**", "UTF-8")
    if HasArgument("--self-test") || HasArgument("--observe-only")
        ExitApp(1)
    return 1
}
