#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\lib\AppInfo.ahk
#Include ..\lib\Utils.ahk
#Include ..\lib\Config.ahk
#Include ..\lib\WindowIdentity.ahk
#Include ..\lib\Rules.ahk
#Include ..\lib\InputProfiles.ahk
#Include ..\lib\ImeMode.ahk
#Include ..\lib\Punctuation.ahk

reportPath := A_ScriptDir "\KeyPersona-probe.txt"
if A_Args.Length && A_Args[1] = "--class-only" {
    Sleep(2500)
    windowInfo := WindowIdentity(0).ReadWindowInfo()
    output := MapGet(windowInfo, "classSelector", "No window class is available.")
    WriteProbe(reportPath, output)
    ExitApp()
}

baseDir := RegExReplace(A_ScriptDir, "\\tools$")
probeConfig := KeyPersonaConfig(baseDir, true)
probeLogger := Logger(probeConfig.LogPath, "off")
identityApi := WindowIdentity(probeConfig, RuleEngine(probeConfig, probeLogger))
profileApi := InputProfiles(identityApi, probeLogger)
currentWindow := identityApi.Resolve()
output := AppInfo.Name " probe`nGenerated: " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n`n"
output .= "Enabled profiles:`n"
for profileId, profile in profileApi.Catalog {
    output .= "- " profile["id"] "`n"
    output .= "  name=" MapGet(profile, "description", "") "`n"
    output .= "  kind=" profile["kind"] "`n"
}
output .= "`nForeground window:`n"
if currentWindow.Count {
    output .= "exe=" currentWindow["exe"] "`n"
    output .= "packageFamily=" MapGet(currentWindow, "packageFamily", "") "`n"
    output .= "path=" currentWindow["path"] "`n"
    output .= "classSelector=" currentWindow["classSelector"] "`n"
    output .= "class=" currentWindow["class"] "`n"
    output .= "title=" currentWindow["title"] "`n"
    output .= "identityMode=" currentWindow["mode"] "`n"
    output .= "identityKey=" currentWindow["identityKey"] "`n"
    currentProfile := profileApi.Read(currentWindow)
    currentMode := ImeMode(identityApi, probeConfig).Read(currentWindow, MapGet(currentProfile, "kind", "unknown"))
    output .= "profile=" currentProfile["profile"] "`n"
    output .= "hkl=" currentProfile["hkl"] "`n"
    output .= "imeOpen=" currentMode["imeOpen"] "`n"
    output .= "conversion=" currentMode["conversion"] "`n"
    output .= "sentence=" currentMode["sentence"] "`n"
} else {
    output .= "No recordable foreground window.`n"
    windowInfo := identityApi.ReadWindowInfo()
    if MapGet(windowInfo, "classSelector", "") != ""
        output .= "classSelector=" windowInfo["classSelector"] "`n"
}
WriteProbe(reportPath, output)
ExitApp

WriteProbe(path, output) {
    report := FileOpen(path, "w", "UTF-8")
    try report.Write(output)
    finally report.Close()
}
