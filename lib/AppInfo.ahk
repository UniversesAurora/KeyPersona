#Requires AutoHotkey v2.0

; Product identity and artifact names live here so renaming stays localized.
;@Ahk2Exe-SetName KeyPersona
;@Ahk2Exe-SetDescription KeyPersona
;@Ahk2Exe-SetVersion 1.4.1
;@Ahk2Exe-SetMainIcon %A_ScriptDir%\assets\KeyPersona.ico
;@Ahk2Exe-AddResource %A_ScriptDir%\assets\GitHub-Invertocat.ico, 1001
;@Ahk2Exe-SetCopyright Copyright (c) 2026 浮枕

class AppInfo {
    static Name := "KeyPersona"
    static Slug := "keypersona"
    static SourceFile := "KeyPersona.ahk"
    static ExecutableFile := "KeyPersona.exe"
    static ConfigFile := "config.ini"
    static StateFile := "state.ini"
    static LogFile := "KeyPersona.log"
    static ErrorLogFile := "KeyPersona-error.log"
    static IconFile := "assets\KeyPersona.ico"
    static StartupShortcutName := "KeyPersona.lnk"
    static StartupValueName := "KeyPersona"
    static Description := "按窗口记忆并自动恢复输入法状态"
    static RepositoryUrl := "https://github.com/UniversesAurora/KeyPersona"
    ; GitHub Invertocat from https://brand.github.com/foundations/logo
    static RepositoryIconFile := "assets\GitHub-Invertocat.ico"
    static RepositoryIconId := 1001
    static Author := "浮枕"
    static AuthorHandle := "@universesaurora"
    static AuthorUrl := "https://github.com/UniversesAurora"
    static Version := "1.4.1"

    ; Retained only so existing installations migrate without losing settings.
    static LegacyLogFiles := ["ime-memory.log"]
    static LegacyStartupShortcutNames := ["IME Memory.lnk"]
    static LegacyStartupValueNames := ["IME Memory"]
}
