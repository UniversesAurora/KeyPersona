#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, StdOut
Persistent
;@Ahk2Exe-SetName IME Memory
;@Ahk2Exe-SetDescription Lightweight per-window input method memory for Windows
;@Ahk2Exe-SetVersion 0.1.2
;@Ahk2Exe-SetMainIcon assets\ime-memory.ico
;@Ahk2Exe-SetCopyright Personal utility

#Include lib\Utils.ahk
#Include lib\Config.ahk
#Include lib\StateStore.ahk
#Include lib\WindowIdentity.ahk
#Include lib\Rules.ahk
#Include lib\InputProfiles.ahk
#Include lib\ImeMode.ahk
#Include lib\WinEventHook.ahk
#Include lib\TrayMenu.ahk
#Include lib\App.ahk
#Include lib\SelfTest.ahk

SetWorkingDir(A_ScriptDir)
if !A_IsCompiled && FileExist(A_ScriptDir "\assets\ime-memory.ico")
    TraySetIcon(A_ScriptDir "\assets\ime-memory.ico")
OnError(GlobalErrorHandler)

if HasArgument("--self-test") {
    ExitApp(RunSelfTests(A_ScriptDir))
}

observeOnly := HasArgument("--observe-only")
smokeSeconds := ArgumentValue("--smoke-seconds=", 0)
global IME_MEMORY_APP := ImeMemoryApp(A_ScriptDir, observeOnly)
OnExit(ObjBindMethod(IME_MEMORY_APP, "Shutdown"))

try {
    IME_MEMORY_APP.Start()
    if (smokeSeconds > 0)
        SetTimer((*) => ExitApp(), -smokeSeconds * 1000)
} catch Error as startupError {
    IME_MEMORY_APP.Logger.Error("Fatal startup error: " startupError.Message " at " startupError.File ":" startupError.Line)
    FileAppend("IME Memory startup failed: " startupError.Message "`n", "**", "UTF-8")
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

GlobalErrorHandler(thrown, mode) {
    message := "Unhandled error: " thrown.Message "`n"
        . "What: " thrown.What "`n"
        . "File: " thrown.File "`n"
        . "Line: " thrown.Line "`n"
        . "Mode: " mode "`n"
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message, A_ScriptDir "\fatal-error.log", "UTF-8")
    try FileAppend(message, "**", "UTF-8")
    ExitApp(1)
    return true
}
