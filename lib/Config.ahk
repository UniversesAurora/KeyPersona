#Requires AutoHotkey v2.0

class ImeMemoryConfig {
    __New(baseDir) {
        this.BaseDir := baseDir
        this.Path := baseDir "\config.ini"
        this.StatePath := baseDir "\state.ini"
        this.LogPath := baseDir "\ime-memory.log"
        this.EnsureDefaultFile()
        this.Reload()
    }

    Reload() {
        this.Doc := IniDocument.Load(this.Path)
        this.Enabled := ParseBool(this.Doc.Get("general", "enabled", "1"), true)
        this.DefaultState := this.Doc.Get("general", "defaultState", "wetype-chinese")
        this.ActivePollMs := ParseInt(this.Doc.Get("general", "activePollMs", "250"), 250, 100, 2000)
        this.IdlePollMs := ParseInt(this.Doc.Get("general", "idlePollMs", "1000"), 1000, 250, 10000)
        this.BurstDurationMs := ParseInt(this.Doc.Get("general", "burstDurationMs", "2000"), 2000, 250, 10000)
        this.ApplySuppressMs := ParseInt(this.Doc.Get("general", "applySuppressMs", "1000"), 1000, 300, 5000)
        this.SaveDebounceMs := ParseInt(this.Doc.Get("general", "saveDebounceMs", "2000"), 2000, 100, 30000)
        this.MessageTimeoutMs := ParseInt(this.Doc.Get("general", "messageTimeoutMs", "120"), 120, 20, 1000)
        this.LogLevel := this.Doc.Get("general", "logLevel", "info")
        this.WindowModeExe := SplitCsv(this.Doc.Get("identity", "windowModeExe", "msedge.exe,chrome.exe,firefox.exe,explorer.exe,zettlr.exe"))
        this.IgnoreExe := SplitCsv(this.Doc.Get("identity", "ignoreExe", "ime-memory.exe,autohotkey64.exe,autohotkey32.exe,textinputhost.exe,searchhost.exe,startmenuexperiencehost.exe"))
        this.IgnoreClassRegex := this.Doc.Get("identity", "ignoreClassRegex", "i)^(Progman|WorkerW|Shell_TrayWnd|XamlExplorerHostIslandWindow|tooltips_class32|IME)$")
        this.NamedStates := this.LoadNamedStates()
        this.RuleSections := this.LoadPrefixedSections("rule.")
    }

    LoadNamedStates() {
        states := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^state\.(.+)$", &match)
                continue
            state := Map(
                "name", match[1],
                "profile", MapGet(values, "profile", "unknown"),
                "imeOpen", MapGet(values, "imeOpen", "unknown"),
                "conversion", MapGet(values, "conversion", "preserve"),
                "sentence", MapGet(values, "sentence", "preserve")
            )
            states[match[1]] := state
        }
        return states
    }

    LoadPrefixedSections(prefix) {
        result := []
        for section, values in this.Doc.Sections {
            if (SubStr(StrLower(section), 1, StrLen(prefix)) != StrLower(prefix))
                continue
            item := Map("name", SubStr(section, StrLen(prefix) + 1))
            for key, value in values
                item[key] := value
            result.Push(item)
        }
        return result
    }

    GetNamedState(name) {
        return this.NamedStates.Has(name) ? StateClone(this.NamedStates[name]) : Map()
    }

    SetDefaultState(name) {
        if !this.NamedStates.Has(name)
            return false
        IniWrite(name, this.Path, "general", "defaultState")
        this.DefaultState := name
        return true
    }

    EnsureDefaultFile() {
        if FileExist(this.Path)
            return
        template := "; IME Memory 用户配置。修改后从托盘选择 Reload。`n"
            . "; profile 可从托盘状态或 tools\ime-probe.ahk 的输出中复制。`n`n"
            . "[general]`n"
            . "enabled=1`n"
            . "defaultState=wetype-chinese`n"
            . "activePollMs=250`n"
            . "idlePollMs=1000`n"
            . "burstDurationMs=2000`n"
            . "applySuppressMs=1000`n"
            . "saveDebounceMs=2000`n"
            . "messageTimeoutMs=120`n"
            . "logLevel=info`n`n"
            . "[identity]`n"
            . "windowModeExe=msedge.exe,chrome.exe,firefox.exe,explorer.exe,zettlr.exe`n"
            . "ignoreExe=ime-memory.exe,autohotkey64.exe,autohotkey32.exe,textinputhost.exe,searchhost.exe,startmenuexperiencehost.exe`n"
            . "ignoreClassRegex=i)^(Progman|WorkerW|Shell_TrayWnd|XamlExplorerHostIslandWindow|tooltips_class32|IME)$`n`n"
            . "[state.english-us]`n"
            . "profile=0409:00000409`n"
            . "imeOpen=unknown`n"
            . "conversion=preserve`n"
            . "sentence=preserve`n`n"
            . "[state.wetype-chinese]`n"
            . "profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}`n"
            . "imeOpen=1`n"
            . "conversion=preserve`n"
            . "sentence=preserve`n`n"
            . "[state.wetype-english]`n"
            . "profile=0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}`n"
            . "imeOpen=0`n"
            . "conversion=preserve`n"
            . "sentence=preserve`n`n"
            . "[rule.windows-terminal]`n"
            . "enabled=1`npriority=100`nexe=WindowsTerminal.exe`nstate=english-us`n`n"
            . "[rule.classic-powershell]`n"
            . "enabled=1`npriority=100`nexe=powershell.exe`nstate=english-us`n`n"
            . "[rule.raycast]`n"
            . "enabled=1`npriority=100`nexe=Raycast.exe`nstate=english-us`n"
        FileAppend(template, this.Path, "UTF-8")
    }
}
