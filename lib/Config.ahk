#Requires AutoHotkey v2.0

class KeyPersonaConfig {
    __New(baseDir, readOnly := false) {
        this.Path := baseDir "\" AppInfo.ConfigFile
        this.StatePath := baseDir "\" AppInfo.StateFile
        this.LogPath := baseDir "\" AppInfo.LogFile
        this.ReadOnly := readOnly
        if !readOnly
            this.EnsureDefaultFile()
        this.Reload()
    }

    Reload() {
        this.Doc := IniDocument.Load(this.Path)
        if !this.ReadOnly
            this.MigratePunctuationSettings()
        this.Enabled := ParseBool(this.Doc.Get("general", "enabled", "1"), true)
        this.RunAsAdmin := ParseBool(this.Doc.Get("general", "runAsAdmin", "0"))
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
        this.LoadAppIdentities()
        this.PunctuationApps := this.LoadPunctuationApps()
        this.AppInputPolicies := this.LoadAppInputPolicies()
        this.PunctuationRevision := this.HasOwnProp("PunctuationRevision") ? this.PunctuationRevision + 1 : 1
        this.NamedStates := this.LoadNamedStates()
        this.DetailedProfiles := Map()
        for _, state in this.NamedStates {
            if ImeMode.NeedsDetailedMode(state)
                this.DetailedProfiles[StrLower(state["profile"])] := true
        }
        this.RuleSections := this.LoadPrefixedSections("rule.")
        this.WindowRules := this.LoadWindowRules()
    }

    WriteChanges(changes, expected := unset) {
        if this.ReadOnly
            throw Error("Configuration is read-only")
        return IniDocument.Update(this.Path, changes, expected?)
    }

    MigratePunctuationSettings() {
        if (!this.Doc.Sections.Has("typing") || !this.Doc.Sections["typing"].Has("backtickInChinese"))
            return
        oldValue := ParseBool(this.Doc.Sections["typing"]["backtickInChinese"]) ? "1" : "0"
        newValues := MapGet(this.Doc.Sections, "punctuation", Map())
        changes := []
        if !newValues.Has("enabled")
            changes.Push(["punctuation", "enabled", oldValue])
        if !newValues.Has("convert.backtick")
            changes.Push(["punctuation", "convert.backtick", oldValue])
        changes.Push(this.Doc.Sections["typing"].Count = 1 ? ["typing"] : ["typing", "backtickInChinese"])
        this.WriteChanges(changes)
        this.Doc := IniDocument.Load(this.Path)
    }

    LoadNamedStates() {
        states := Map()
        states.CaseSense := "Off"
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
        states := this.NamedStates.Clone()
        changes := []
        result["added"] := this.PlanDiscoveredStates(catalog, states, changes)
        if authoritative {
            valid := result["validProfiles"]
            for catalogKey, profile in catalog
                valid[StrLower(MapGet(profile, "id", catalogKey))] := true
            result["authoritative"] := true

            defaultName := this.PlanDiscoveredCleanup(states, valid, changes, result)
            if !states.Has(defaultName)
                defaultName := this.FindValidDefaultState(catalog, states)
            if defaultName != "" && defaultName != this.DefaultState {
                changes.Push(["general", "defaultState", defaultName])
                result["defaultChanged"] := true
            }
        }
        if changes.Length {
            this.WriteChanges(changes)
            this.Reload()
        }
        return result
    }

    PlanDiscoveredStates(catalog, states, changes) {
        existing := Map()
        for _, state in states {
            key := this.DiscoveredStateKey(
                MapGet(state, "profile", "unknown"),
                MapGet(state, "imeOpen", "unknown"),
                MapGet(state, "conversion", "preserve"), MapGet(state, "sentence", "preserve")
            )
            existing[key] := true
        }
        added := 0
        for _, profile in catalog {
            if MapGet(profile, "id", "") = ""
                continue
            if ImeMode.HasModePresets(profile) {
                ; Keep the existing Chinese state names for rules and saved defaults.
                chinese := (profile["langId"] & 0x03FF) = 0x04
                added += this.PlanDiscoveredState(profile, "1", chinese ? "chinese" : "ime-on", existing, changes, states)
                added += this.PlanDiscoveredState(profile, "0", chinese ? "english" : "ime-off", existing, changes, states)
            }
            added += this.PlanDiscoveredState(profile, "unknown", "", existing, changes, states)
        }
        return added
    }

    PlanDiscoveredCleanup(states, validProfiles, changes, result) {
        invalid := Map()
        invalid.CaseSense := "Off"
        canonicalByKey := Map()
        duplicates := Map()
        duplicates.CaseSense := "Off"
        for generatedPass in [false, true] {
            for stateName, state in states {
                if (MapGet(state, "generated", false) != generatedPass)
                    continue
                profileId := StrLower(MapGet(state, "profile", ""))
                if !validProfiles.Has(profileId) {
                    invalid[stateName] := true
                    continue
                }
                key := this.DiscoveredStateKey(profileId, MapGet(state, "imeOpen", "unknown"),
                    MapGet(state, "conversion", "preserve"), MapGet(state, "sentence", "preserve"))
                if canonicalByKey.Has(key)
                    duplicates[stateName] := canonicalByKey[key]
                else
                    canonicalByKey[key] := stateName
            }
        }

        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^(rule\.|window-rule\.)")
                continue
            stateName := MapGet(values, "state", "")
            if invalid.Has(stateName) {
                changes.Push([section])
                result["removedRules"] += 1
            } else if duplicates.Has(stateName) {
                changes.Push([section, "state", duplicates[stateName]])
                result["repointedRules"] += 1
            }
        }
        for obsolete in [invalid, duplicates] {
            for stateName in obsolete {
                changes.Push(["state." stateName])
                states.Delete(stateName)
                result["removedStates"] += 1
            }
        }
        return MapGet(duplicates, this.DefaultState, this.DefaultState)
    }

    FindValidDefaultState(catalog, states) {
        chineseState := ""
        englishState := ""
        firstState := ""
        for stateName, state in states {
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

    PlanDiscoveredState(profile, imeOpen, suffix, existing, changes, states) {
        profileId := MapGet(profile, "id", "")
        key := this.DiscoveredStateKey(profileId, imeOpen)
        if existing.Has(key)
            return 0
        stateName := "auto-" StrLower(Fnv1a32(StrLower(profileId)))
        if (suffix != "")
            stateName .= "-" suffix
        baseName := stateName
        while states.Has(stateName)
            stateName := baseName "-" A_Index
        description := StrReplace(MapGet(profile, "description", profileId), "`n", " ")
        description := StrReplace(description, "`r", " ")
        state := Map("description", description, "generated", 1, "profile", profileId, "imeOpen", imeOpen,
            "conversion", "preserve", "sentence", "preserve")
        section := "state." stateName
        for field, value in state
            changes.Push([section, field, value])
        states[stateName] := state
        existing[key] := true
        return 1
    }

    DiscoveredStateKey(profileId, imeOpen, conversion := "preserve", sentence := "preserve") {
        normalizedOpen := StrLower(Trim(imeOpen ""))
        if (normalizedOpen != "0" && normalizedOpen != "1")
            normalizedOpen := "preserve"
        return StrLower(Trim(profileId "")) "|" normalizedOpen "|"
            . KeyPersonaConfig.NormalizeMode(conversion) "|" KeyPersonaConfig.NormalizeMode(sentence)
    }

    static NormalizeMode(value) {
        value := StrLower(Trim(value ""))
        if IsNumber(value)
            return Integer(value) ""
        return value = "" || value = "unknown" ? "preserve" : value
    }

    LoadPrefixedSections(prefix) {
        result := []
        for section in this.Doc.SectionOrder {
            if (SubStr(StrLower(section), 1, StrLen(prefix)) != StrLower(prefix))
                continue
            item := Map("name", SubStr(section, StrLen(prefix) + 1))
            for key, value in this.Doc.Sections[section]
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
            if (identityKey = "" || (stateName != "@global" && !this.NamedStates.Has(stateName)))
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
        this.WriteChanges([["general", "defaultState", name]])
        this.DefaultState := name
        return true
    }

    SetAutoMemory(enabled) {
        value := enabled ? "1" : "0"
        this.WriteChanges([["general", "autoMemory", value]])
        this.AutoMemory := !!enabled
        return this.AutoMemory
    }

    SetAutoSwitch(enabled) {
        this.WriteChanges([["general", "enabled", enabled ? "1" : "0"]])
        this.Enabled := !!enabled
    }

    SetRunAsAdmin(enabled) {
        this.WriteChanges([["general", "runAsAdmin", enabled ? "1" : "0"]])
        this.RunAsAdmin := !!enabled
    }

    LoadAppIdentities() {
        this.AppIdentities := Map()
        this.AppIdentitiesByPath := Map()
        for section in this.Doc.SectionOrder {
            if !RegExMatch(section, "i)^app-identity\.([a-z0-9][a-z0-9_-]*)$", &match)
                continue
            path := this.Doc.Get(section, "path", "")
            pathKey := KeyPersonaConfig.AppPathKey(path)
            if pathKey = "" || this.AppIdentitiesByPath.Has(pathKey)
                continue
            id := StrLower(match[1])
            SplitPath(pathKey, &exe)
            binding := {id: id, exe: exe, section: section,
                enabled: ParseBool(this.Doc.Get(section, "enabled", "1"), true)}
            this.AppIdentities[id] := binding
            this.AppIdentitiesByPath[pathKey] := binding
        }
    }

    static AppPathKey(path) {
        path := StrReplace(Trim(path), "/", "\")
        if InStr(path, "\\?\UNC\") = 1
            path := "\\" SubStr(path, 9)
        else if RegExMatch(path, "i)^\\\\\?\\[a-z]:\\")
            path := SubStr(path, 5)
        return RegExMatch(path, "i)^(?:[a-z]:\\|\\\\[^\\]+\\[^\\]+\\).+") ? StrLower(path) : ""
    }

    SetPathIsolation(path, enabled) {
        pathKey := KeyPersonaConfig.AppPathKey(path)
        if pathKey = ""
            return false
        binding := MapGet(this.AppIdentitiesByPath, pathKey, 0)
        if binding {
            if binding.enabled = enabled
                return false
            changes := [[binding.section, "enabled", enabled ? "1" : "0"]]
        } else {
            if !enabled
                return false
            SplitPath(pathKey, , , , &stem)
            stem := SubStr(Trim(RegExReplace(stem, "[^a-z0-9]+", "-"), "-"), 1, 32)
            loop {
                section := "app-identity." (stem = "" ? "app" : stem) "-" Format("{:012x}", Random(0, 0xFFFFFFFFFFFF))
                if !this.Doc.Sections.Has(section)
                    break
            }
            changes := [[section, "path", path]]
        }
        this.WriteChanges(changes)
        this.Reload()
        return true
    }

    ConfiguredAppSelector(values) {
        appId := StrLower(Trim(MapGet(values, "appId", "")))
        if appId != "" {
            binding := MapGet(this.AppIdentities, appId, 0)
            return binding && binding.enabled ? "app:" appId : ""
        }
        exe := Trim(MapGet(values, "exe", ""))
        return exe = "" ? "" : WindowIdentity.AppSelector(exe, Trim(MapGet(values, "packageFamily", "")))
    }

    BaseAppSelector(selector) {
        if InStr(selector, "app:") = 1 {
            binding := MapGet(this.AppIdentities, SubStr(selector, 5), 0)
            return binding ? binding.exe : ""
        }
        separator := InStr(selector, "|")
        return separator ? SubStr(selector, 1, separator - 1) : selector
    }

    LoadAppInputPolicies() {
        policies := Map()
        for section, values in this.Doc.Sections {
            if !RegExMatch(section, "i)^input-app\.")
                continue
            exe := this.ConfiguredAppSelector(values)
            if (exe != "")
                policies[exe] := Map("section", section,
                    "autoMemory", KeyPersonaConfig.OverrideValue(MapGet(values, "autoMemory", "inherit")),
                    "autoSwitch", KeyPersonaConfig.OverrideValue(MapGet(values, "autoSwitch", "inherit")),
                    "force", KeyPersonaConfig.OverrideValue(MapGet(values, "force", "inherit")))
        }
        return policies
    }

    static OverrideValue(value) {
        enabled := ParseBool(value, -1)
        return enabled = -1 ? "inherit" : enabled ? "1" : "0"
    }

    GetAppInputOption(exe, option) {
        return MapGet(MapGet(this.AppInputPolicies, StrLower(exe), Map()), option, "inherit")
    }

    GetInheritedAppInputOption(exe, option) {
        base := this.BaseAppSelector(exe)
        if base != "" && base != exe {
            mode := this.GetAppInputOption(base, option)
            if mode != "inherit"
                return mode = "1"
        }
        return option = "autoMemory" ? this.AutoMemory : option = "autoSwitch" && this.Enabled
    }

    ResolveAppInputOption(exe, option) {
        mode := this.GetAppInputOption(exe, option)
        if mode != "inherit"
            return mode = "1"
        return this.GetInheritedAppInputOption(exe, option)
    }

    IsAppInputForced(exe) {
        return this.ResolveAppInputOption(exe, "force")
    }

    SetAppInputOption(exe, option, mode) {
        exe := StrLower(Trim(exe))
        if (exe = "" || (option != "autoMemory" && option != "autoSwitch" && option != "force")
            || (mode != "inherit" && mode != "0" && mode != "1"))
            return false
        policy := MapGet(this.AppInputPolicies, exe, Map())
        section := MapGet(policy, "section", "input-app." Fnv1a32(exe))
        if (mode != "inherit") {
            changes := KeyPersonaConfig.AppSelectorFields(section, exe)
            changes.Push([section, option, mode])
            this.WriteChanges(changes)
        } else if policy.Count {
            values := this.Doc.Sections[section]
            if (values.Count = KeyPersonaConfig.AppSelectorFields(section, exe).Length + 1 && values.Has(option))
                this.WriteChanges([[section]])
            else
                this.WriteChanges([[section, option]])
        }
        this.Doc := IniDocument.Load(this.Path)
        this.AppInputPolicies := this.LoadAppInputPolicies()
        return true
    }

    static AppSelectorFields(section, selector) {
        if InStr(selector, "app:") = 1
            return [[section, "appId", SubStr(selector, 5)]]
        parts := StrSplit(selector, "|",, 2)
        changes := [[section, "exe", parts[1]]]
        if parts.Length = 2
            changes.Push([section, "packageFamily", parts[2]])
        return changes
    }

    SetPunctuationEnabled(enabled) {
        this.WriteChanges([["punctuation", "enabled", enabled ? "1" : "0"]])
        this.PunctuationEnabled := !!enabled
        this.PunctuationRevision += 1
    }

    SetPunctuationOption(id, pair, enabled) {
        rule := PunctuationCatalog.Find(id)
        if !rule.Count || (pair && rule["close"] = "")
            return false
        this.WriteChanges([["punctuation", (pair ? "pair." : "convert.") id, enabled ? "1" : "0"]])
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
            exe := this.ConfiguredAppSelector(values)
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
        return this.GetInheritedPunctuationOption(exe, id, pair)
    }

    GetInheritedPunctuationOption(exe, id := "", pair := false) {
        base := this.BaseAppSelector(exe)
        if base != "" && base != exe {
            override := this.GetAppPunctuationOption(base, id, pair)
            if override != "inherit"
                return !!override
        }
        if (id = "")
            return this.PunctuationEnabled
        return MapGet(pair ? this.PunctuationPairs : this.PunctuationConvert, id, false)
    }

    HasPunctuationConversion(id) {
        if this.ShouldConvertPunctuation("", id)
            return true
        for exe in this.PunctuationApps {
            if this.ShouldConvertPunctuation(exe, id)
                return true
        }
        return false
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
                this.WriteChanges([[section, key]])
        } else {
            changes := KeyPersonaConfig.AppSelectorFields(section, exe)
            changes.Push([section, key, mode])
            this.WriteChanges(changes)
        }
        this.Reload()
        if this.PunctuationApps.Has(exe) {
            app := this.PunctuationApps[exe]
            if (app["enabled"] = "inherit" && !app["convert"].Count && !app["pairs"].Count) {
                this.WriteChanges([[section]])
                this.Reload()
            }
        }
        return true
    }

    ClearAppPunctuationOptions(exe) {
        exe := StrLower(exe)
        if !this.PunctuationApps.Has(exe)
            return
        this.WriteChanges([[this.PunctuationApps[exe]["section"]]])
        this.Reload()
    }

    GetWindowRule(windowInfo, inherited := false) {
        identityKey := MapGet(windowInfo, inherited ? "legacyIdentityKey" : "identityKey", "")
        if (identityKey = "" || !this.WindowRules.Has(identityKey))
            return Map()
        stored := this.WindowRules[identityKey]
        stateName := stored["stateName"]
        state := this.GetNamedState(stateName = "@global" ? this.DefaultState : stateName)
        if !state.Count
            return Map()
        return Map(
            "name", stored["name"],
            "scope", inherited ? "application" : "window",
            "stateName", stateName,
            "state", state
        )
    }

    SetWindowRule(windowInfo, stateName) {
        identityKey := MapGet(windowInfo, "identityKey", "")
        if (identityKey = "" || (stateName != "@global" && !this.NamedStates.Has(stateName)))
            return false
        existing := MapGet(this.WindowRules, identityKey, Map())
        section := MapGet(existing, "section", "window-rule." Fnv1a32(identityKey))
        baseSection := section
        while this.Doc.Sections.Has(section)
            && IniUnescape(this.Doc.Get(section, "identityKey", "")) != identityKey
            section := baseSection "-" A_Index
        this.WriteChanges([[section, "identityKey", IniEscape(identityKey)], [section, "state", stateName],
            [section, "exe", MapGet(windowInfo, "exe", "")], [section, "mode", MapGet(windowInfo, "mode", "app")]])
        this.Reload()
        return this.WindowRules.Has(identityKey)
    }

    RemoveWindowRule(windowInfo) {
        identityKey := MapGet(windowInfo, "identityKey", "")
        if (identityKey = "" || !this.WindowRules.Has(identityKey))
            return false
        section := this.WindowRules[identityKey]["section"]
        this.WriteChanges([[section]])
        this.Reload()
        return !this.WindowRules.Has(identityKey)
    }

    EnsureDefaultFile() {
        if FileExist(this.Path)
            return
        template := "; " AppInfo.Name " 用户配置。修改后从托盘选择“重新加载”。`n"
            . "; profile 可从托盘状态或 tools\KeyPersona-probe.ahk 的输出中复制。`n`n"
            . "[general]`n"
            . "enabled=1`n"
            . "autoMemory=1`n"
            . "runAsAdmin=0`n"
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
