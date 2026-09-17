#Requires AutoHotkey v2.0

; Product identity and artifact names live here so renaming stays localized.
;@Ahk2Exe-SetName IME Memory
;@Ahk2Exe-SetDescription IME Memory
;@Ahk2Exe-SetVersion 0.1.2
;@Ahk2Exe-SetMainIcon %A_ScriptDir%\assets\ime-memory.ico
;@Ahk2Exe-SetCopyright Personal utility

class AppInfo {
    static Name := "IME Memory"
    static Slug := "ime-memory"
    static SourceFile := "ime-memory.ahk"
    static ExecutableFile := "ime-memory.exe"
    static ConfigFile := "config.ini"
    static StateFile := "state.ini"
    static LogFile := "ime-memory.log"
    static IconFile := "assets\ime-memory.ico"
    static StartupShortcutName := "IME Memory.lnk"
    static LegacyStartupValueName := "IME Memory"
    static Description := "按窗口记忆并自动恢复输入法状态"
    static Author := "浮枕"
    static AuthorHandle := "@universesaurora"
    static Version := "0.1.2"
}
