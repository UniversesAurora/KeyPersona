#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, StdOut
Persistent

#Include lib\AppInfo.ahk
#Include lib\LegacyMigration.ahk
#Include lib\Utils.ahk
#Include lib\Config.ahk
#Include lib\StartupManager.ahk
#Include lib\AboutDialog.ahk
#Include lib\StateStore.ahk
#Include lib\WindowIdentity.ahk
#Include lib\Rules.ahk
#Include lib\InputProfiles.ahk
#Include lib\ImeMode.ahk
#Include lib\BacktickKey.ahk
#Include lib\WinEventHook.ahk
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
smokeSeconds := ArgumentValue("--smoke-seconds=", 0)
appBaseDir := RuntimeBaseDir()
global KEYPERSONA_APP := KeyPersonaApp(appBaseDir, observeOnly)
OnExit(ObjBindMethod(KEYPERSONA_APP, "Shutdown"))

try {
    KEYPERSONA_APP.Start()
    if (smokeSeconds > 0)
        SetTimer((*) => ExitApp(), -smokeSeconds * 1000)
} catch Error as startupError {
    KEYPERSONA_APP.Logger.Error("Fatal startup error: " startupError.Message " at " startupError.File ":" startupError.Line)
    FileAppend(AppInfo.Name " startup failed: " startupError.Message "`n", "**", "UTF-8")
    ExitApp(1)
}

HasArgument(expected) {
    for arg in A_Args {
        if (arg = expected)
            return true
    }
    return false
}

ArgumentValue(prefix, defaultValue) {
    for arg in A_Args {
        if (SubStr(arg, 1, StrLen(prefix)) = prefix)
            return ParseInt(SubStr(arg, StrLen(prefix) + 1), defaultValue, 0, 3600)
    }
    return defaultValue
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
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message, A_ScriptDir "\" AppInfo.ErrorLogFile, "UTF-8")
    try FileAppend(message, "**", "UTF-8")
    ExitApp(1)
    return true
}
