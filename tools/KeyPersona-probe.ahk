#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\lib\AppInfo.ahk
#Include ..\lib\Utils.ahk
#Include ..\lib\Config.ahk
#Include ..\lib\WindowIdentity.ahk
#Include ..\lib\InputProfiles.ahk
#Include ..\lib\ImeMode.ahk

baseDir := RegExReplace(A_ScriptDir, "\\tools$")
probeConfig := KeyPersonaConfig(baseDir)
probeLogger := Logger(probeConfig.LogPath, "off")
identityApi := WindowIdentity(probeConfig, probeLogger)
profileApi := InputProfiles(identityApi, probeConfig, probeLogger)
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
    output .= "path=" currentWindow["path"] "`n"
    output .= "class=" currentWindow["class"] "`n"
    output .= "title=" currentWindow["title"] "`n"
    output .= "identityMode=" currentWindow["mode"] "`n"
    output .= "identityKey=" currentWindow["identityKey"] "`n"
    currentProfile := profileApi.Read(currentWindow)
    currentMode := ImeMode(identityApi, probeConfig, probeLogger).Read(currentWindow, MapGet(currentProfile, "kind", "unknown"))
    output .= "profile=" currentProfile["profile"] "`n"
    output .= "hkl=" currentProfile["hkl"] "`n"
    output .= "imeOpen=" currentMode["imeOpen"] "`n"
    output .= "conversion=" currentMode["conversion"] "`n"
    output .= "sentence=" currentMode["sentence"] "`n"
} else {
    output .= "No recordable foreground window.`n"
}
reportPath := A_ScriptDir "\KeyPersona-probe.txt"
try FileDelete(reportPath)
FileAppend(output, reportPath, "UTF-8")
ExitApp
