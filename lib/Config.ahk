#Requires AutoHotkey v2.0

class KeyPersonaConfig {
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
        this.MigratePunctuationSettings()
        this.Enabled := ParseBool(this.Doc.Get("general", "enabled", "1"), true)
        this.AutoMemory := ParseBool(this.Doc.Get("general", "autoMemory", "1"), true)
        this.DefaultState := this.Doc.Get("general", "defaultState", "wetype-chinese")
        this.ForegroundSettleMs := ParseInt(this.Doc.Get("general", "foregroundSettleMs", "80"), 80, 20, 500)
        this.ActivePollMs := ParseInt(this.Doc.Get("general", "activePollMs", "250"), 250, 100, 2000)
        this.IdlePollMs := ParseInt(this.Doc.Get("general", "idlePollMs", "1000"), 1000, 250, 10000)
        this.ForcePollMs := ParseInt(this.Doc.Get("general", "forcePollMs", "100"), 100, 80, 1000)
        this.BurstDurationMs := ParseInt(this.Doc.Get("general", "burstDurationMs", "2000"), 2000, 250, 10000)
        this.ApplySuppressMs := ParseInt(this.Doc.Get("general", "applySuppressMs", "1000"), 1000, 300, 5000)
        this.SaveDebounceMs := ParseInt(this.Doc.Get("general", "saveDebounceMs", "2000"), 2000, 100, 30000)
        this.MessageTimeoutMs := ParseInt(this.Doc.Get("general", "messageTimeoutMs", "120"), 120, 20, 1000)
        this.LogLevel := this.Doc.Get("general", "logLevel", "info")
        this.WindowModeExe := SplitCsv(this.Doc.Get("identity", "windowModeExe", "msedge.exe,chrome.exe,firefox.exe,explorer.exe,zettlr.exe"))
        this.IgnoreExe := SplitCsv(this.Doc.Get("identity", "ignoreExe", "autohotkey64.exe,autohotkey32.exe,textinputhost.exe,searchhost.exe,startmenuexperiencehost.exe"))
        this.IgnoreClassRegex := this.Doc.Get("identity", "ignoreClassRegex", "i)^(Progman|WorkerW|Shell_(Secondary)?TrayWnd|TopLevelWindowForOverflowXamlIsland|NotifyIconOverflowWindow|XamlExplorerHostIslandWindow|tooltips_class32|IME)$")
        this.PunctuationEnabled := ParseBool(this.Doc.Get("punctuation", "enabled", "0"))
        this.PunctuationConvert := Map()
        this.PunctuationPairs := Map()
        for rule in PunctuationCatalog.Rules {
            id := rule["id"]
            this.PunctuationConvert[id] := ParseBool(this.Doc.Get("punctuation", "convert." id, "0"))
            if (rule["close"] != "")
                this.PunctuationPairs[id] := ParseBool(this.Doc.Get("punctuation", "pair." id, "0"))
        }
        this.PunctuationApps := this.LoadPunctuationApps()
        this.AppInputPolicies := this.LoadAppInputPolicies()
        this.PunctuationRevision := this.HasOwnProp("PunctuationRevision") ? this.PunctuationRevision + 1 : 1
        this.NamedStates := this.LoadNamedStates()
        this.RuleSections := this.LoadPrefixedSections("rule.")
        this.WindowRules := this.LoadWindowRules()
    }

    MigratePunctuationSettings() {
        if (!this.Doc.Sections.Has("typing") || !this.Doc.Sections["typing"].Has("backtickInChinese"))
            return
        oldValue := ParseBool(this.Doc.Sections["typing"]["backtickInChinese"]) ? "1" : "0"
        newValues := MapGet(this.Doc.Sections, "punctuation", Map())
        if !newValues.Has("enabled")
            IniWrite(oldValue, this.Path, "punctuation", "enabled")
        if !newValues.Has("convert.backtick")
            IniWrite(oldValue, this.Path, "punctuation", "convert.backtick")
        IniDelete(this.Path, "typing", "backtickInChinese")
        if (this.Doc.Sections["typing"].Count = 1)
            IniDelete(this.Path, "typing")
        this.Doc := IniDocument.Load(this.Path)
    }

    LoadNamedStates() {
        states := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^state\.(.+)$", &match)
                continue
            state := Map(
                "name", match[1],
                "description", MapGet(values, "description", ""),
                "generated", ParseBool(MapGet(values, "generated", "0"), false),
                "profile", MapGet(values, "profile", "unknown"),
                "imeOpen", MapGet(values, "imeOpen", "unknown"),
                "conversion", MapGet(values, "conversion", "preserve"),
                "sentence", MapGet(values, "sentence", "preserve")
            )
            states[match[1]] := state
        }
        return states
    }

    ReconcileDiscoveredStates(catalog, authoritative := true) {
        result := Map(
            "added", 0,
            "removedStates", 0,
            "removedRules", 0,
            "repointedRules", 0,
            "defaultChanged", false,
            "authoritative", false,
            "validProfiles", Map()
        )
        if !IsObject(catalog) || catalog.Count = 0
            return result
        result["added"] := this.AddDiscoveredStates(catalog)
        if !authoritative
            return result
        for catalogKey, profile in catalog
            result["validProfiles"][StrLower(MapGet(profile, "id", catalogKey))] := true
        result["authoritative"] := true

        cleanup := this.CleanupDiscoveredStates(result["validProfiles"])
        for field in ["removedStates", "removedRules", "repointedRules"]
            result[field] := cleanup[field]

        if (!this.NamedStates.Has(this.DefaultState)
            || !result["validProfiles"].Has(StrLower(MapGet(this.GetNamedState(this.DefaultState), "profile", "")))) {
            fallback := this.FindValidDefaultState(catalog)
            if (fallback != "" && fallback != this.DefaultState) {
                IniWrite(fallback, this.Path, "general", "defaultState")
                this.Reload()
                result["defaultChanged"] := true
            }
        }
        return result
    }

    AddDiscoveredStates(catalog) {
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
            if ImeMode.HasModePresets(profile) {
                ; Keep the existing Chinese state names for rules and saved defaults.
                chinese := (profile["langId"] & 0x03FF) = 0x04
                added += this.EnsureDiscoveredState(profile, "1", chinese ? "chinese" : "ime-on", existing)
                added += this.EnsureDiscoveredState(profile, "0", chinese ? "english" : "ime-off", existing)
            }
            added += this.EnsureDiscoveredState(profile, "unknown", "", existing)
        }
        if added
            this.Reload()
        return added
    }

    CleanupDiscoveredStates(validProfiles) {
        invalid := Map()
        canonicalByKey := Map()
        duplicates := Map()
        for generatedPass in [false, true] {
            for stateName, state in this.NamedStates {
                profileId := StrLower(MapGet(state, "profile", ""))
                if !validProfiles.Has(profileId) {
                    invalid[stateName] := true
                    continue
                }
                if (MapGet(state, "generated", false) != generatedPass)
                    continue
                key := this.DiscoveredStateKey(profileId, MapGet(state, "imeOpen", "unknown"))
                if canonicalByKey.Has(key)
                    duplicates[stateName] := canonicalByKey[key]
                else
                    canonicalByKey[key] := stateName
            }
        }

        removedRules := 0
        repointedRules := 0
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^(rule\.|window-rule\.)")
                continue
            stateName := MapGet(values, "state", "")
            if invalid.Has(stateName) {
                IniDelete(this.Path, section)
                removedRules += 1
            } else if duplicates.Has(stateName) {
                IniWrite(duplicates[stateName], this.Path, section, "state")
                repointedRules += 1
            }
        }

        if duplicates.Has(this.DefaultState) {
            IniWrite(duplicates[this.DefaultState], this.Path, "general", "defaultState")
            this.DefaultState := duplicates[this.DefaultState]
        }

        removedStates := 0
        for stateName in invalid {
            IniDelete(this.Path, "state." stateName)
            removedStates += 1
        }
        for stateName in duplicates {
            IniDelete(this.Path, "state." stateName)
            removedStates += 1
        }
        if (removedRules || repointedRules || removedStates)
            this.Reload()
        return Map(
            "removedStates", removedStates,
            "removedRules", removedRules,
            "repointedRules", repointedRules
        )
    }

    FindValidDefaultState(catalog) {
        chineseState := ""
        englishState := ""
        firstState := ""
        for stateName, state in this.NamedStates {
            profileId := StrLower(MapGet(state, "profile", ""))
            if !catalog.Has(profileId)
                continue
            if (firstState = "")
                firstState := stateName
            if (profileId = "0409:00000409")
                englishState := stateName
            profile := catalog[profileId]
            languageState := Map(
                "profile", MapGet(profile, "id", ""),
                "langId", Hex(MapGet(profile, "langId", 0), 4)
            )
            if (chineseState = "" && IsChineseLanguageState(languageState)
                && MapGet(state, "imeOpen", "unknown") = "1")
                chineseState := stateName
        }
        return chineseState != "" ? chineseState : englishState != "" ? englishState : firstState
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
        IniWrite("1", this.Path, section, "generated")
        IniWrite(profileId, this.Path, section, "profile")
        IniWrite(imeOpen, this.Path, section, "imeOpen")
        IniWrite("preserve", this.Path, section, "conversion")
        IniWrite("preserve", this.Path, section, "sentence")
        existing[key] := true
        return 1
    }

    DiscoveredStateKey(profileId, imeOpen) {
        normalizedOpen := StrLower(Trim(imeOpen ""))
        if (normalizedOpen != "0" && normalizedOpen != "1")
            normalizedOpen := "preserve"
        return StrLower(Trim(profileId "")) "|" normalizedOpen
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

    SetAutoMemory(enabled) {
        value := enabled ? "1" : "0"
        IniWrite(value, this.Path, "general", "autoMemory")
        this.AutoMemory := !!enabled
        return this.AutoMemory
    }

    LoadAppInputPolicies() {
        policies := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^input-app\.")
                continue
            exe := StrLower(Trim(MapGet(values, "exe", "")))
            if (exe != "")
                policies[exe] := Map("section", section,
                    "excludeMemory", !ParseBool(MapGet(values, "autoMemory", "1"), true),
                    "force", ParseBool(MapGet(values, "force", "0")))
        }
        return policies
    }

    IsAppMemoryExcluded(exe) {
        exe := StrLower(exe)
        return this.AppInputPolicies.Has(exe) && this.AppInputPolicies[exe]["excludeMemory"]
    }

    IsAppInputForced(exe) {
        exe := StrLower(exe)
        return this.AppInputPolicies.Has(exe) && this.AppInputPolicies[exe]["force"]
    }

    SetAppInputOption(exe, option, enabled) {
        exe := StrLower(Trim(exe))
        if (exe = "" || (option != "excludeMemory" && option != "force"))
            return false
        key := option = "excludeMemory" ? "autoMemory" : "force"
        policy := MapGet(this.AppInputPolicies, exe, Map())
        section := MapGet(policy, "section", "input-app." Fnv1a32(exe))
        if enabled {
            if !policy.Count
                IniWrite(exe, this.Path, section, "exe")
            IniWrite(key = "autoMemory" ? "0" : "1", this.Path, section, key)
        } else if policy.Count {
            values := this.Doc.Sections[section]
            if (values.Count = 2 && values.Has(key))
                IniDelete(this.Path, section)
            else
                IniDelete(this.Path, section, key)
        }
        this.Doc := IniDocument.Load(this.Path)
        this.AppInputPolicies := this.LoadAppInputPolicies()
        return true
    }

    SetPunctuationEnabled(enabled) {
        IniWrite(enabled ? "1" : "0", this.Path, "punctuation", "enabled")
        this.PunctuationEnabled := !!enabled
        this.PunctuationRevision += 1
    }

    SetPunctuationOption(id, pair, enabled) {
        rule := PunctuationCatalog.Find(id)
        if !rule.Count || (pair && rule["close"] = "")
            return false
        IniWrite(enabled ? "1" : "0", this.Path, "punctuation", (pair ? "pair." : "convert.") id)
        options := pair ? this.PunctuationPairs : this.PunctuationConvert
        options[id] := !!enabled
        this.PunctuationRevision += 1
        return true
    }

    LoadPunctuationApps() {
        apps := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^punctuation-app\.")
                continue
            exe := StrLower(Trim(MapGet(values, "exe", "")))
            if (exe = "")
                continue
            conversion := Map()
            pairs := Map()
            enabled := MapGet(values, "enabled", "inherit")
            if (enabled != "0" && enabled != "1")
                enabled := "inherit"
            else
                enabled := enabled = "1"
            for rule in PunctuationCatalog.Rules {
                convertValue := MapGet(values, "convert." rule["id"], "inherit")
                if (convertValue = "0" || convertValue = "1")
                    conversion[rule["id"]] := convertValue = "1"
                value := MapGet(values, "pair." rule["id"], "inherit")
                if (rule["close"] != "" && (value = "0" || value = "1"))
                    pairs[rule["id"]] := value = "1"
            }
            apps[exe] := Map("section", section, "enabled", enabled, "convert", conversion, "pairs", pairs)
        }
        return apps
    }

    GetAppPunctuationOption(exe, id := "", pair := false) {
        exe := StrLower(exe)
        if !this.PunctuationApps.Has(exe)
            return "inherit"
        app := this.PunctuationApps[exe]
        if (id = "")
            return app["enabled"]
        return MapGet(app[pair ? "pairs" : "convert"], id, "inherit")
    }

    ResolvePunctuationOption(exe, id := "", pair := false) {
        override := this.GetAppPunctuationOption(exe, id, pair)
        if (override != "inherit")
            return !!override
        if (id = "")
            return this.PunctuationEnabled
        return MapGet(pair ? this.PunctuationPairs : this.PunctuationConvert, id, false)
    }

    ShouldConvertPunctuation(exe, id) {
        return this.ResolvePunctuationOption(exe) && this.ResolvePunctuationOption(exe, id)
    }

    ShouldPairPunctuation(exe, id) {
        return this.ResolvePunctuationOption(exe, id, true)
    }

    SetAppPunctuationOption(exe, id, pair, mode) {
        exe := StrLower(Trim(exe))
        rule := PunctuationCatalog.Find(id)
        if (exe = "" || (id != "" && (!rule.Count || (pair && rule["close"] = "")))
            || (id = "" && pair)
            || (mode != "inherit" && mode != "0" && mode != "1"))
            return false
        section := this.PunctuationApps.Has(exe) ? this.PunctuationApps[exe]["section"]
            : "punctuation-app." Fnv1a32(exe)
        key := id = "" ? "enabled" : (pair ? "pair." : "convert.") id
        if (mode = "inherit") {
            if this.PunctuationApps.Has(exe)
                IniDelete(this.Path, section, key)
        } else {
            IniWrite(exe, this.Path, section, "exe")
            IniWrite(mode, this.Path, section, key)
        }
        this.Reload()
        if this.PunctuationApps.Has(exe) {
            app := this.PunctuationApps[exe]
            if (app["enabled"] = "inherit" && !app["convert"].Count && !app["pairs"].Count) {
                IniDelete(this.Path, section)
                this.Reload()
            }
        }
        return true
    }

    ClearAppPunctuationOptions(exe) {
        exe := StrLower(exe)
        if !this.PunctuationApps.Has(exe)
            return
        IniDelete(this.Path, this.PunctuationApps[exe]["section"])
        this.Reload()
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
            . "; profile 可从托盘状态或 tools\KeyPersona-probe.ahk 的输出中复制。`n`n"
            . "[general]`n"
            . "enabled=1`n"
            . "autoMemory=1`n"
            . "defaultState=wetype-chinese`n"
            . "foregroundSettleMs=80`n"
            . "activePollMs=250`n"
            . "idlePollMs=1000`n"
            . "forcePollMs=100`n"
            . "burstDurationMs=2000`n"
            . "applySuppressMs=1000`n"
            . "saveDebounceMs=2000`n"
            . "messageTimeoutMs=120`n"
            . "logLevel=info`n`n"
            . "[identity]`n"
            . "windowModeExe=msedge.exe,chrome.exe,firefox.exe,explorer.exe,zettlr.exe`n"
            . "ignoreExe=autohotkey64.exe,autohotkey32.exe,textinputhost.exe,searchhost.exe,startmenuexperiencehost.exe`n"
            . "ignoreClassRegex=i)^(Progman|WorkerW|Shell_(Secondary)?TrayWnd|TopLevelWindowForOverflowXamlIsland|NotifyIconOverflowWindow|XamlExplorerHostIslandWindow|tooltips_class32|IME)$`n`n"
            . "[punctuation]`n"
            . "enabled=0`n"
            . "; convert.<名称>=1 启用转换，pair.<名称>=1 自动补齐。所有选项默认关闭。`n`n"
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
            . "; 用户规则仅在窗口没有自动记忆时作为默认值，不会锁定输入法。`n"
            . "[rule.windows-terminal]`n"
            . "enabled=1`npriority=100`nexe=WindowsTerminal.exe`nstate=english-us`n`n"
            . "[rule.classic-powershell]`n"
            . "enabled=1`npriority=100`nexe=powershell.exe`nstate=english-us`n`n"
            . "[rule.raycast]`n"
            . "enabled=1`npriority=100`nexe=Raycast.exe`nstate=english-us`n"
        FileAppend(template, this.Path, "UTF-8")
    }
}
