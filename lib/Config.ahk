#Requires AutoHotkey v2.0

class ImeMemoryConfig {
    __New(baseDir) {
        this.BaseDir := baseDir
        this.Path := baseDir "\" AppInfo.ConfigFile
        this.StatePath := baseDir "\" AppInfo.StateFile
        this.LogPath := baseDir "\" AppInfo.LogFile
        this.EnsureDefaultFile()
        this.Reload()
    }

    Reload() {
        this.Doc := IniDocument.Load(this.Path)
        this.Enabled := ParseBool(this.Doc.Get("general", "enabled", "1"), true)
        this.DefaultState := this.Doc.Get("general", "defaultState", "wetype-chinese")
        this.ForegroundSettleMs := ParseInt(this.Doc.Get("general", "foregroundSettleMs", "80"), 80, 20, 500)
        this.ActivePollMs := ParseInt(this.Doc.Get("general", "activePollMs", "250"), 250, 100, 2000)
        this.IdlePollMs := ParseInt(this.Doc.Get("general", "idlePollMs", "1000"), 1000, 250, 10000)
        this.BurstDurationMs := ParseInt(this.Doc.Get("general", "burstDurationMs", "2000"), 2000, 250, 10000)
        this.ApplySuppressMs := ParseInt(this.Doc.Get("general", "applySuppressMs", "1000"), 1000, 300, 5000)
        this.SaveDebounceMs := ParseInt(this.Doc.Get("general", "saveDebounceMs", "2000"), 2000, 100, 30000)
        this.MessageTimeoutMs := ParseInt(this.Doc.Get("general", "messageTimeoutMs", "120"), 120, 20, 1000)
        this.LogLevel := this.Doc.Get("general", "logLevel", "info")
        this.WindowModeExe := SplitCsv(this.Doc.Get("identity", "windowModeExe", "msedge.exe,chrome.exe,firefox.exe,explorer.exe,zettlr.exe"))
        this.IgnoreExe := SplitCsv(this.Doc.Get("identity", "ignoreExe", "autohotkey64.exe,autohotkey32.exe,textinputhost.exe,searchhost.exe,startmenuexperiencehost.exe"))
        this.IgnoreClassRegex := this.Doc.Get("identity", "ignoreClassRegex", "i)^(Progman|WorkerW|Shell_(Secondary)?TrayWnd|TopLevelWindowForOverflowXamlIsland|NotifyIconOverflowWindow|XamlExplorerHostIslandWindow|tooltips_class32|IME)$")
        this.BacktickInChinese := ParseBool(this.Doc.Get("typing", "backtickInChinese", "0"), false)
        this.NamedStates := this.LoadNamedStates()
        this.RuleSections := this.LoadPrefixedSections("rule.")
        this.WindowRules := this.LoadWindowRules()
    }

    LoadNamedStates() {
        states := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^state\.(.+)$", &match)
                continue
            state := Map(
                "name", match[1],
                "description", MapGet(values, "description", ""),
                "profile", MapGet(values, "profile", "unknown"),
                "imeOpen", MapGet(values, "imeOpen", "unknown"),
                "conversion", MapGet(values, "conversion", "preserve"),
                "sentence", MapGet(values, "sentence", "preserve")
            )
            states[match[1]] := state
        }
        return states
    }

    EnsureDiscoveredStates(catalog) {
        if !IsObject(catalog)
            return 0
        existing := Map()
        for stateName, state in this.NamedStates {
            key := this.DiscoveredStateKey(
                MapGet(state, "profile", "unknown"),
                MapGet(state, "imeOpen", "unknown")
            )
            existing[key] := true
        }
        added := 0
        for catalogKey, profile in catalog {
            profileId := MapGet(profile, "id", "")
            if (profileId = "")
                continue
            languageState := Map(
                "profile", profileId,
                "langId", Hex(MapGet(profile, "langId", 0), 4)
            )
            if (MapGet(profile, "kind", "") = "tip" && IsChineseLanguageState(languageState)) {
                added += this.EnsureDiscoveredState(profile, "1", "chinese", existing)
                added += this.EnsureDiscoveredState(profile, "0", "english", existing)
            } else {
                added += this.EnsureDiscoveredState(profile, "unknown", "", existing)
            }
        }
        if added
            this.Reload()
        return added
    }

    EnsureDiscoveredState(profile, imeOpen, suffix, existing) {
        profileId := MapGet(profile, "id", "")
        key := this.DiscoveredStateKey(profileId, imeOpen)
        if existing.Has(key)
            return 0
        stateName := "auto-" StrLower(Fnv1a32(StrLower(profileId)))
        if (suffix != "")
            stateName .= "-" suffix
        section := "state." stateName
        description := StrReplace(MapGet(profile, "description", profileId), "`n", " ")
        description := StrReplace(description, "`r", " ")
        IniWrite(description, this.Path, section, "description")
        IniWrite(profileId, this.Path, section, "profile")
        IniWrite(imeOpen, this.Path, section, "imeOpen")
        IniWrite("preserve", this.Path, section, "conversion")
        IniWrite("preserve", this.Path, section, "sentence")
        existing[key] := true
        return 1
    }

    DiscoveredStateKey(profileId, imeOpen) {
        return StrLower(Trim(profileId "")) "|" StrLower(Trim(imeOpen ""))
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

    LoadWindowRules() {
        rules := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^window-rule\.(.+)$", &match)
                continue
            identityKey := IniUnescape(MapGet(values, "identityKey", ""))
            stateName := MapGet(values, "state", "")
            if (identityKey = "" || !this.NamedStates.Has(stateName))
                continue
            rules[identityKey] := Map(
                "name", match[1],
                "section", section,
                "identityKey", identityKey,
                "stateName", stateName
            )
        }
        return rules
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

    SetBacktickInChinese(enabled) {
        value := enabled ? "1" : "0"
        IniWrite(value, this.Path, "typing", "backtickInChinese")
        this.BacktickInChinese := !!enabled
        return this.BacktickInChinese
    }

    GetWindowRule(windowInfo) {
        identityKey := MapGet(windowInfo, "identityKey", "")
        if (identityKey = "" || !this.WindowRules.Has(identityKey))
            return Map()
        stored := this.WindowRules[identityKey]
        stateName := stored["stateName"]
        state := this.GetNamedState(stateName)
        if !state.Count
            return Map()
        return Map(
            "name", stored["name"],
            "scope", "window",
            "stateName", stateName,
            "state", state
        )
    }

    SetWindowRule(windowInfo, stateName) {
        identityKey := MapGet(windowInfo, "identityKey", "")
        if (identityKey = "" || !this.NamedStates.Has(stateName))
            return false
        section := "window-rule." Fnv1a32(identityKey)
        IniWrite(IniEscape(identityKey), this.Path, section, "identityKey")
        IniWrite(stateName, this.Path, section, "state")
        IniWrite(MapGet(windowInfo, "exe", ""), this.Path, section, "exe")
        IniWrite(MapGet(windowInfo, "mode", "app"), this.Path, section, "mode")
        this.Reload()
        return this.WindowRules.Has(identityKey)
    }

    RemoveWindowRule(windowInfo) {
        identityKey := MapGet(windowInfo, "identityKey", "")
        if (identityKey = "" || !this.WindowRules.Has(identityKey))
            return false
        section := this.WindowRules[identityKey]["section"]
        IniDelete(this.Path, section)
        this.Reload()
        return !this.WindowRules.Has(identityKey)
    }

    RemoveApplicationRule(name) {
        wanted := StrLower("rule." name)
        sectionName := ""
        for section in this.Doc.Sections {
            if (StrLower(section) = wanted) {
                sectionName := section
                break
            }
        }
        if (sectionName = "")
            return false
        IniDelete(this.Path, sectionName)
        this.Reload()
        return true
    }

    EnsureDefaultFile() {
        if FileExist(this.Path)
            return
        template := "; " AppInfo.Name " 用户配置。修改后从托盘选择“重新加载”。`n"
            . "; profile 可从托盘状态或 tools\ime-probe.ahk 的输出中复制。`n`n"
            . "[general]`n"
            . "enabled=1`n"
            . "defaultState=wetype-chinese`n"
            . "foregroundSettleMs=80`n"
            . "activePollMs=250`n"
            . "idlePollMs=1000`n"
            . "burstDurationMs=2000`n"
            . "applySuppressMs=1000`n"
            . "saveDebounceMs=2000`n"
            . "messageTimeoutMs=120`n"
            . "logLevel=info`n`n"
            . "[identity]`n"
            . "windowModeExe=msedge.exe,chrome.exe,firefox.exe,explorer.exe,zettlr.exe`n"
            . "ignoreExe=autohotkey64.exe,autohotkey32.exe,textinputhost.exe,searchhost.exe,startmenuexperiencehost.exe`n"
            . "ignoreClassRegex=i)^(Progman|WorkerW|Shell_(Secondary)?TrayWnd|TopLevelWindowForOverflowXamlIsland|NotifyIconOverflowWindow|XamlExplorerHostIslandWindow|tooltips_class32|IME)$`n`n"
            . "[typing]`n"
            . "backtickInChinese=0`n`n"
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
