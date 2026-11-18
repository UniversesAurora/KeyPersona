#Requires AutoHotkey v2.0

RunSelfTests(baseDir) {
    progressPath := baseDir "\self-test.log"
    try FileDelete(progressPath)
    FileAppend("start`n", progressPath, "UTF-8")
    failures := []
    AssertTest(Fnv1a32("abc") = Fnv1a32("abc"), "FNV hash is stable", failures)
    escaped := IniEscape("a\b`r`nc")
    AssertTest(IniUnescape(escaped) = "a\b`r`nc", "INI value round-trip", failures)
    desired := Map("profile", "0409:00000409", "imeOpen", "unknown", "conversion", "preserve", "sentence", "preserve")
    actual := Map("profile", "0409:00000409", "imeOpen", "unknown", "conversion", "unknown", "sentence", "unknown")
    AssertTest(StateMatches(actual, desired), "State wildcard comparison", failures)
    AssertTest(HasKnownProfile(actual), "Known profile detection", failures)
    AssertTest(!HasKnownProfile(Map("profile", "unknown")), "Plain unknown profile rejection", failures)
    AssertTest(!HasKnownProfile(Map("profile", "0000:unknown")), "Qualified unknown profile rejection", failures)
    AssertTest(IsChineseLanguageState(Map("langId", "0804")), "Simplified Chinese language detection", failures)
    AssertTest(!IsChineseLanguageState(Map("langId", "0409")), "Non-Chinese language rejection", failures)
    chineseProfile := Map("profile", "0804:sample", "langId", "0804")
    englishProfile := Map("profile", "0409:00000409", "langId", "0409")
    AssertTest(ShouldReplacePunctuationState(chineseProfile, "1"), "Punctuation replacement in Chinese mode", failures)
    AssertTest(!ShouldReplacePunctuationState(chineseProfile, "0"), "Punctuation pass-through in IME English mode", failures)
    AssertTest(!ShouldReplacePunctuationState(englishProfile, "1"), "Punctuation pass-through for non-Chinese input", failures)
    AssertTest(!ShouldReplacePunctuationState(chineseProfile, "unknown"), "Unknown IME state passes punctuation through", failures)
    AssertTest(!ShouldReplacePunctuationState(chineseProfile, "1", false), "Punctuation option disables replacement", failures)
    punctuationKeys := Map()
    punctuationChars := Map()
    for rule in PunctuationCatalog.Rules {
        for binding in rule["bindings"] {
            AssertTest(!punctuationKeys.Has(binding["key"]), "Punctuation keys have no duplicates", failures)
            punctuationKeys[binding["key"]] := binding["text"]
            punctuationChars[binding["text"]] := true
        }
    }
    AssertTest(punctuationKeys.Count = 32 && punctuationChars.Count = 32,
        "All US keyboard punctuation keys are covered exactly once", failures)
    AssertTest(punctuationKeys["$+SC005"] = "$" && punctuationKeys["$+SC007"] = "^"
        && punctuationKeys["$+SC00C"] = "_" && punctuationKeys["$SC02B"] = "\",
        "Currency ellipsis dash and enumeration keys use US outputs", failures)
    AssertTest(PunctuationCatalog.SendSequence("(", ")") = "{U+0028}{U+0029}{Left 1}",
        "Auto pair inserts both characters and puts the caret between them", failures)
    AssertTest(PunctuationCatalog.SendSequence(")") = "{U+0029}",
        "Closing punctuation has no extra pair or cursor move", failures)
    AssertTest(PunctuationCatalog.SendSequence("{") = "{U+007B}",
        "Send metacharacters are inserted literally", failures)
    AssertTest(AppInfo.Name != "" && AppInfo.ExecutableFile != "", "Central application identity", failures)
    noOpProbe := ImeModeNoOpProbe()
    noOpState := Map("imeOpen", "1", "conversion", "0x1", "sentence", "0x8")
    AssertTest(noOpProbe.Apply(Map(), noOpState) && noOpProbe.SetCalls = 0,
        "IME mode skips redundant writes", failures)
    changedState := Map("imeOpen", "0", "conversion", "0x1", "sentence", "0x8")
    AssertTest(noOpProbe.Apply(Map(), changedState) && noOpProbe.SetCalls = 1,
        "IME mode writes only changed fields", failures)
    AssertTest(ApplicationVersion() != "", "Application version discovery", failures)
    try {
        about := AboutDialog()
        aboutPanel := about.CreatePanel()
        try {
            aboutPanel.Show("Hide")
            projectButton := aboutPanel["ProjectLink"]
            AssertTest(projectButton.Type = "Button" && projectButton.Text = "GitHub"
                && about.ProjectIcon && SendMessage(0xF6, 1, 0, projectButton) = about.ProjectIcon,
                "About window loads the GitHub project icon into a native button", failures)
            AssertTest(TestProjectIconPaint(projectButton, about.ProjectIconSize),
                "GitHub project button draws the icon against the panel without a frame", failures)
            previousCursor := DllCall("user32\GetCursor", "Ptr")
            try {
                hand := DllCall("user32\LoadCursorW", "Ptr", 0, "Ptr", 32649, "Ptr")
                AssertTest(hand && SendMessage(AboutDialog.WM_SETCURSOR, projectButton.Hwnd, 0x02000001, aboutPanel) = 1
                    && DllCall("user32\GetCursor", "Ptr") = hand,
                    "GitHub project icon requests the system hand cursor", failures)
            } finally {
                DllCall("user32\SetCursor", "Ptr", previousCursor)
            }
            AssertTest(InStr(aboutPanel["AuthorLink"].Text, 'href="' AppInfo.AuthorUrl '"'),
                "About window creates the author GitHub link", failures)
        } finally {
            aboutPanel.Destroy()
            about.Dispose()
        }
    } catch Error as failure {
        failures.Push("About window construction: " failure.Message)
    }
    SplitPath(baseDir, &selfTestFolder, &selfTestParent)
    if (StrLower(selfTestFolder) = "src")
        AssertTest(RuntimeBaseDir() = selfTestParent, "Source runtime uses install-root configuration", failures)

    tempPath := A_Temp "\keypersona-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt") ".ini"
    try FileDelete(tempPath)
    FileAppend("[one]`nkey=value`n", tempPath, "UTF-8")
    doc := IniDocument.Load(tempPath)
    AssertTest(doc.Get("one", "key", "") = "value", "INI parser", failures)
    try FileDelete(tempPath)
    FileAppend("utilities-ok`n", progressPath, "UTF-8")

    testConfig := KeyPersonaConfig(baseDir)
    testLogger := Logger(testConfig.LogPath, "off")
    startupApi := StartupManager(testLogger)
    AssertTest(InStr(startupApi.CommandLine(), "--startup") > 0, "Startup command generation", failures)
    AssertTest(SubStr(startupApi.ShortcutPath(), -StrLen(StartupManager.ShortcutName)) = StartupManager.ShortcutName,
        "Startup shortcut path generation", failures)

    migrationDir := A_Temp "\keypersona-migration-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt")
    try DirDelete(migrationDir, true)
    DirCreate(migrationDir)
    FileAppend("; IME Memory 用户配置。`n; tools\ime-probe.ahk`nignoreExe=ime-memory.exe,other.exe`n",
        migrationDir "\" AppInfo.ConfigFile, "UTF-8")
    legacyState := "; Managed by IME Memory.`nidentityKey=ime-memory`ntitle=IME Memory`n"
    FileAppend(legacyState, migrationDir "\" AppInfo.StateFile, "UTF-8")
    FileAppend(legacyState, migrationDir "\" AppInfo.StateFile ".bak", "UTF-8")
    FileAppend("IME Memory ime-memory`n", migrationDir "\ime-memory.log", "UTF-8")
    LegacyMigration.MigrateRuntimeFiles(migrationDir)
    migratedText := FileRead(migrationDir "\" AppInfo.ConfigFile, "UTF-8")
        . FileRead(migrationDir "\" AppInfo.StateFile, "UTF-8")
        . FileRead(migrationDir "\" AppInfo.StateFile ".bak", "UTF-8")
        . FileRead(migrationDir "\" AppInfo.LogFile, "UTF-8")
    AssertTest(!InStr(migratedText, "IME Memory") && !InStr(migratedText, "ime-memory")
        && InStr(migratedText, AppInfo.Name), "Legacy product data migration", failures)
    AssertTest(!FileExist(migrationDir "\ime-memory.log") && FileExist(migrationDir "\" AppInfo.LogFile),
        "Legacy log file migration", failures)
    try DirDelete(migrationDir, true)

    tempConfigDir := A_Temp "\keypersona-config-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt")
    try DirDelete(tempConfigDir, true)
    DirCreate(tempConfigDir)
    FileCopy(baseDir "\" AppInfo.ConfigFile, tempConfigDir "\" AppInfo.ConfigFile, true)
    editableConfig := KeyPersonaConfig(tempConfigDir)
    AssertTest(editableConfig.SetDefaultState("english-us"), "Default state write", failures)
    AssertTest(!editableConfig.SetAutoMemory(false), "Automatic memory setting write", failures)
    editableConfig.SetPunctuationEnabled(true)
    AssertTest(editableConfig.SetPunctuationOption("parentheses", true, true), "Global auto pair setting write", failures)
    AssertTest(editableConfig.SetPunctuationOption("dollar", false, false), "Individual punctuation toggle write", failures)
    AssertTest(editableConfig.SetAppPunctuationOption("Code.exe", "parentheses", true, "0"), "Per-app auto pair override write", failures)
    AssertTest(!editableConfig.ShouldPairPunctuation("CODE.EXE", "parentheses")
        && editableConfig.ShouldPairPunctuation("Notepad.exe", "parentheses"),
        "App disable overrides global enable without affecting other apps", failures)
    AssertTest(editableConfig.SetAppPunctuationOption("Code.exe", "doubleQuote", true, "1")
        && editableConfig.ShouldPairPunctuation("Code.exe", "doubleQuote")
        && !editableConfig.ShouldPairPunctuation("Notepad.exe", "doubleQuote"),
        "App enable overrides global disable for a separate pair", failures)
    editableConfig.SetPunctuationEnabled(false)
    editableConfig.SetAppPunctuationOption("Code.exe", "", false, "1")
    editableConfig.SetAppPunctuationOption("Code.exe", "dollar", false, "1")
    AssertTest(editableConfig.ShouldConvertPunctuation("CODE.EXE", "dollar")
        && !editableConfig.ShouldConvertPunctuation("Notepad.exe", "dollar"),
        "Per-app master and conversion overrides work with global defaults off", failures)
    editableConfig.SetPunctuationOption("comma", false, true)
    editableConfig.SetAppPunctuationOption("Code.exe", "comma", false, "0")
    AssertTest(!editableConfig.ShouldConvertPunctuation("Code.exe", "comma"),
        "An app can disable a globally enabled symbol", failures)
    editableConfig.SetAppPunctuationOption("Code.exe", "dollar", false, "inherit")
    AssertTest(!editableConfig.ShouldConvertPunctuation("Code.exe", "dollar")
        && editableConfig.ShouldPairPunctuation("Code.exe", "doubleQuote"),
        "Restoring conversion inheritance preserves independent auto pair settings", failures)
    editableConfig.SetAppPunctuationOption("Code.exe", "dollar", false, "1")
    editableConfig.SetPunctuationEnabled(true)
    discoveredChineseId := "0804:{11111111-1111-1111-1111-111111111111}{22222222-2222-2222-2222-222222222222}"
    discoveredKeyboardId := "0411:00000411"
    discoveredCatalog := Map(
        "0409:00000409", Map(
            "id", "0409:00000409", "kind", "keyboard", "langId", 0x0409,
            "description", "English (United States) - US"
        ),
        "0804:{86598fb9-66a2-463e-b9c2-aeb906d477ad}{607fdf85-fcc8-4dbd-a365-41296f980c9c}", Map(
            "id", "0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}",
            "kind", "tip", "langId", 0x0804, "description", "WeType"
        ),
        StrLower(discoveredChineseId), Map(
            "id", discoveredChineseId, "kind", "tip", "langId", 0x0804,
            "description", "Test Chinese IME"
        ),
        StrLower(discoveredKeyboardId), Map(
            "id", discoveredKeyboardId, "kind", "keyboard", "langId", 0x0411,
            "description", "Test Japanese Keyboard"
        )
    )
    firstReconcile := editableConfig.ReconcileDiscoveredStates(discoveredCatalog)
    AssertTest(firstReconcile["added"] = 5,
        "Discovered input states are generated", failures)
    secondReconcile := editableConfig.ReconcileDiscoveredStates(discoveredCatalog)
    AssertTest(secondReconcile["added"] = 0 && secondReconcile["removedStates"] = 0,
        "Discovered input state generation is idempotent", failures)
    generatedChineseModes := 0
    generatedKeyboardStates := 0
    generatedKeyboardName := ""
    for generatedStateName, generatedState in editableConfig.NamedStates {
        if (StrLower(MapGet(generatedState, "profile", "")) = StrLower(discoveredChineseId))
            generatedChineseModes += 1
        if (StrLower(MapGet(generatedState, "profile", "")) = StrLower(discoveredKeyboardId)) {
            generatedKeyboardStates += 1
            generatedKeyboardName := generatedStateName
        }
    }
    AssertTest(generatedChineseModes = 3, "Chinese TIP gets Chinese, English and profile-only states", failures)
    AssertTest(generatedKeyboardStates = 1, "Keyboard layout gets one generated state", failures)
    IniWrite("Manual Japanese", editableConfig.Path, "state.manual-japanese", "description")
    IniWrite(discoveredKeyboardId, editableConfig.Path, "state.manual-japanese", "profile")
    IniWrite("unknown", editableConfig.Path, "state.manual-japanese", "imeOpen")
    IniWrite("preserve", editableConfig.Path, "state.manual-japanese", "conversion")
    IniWrite("preserve", editableConfig.Path, "state.manual-japanese", "sentence")
    IniWrite("1", editableConfig.Path, "rule.duplicate", "enabled")
    IniWrite("duplicate.exe", editableConfig.Path, "rule.duplicate", "exe")
    IniWrite(generatedKeyboardName, editableConfig.Path, "rule.duplicate", "state")
    editableConfig.Reload()
    duplicateReconcile := editableConfig.ReconcileDiscoveredStates(discoveredCatalog)
    AssertTest(duplicateReconcile["removedStates"] = 1,
        "Duplicate input state is removed", failures)
    AssertTest(duplicateReconcile["repointedRules"] = 1
        && editableConfig.Doc.Get("rule.duplicate", "state", "") = "manual-japanese",
        "Rules are repointed to the canonical input state", failures)
    configWindow := Map(
        "identityKey", "sample.exe|SampleClass|Sample",
        "exe", "sample.exe", "mode", "window"
    )
    AssertTest(editableConfig.SetWindowRule(configWindow, "wetype-chinese"), "Window rule write", failures)
    storedWindowRule := editableConfig.GetWindowRule(configWindow)
    AssertTest(storedWindowRule.Count && storedWindowRule["stateName"] = "wetype-chinese",
        "Window rule lookup", failures)
    reloadedConfig := KeyPersonaConfig(tempConfigDir)
    AssertTest(reloadedConfig.DefaultState = "english-us", "Default state reload", failures)
    AssertTest(!reloadedConfig.AutoMemory, "Automatic memory setting reload", failures)
    AssertTest(reloadedConfig.PunctuationEnabled && reloadedConfig.PunctuationPairs["parentheses"]
        && !reloadedConfig.PunctuationConvert["dollar"], "Punctuation global options reload", failures)
    AssertTest(!reloadedConfig.ShouldPairPunctuation("Code.exe", "parentheses")
        && reloadedConfig.ShouldPairPunctuation("Code.exe", "doubleQuote"), "Punctuation app options reload", failures)
    AssertTest(reloadedConfig.ShouldConvertPunctuation("Code.exe", "dollar")
        && !reloadedConfig.ShouldConvertPunctuation("Code.exe", "comma"), "Conversion app options reload", failures)
    reloadedConfig.SetAppPunctuationOption("Code.exe", "parentheses", true, "inherit")
    AssertTest(reloadedConfig.ShouldPairPunctuation("Code.exe", "parentheses")
        && reloadedConfig.GetAppPunctuationOption("Code.exe", "parentheses", true) = "inherit",
        "Individual app pair can return to the global setting", failures)
    AssertTest(reloadedConfig.ShouldConvertPunctuation("Code.exe", "dollar"),
        "Restoring auto pair inheritance keeps conversion overrides", failures)
    reloadedConfig.ClearAppPunctuationOptions("Code.exe")
    AssertTest(!reloadedConfig.PunctuationApps.Has("code.exe")
        && !reloadedConfig.ShouldPairPunctuation("Code.exe", "doubleQuote")
        && !reloadedConfig.ShouldConvertPunctuation("Code.exe", "dollar"),
        "All app options can return to global without removing global options", failures)
    IniDelete(reloadedConfig.Path, "punctuation")
    IniWrite("1", reloadedConfig.Path, "typing", "backtickInChinese")
    reloadedConfig.Reload()
    AssertTest(reloadedConfig.PunctuationEnabled && reloadedConfig.PunctuationConvert["backtick"]
        && !reloadedConfig.PunctuationPairs["backtick"] && !reloadedConfig.Doc.Sections.Has("typing")
        && reloadedConfig.Doc.Get("punctuation", "convert.backtick", "") = "1",
        "Existing backtick setting migrates once and removes the old key", failures)
    reloadedConfig.SetPunctuationEnabled(false)
    IniWrite("1", reloadedConfig.Path, "typing", "backtickInChinese")
    reloadedConfig.Reload()
    AssertTest(!reloadedConfig.PunctuationEnabled && !reloadedConfig.Doc.Sections.Has("typing"),
        "Migration keeps explicit new settings", failures)
    AssertTest(reloadedConfig.GetWindowRule(configWindow).Count > 0, "Window rule reload", failures)
    AssertTest(reloadedConfig.RemoveWindowRule(configWindow), "Window rule removal", failures)
    AssertTest(!reloadedConfig.GetWindowRule(configWindow).Count, "Window rule removal verification", failures)
    AssertTest(reloadedConfig.RemoveApplicationRule("raycast"), "Application rule removal", failures)
    raycastWindow := Map("exe", "Raycast.exe", "path", "Raycast.exe", "class", "Raycast", "title", "Raycast")
    AssertTest(!RuleEngine(reloadedConfig, testLogger).Match(raycastWindow).Count,
        "Application rule removal verification", failures)
    invalidProfileId := "0404:DEADBEEF"
    IniWrite(invalidProfileId, reloadedConfig.Path, "state.invalid-input", "profile")
    IniWrite("unknown", reloadedConfig.Path, "state.invalid-input", "imeOpen")
    IniWrite("1", reloadedConfig.Path, "rule.invalid-input", "enabled")
    IniWrite("invalid.exe", reloadedConfig.Path, "rule.invalid-input", "exe")
    IniWrite("invalid-input", reloadedConfig.Path, "rule.invalid-input", "state")
    IniWrite("invalid-input", reloadedConfig.Path, "general", "defaultState")
    reloadedConfig.Reload()
    invalidReconcile := reloadedConfig.ReconcileDiscoveredStates(discoveredCatalog)
    AssertTest(invalidReconcile["removedStates"] = 1 && invalidReconcile["removedRules"] = 1,
        "Unavailable input state and rule are removed", failures)
    AssertTest(invalidReconcile["defaultChanged"]
        && discoveredCatalog.Has(StrLower(MapGet(reloadedConfig.GetNamedState(reloadedConfig.DefaultState), "profile", ""))),
        "Unavailable global default falls back to a valid state", failures)
    try DirDelete(tempConfigDir, true)

    tempState := A_Temp "\keypersona-state-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt") ".ini"
    try FileDelete(tempState)
    try FileDelete(tempState ".bak")
    storeApi := StateStore(tempState, testLogger)
    syntheticWindow := Map(
        "identityKey", "sample.exe",
        "mode", "app", "exe", "sample.exe", "path", "sample.exe",
        "class", "SampleWindow", "normalizedTitle", "Sample"
    )
    learnedState := Map(
        "profile", "0409:00000409", "imeOpen", "unknown",
        "conversion", "unknown", "sentence", "unknown"
    )
    storeApi.Upsert(syntheticWindow, learnedState, "learned")
    invalidWindow := Map(
        "identityKey", "invalid.exe", "mode", "app", "exe", "invalid.exe",
        "path", "invalid.exe", "class", "InvalidWindow", "normalizedTitle", "Invalid"
    )
    storeApi.Upsert(invalidWindow, Map(
        "profile", "0404:DEADBEEF", "imeOpen", "unknown",
        "conversion", "unknown", "sentence", "unknown"
    ), "learned")
    AssertTest(storeApi.RemoveInvalidProfiles(Map("0409:00000409", true)) = 1,
        "Unavailable remembered profile is removed", failures)
    AssertTest(storeApi.Flush(), "State store atomic flush", failures)
    loadedStore := StateStore(tempState, testLogger)
    AssertTest(StateMatches(loadedStore.Find(syntheticWindow), learnedState), "State store round-trip", failures)
    AssertTest(MapGet(loadedStore.Find(syntheticWindow), "source", "") = "learned", "State source round-trip", failures)
    FileCopy(tempState, tempState ".bak", true)
    FileDelete(tempState)
    FileAppend("[broken`n", tempState, "UTF-8")
    recoveredStore := StateStore(tempState, testLogger)
    AssertTest(StateMatches(recoveredStore.Find(syntheticWindow), learnedState), "State backup recovery", failures)
    AssertTest(recoveredStore.ClearAll() = 1, "Clear-all removes persisted records", failures)
    AssertTest(recoveredStore.Flush(), "Clear-all state flush", failures)
    clearedStore := StateStore(tempState, testLogger)
    clearedBackup := StateStore(tempState ".bak", testLogger)
    AssertTest(clearedStore.Records.Count = 0 && clearedBackup.Records.Count = 0,
        "Clear-all removes primary and backup memories", failures)
    try FileDelete(tempState)
    try FileDelete(tempState ".bak")

    policyState := Map(
        "profile", "0409:00000409", "imeOpen", "unknown",
        "conversion", "unknown", "sentence", "unknown", "source", "learned"
    )
    ruleState := Map(
        "profile", "0804:rule", "imeOpen", "1",
        "conversion", "preserve", "sentence", "preserve"
    )
    ruleMatch := Map("state", ruleState)
    defaultPolicyState := Map(
        "profile", "0804:default", "imeOpen", "1",
        "conversion", "preserve", "sentence", "preserve"
    )
    rememberedTarget := KeyPersonaApp.ChooseDesiredState(
        true, policyState, Map(), ruleMatch, defaultPolicyState)
    AssertTest(MapGet(rememberedTarget, "profile", "") = "0409:00000409",
        "Automatic memory takes priority over a user default rule", failures)
    ruleTarget := KeyPersonaApp.ChooseDesiredState(
        true, Map(), Map(), ruleMatch, defaultPolicyState)
    AssertTest(MapGet(ruleTarget, "profile", "") = "0804:rule"
        && MapGet(ruleTarget, "source", "") = "rule",
        "User rule seeds a window without memory", failures)
    disabledRuleTarget := KeyPersonaApp.ChooseDesiredState(
        false, Map(), policyState, ruleMatch, defaultPolicyState)
    AssertTest(MapGet(disabledRuleTarget, "profile", "") = "0804:rule",
        "Disabled automatic memory still applies user rules", failures)
    unmanagedTarget := KeyPersonaApp.ChooseDesiredState(
        false, Map(), policyState, Map(), defaultPolicyState)
    AssertTest(unmanagedTarget.Count = 0,
        "Disabled automatic memory leaves unmatched windows unchanged", failures)
    observedBaseline := StateClone(policyState)
    observedBaseline["source"] := "observed"
    baselineTarget := KeyPersonaApp.ChooseDesiredState(
        true, observedBaseline, Map(), ruleMatch, defaultPolicyState)
    AssertTest(MapGet(baselineTarget, "profile", "") = "0804:rule"
        && MapGet(baselineTarget, "source", "") = "rule",
        "Observation baseline does not become automatic memory", failures)
    AssertTest(KeyPersonaApp.IsSameTopLevelWindow(Map("hwnd", 100), Map("hwnd", 100)),
        "Foreground observation accepts the current top-level window", failures)
    AssertTest(!KeyPersonaApp.IsSameTopLevelWindow(Map("hwnd", 100), Map("hwnd", 200)),
        "Foreground observation rejects a window after focus leaves it", failures)
    rulesApi := RuleEngine(testConfig, testLogger)
    terminalWindow := Map("exe", "WindowsTerminal.exe", "path", "WindowsTerminal.exe", "class", "CASCADIA_HOSTING_WINDOW_CLASS", "title", "Terminal")
    terminalRule := rulesApi.Match(terminalWindow)
    AssertTest(terminalRule.Count && terminalRule["stateName"] = "english-us", "User rule matching", failures)
    FileAppend("persistence-rules-ok`n", progressPath, "UTF-8")

    identityApi := WindowIdentity(testConfig, testLogger)
    window := identityApi.Resolve()
    AssertTest(window.Count > 0, "Foreground window resolution", failures)
    if window.Count {
        AssertTest(identityApi.IsIgnored("explorer.exe", "Shell_SecondaryTrayWnd", window["hwnd"]),
            "Secondary taskbar surface ignored", failures)
        AssertTest(identityApi.IsIgnored("explorer.exe", "TopLevelWindowForOverflowXamlIsland", window["hwnd"]),
            "Tray overflow surface ignored", failures)
    }
    FileAppend("window-ok`n", progressPath, "UTF-8")
    profileApi := InputProfiles(identityApi, testConfig, testLogger)
    AssertTest(profileApi.Catalog.Count >= 2, "Enabled profile discovery", failures)
    FileAppend("profiles-ok count=" profileApi.Catalog.Count "`n", progressPath, "UTF-8")
    if window.Count {
        state := profileApi.Read(window)
        AssertTest(MapGet(state, "profile", "") != "", "Foreground profile read", failures)
        FileAppend("profile-read=" MapGet(state, "profile", "") "`n", progressPath, "UTF-8")
        imeState := ImeMode(identityApi, testConfig, testLogger).Read(window, MapGet(state, "kind", "unknown"))
        AssertTest(imeState.Has("imeOpen"), "IME mode read path", failures)
        FileAppend("ime-read=" MapGet(imeState, "imeOpen", "") "`n", progressPath, "UTF-8")
    }
    if failures.Length {
        text := "SELF-TEST FAILED (" failures.Length ")`n- " JoinValues(failures, "`n- ") "`n"
        FileAppend(text, progressPath, "UTF-8")
        return 1
    }
    FileAppend("SELF-TEST PASSED`n", progressPath, "UTF-8")
    return 0
}

AssertTest(condition, name, failures) {
    if !condition
        failures.Push(name)
}

class ImeModeNoOpProbe extends ImeMode {
    __New() {
        this.SetCalls := 0
    }

    GetImeWindow(windowInfo) {
        return 1
    }

    Control(imeWindow, command, value) {
        if (command = ImeMode.IMC_SETOPENSTATUS
            || command = ImeMode.IMC_SETCONVERSIONMODE
            || command = ImeMode.IMC_SETSENTENCEMODE) {
            this.SetCalls += 1
            return Map("ok", true, "value", value, "error", 0)
        }
        current := command = ImeMode.IMC_GETOPENSTATUS ? 1
            : command = ImeMode.IMC_GETCONVERSIONMODE ? 0x1
            : command = ImeMode.IMC_GETSENTENCEMODE ? 0x8 : 0
        return Map("ok", true, "value", current, "error", 0)
    }
}

TestProjectIconPaint(button, iconSize) {
    bounds := Buffer(16, 0)
    DllCall("user32\GetClientRect", "Ptr", button.Hwnd, "Ptr", bounds)
    width := NumGet(bounds, 8, "Int")
    height := NumGet(bounds, 12, "Int")
    screen := DllCall("user32\GetDC", "Ptr", 0, "Ptr")
    bitmap := DllCall("gdi32\CreateCompatibleBitmap", "Ptr", screen, "Int", width, "Int", height, "Ptr")
    target := DllCall("gdi32\CreateCompatibleDC", "Ptr", screen, "Ptr")
    DllCall("user32\ReleaseDC", "Ptr", 0, "Ptr", screen)
    previous := DllCall("gdi32\SelectObject", "Ptr", target, "Ptr", bitmap, "Ptr")
    try {
        Sleep(20)
        SendMessage(0x318, target, 0xC, button) ; WM_PRINTCLIENT, PRF_CLIENT | PRF_ERASEBKGND
        top := DllCall("gdi32\GetPixel", "Ptr", target, "Int", width // 2, "Int", 0, "UInt")
        edge := DllCall("gdi32\GetPixel", "Ptr", target, "Int", 0, "Int", height // 2, "UInt")
        glyph := DllCall("gdi32\GetPixel", "Ptr", target, "Int", (width - iconSize) // 2 + 2,
            "Int", height // 2, "UInt")
        return top = 0xFAF7F5 && edge = top && glyph < 0x777777
    } finally {
        DllCall("gdi32\SelectObject", "Ptr", target, "Ptr", previous)
        DllCall("gdi32\DeleteDC", "Ptr", target)
        DllCall("gdi32\DeleteObject", "Ptr", bitmap)
    }
}
