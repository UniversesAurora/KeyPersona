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
    AssertTest(ShouldReplaceBacktickState(chineseProfile, "1"), "Backtick replacement in Chinese mode", failures)
    AssertTest(!ShouldReplaceBacktickState(chineseProfile, "0"), "Backtick pass-through in IME English mode", failures)
    AssertTest(!ShouldReplaceBacktickState(englishProfile, "1"), "Backtick pass-through for non-Chinese input", failures)
    AssertTest(!ShouldReplaceBacktickState(chineseProfile, "1", false), "Backtick option disables replacement", failures)
    AssertTest(AppInfo.Name != "" && AppInfo.ExecutableFile != "", "Central application identity", failures)
    noOpProbe := ImeModeNoOpProbe()
    noOpState := Map("imeOpen", "1", "conversion", "0x1", "sentence", "0x8")
    AssertTest(noOpProbe.Apply(Map(), noOpState) && noOpProbe.SetCalls = 0,
        "IME mode skips redundant writes", failures)
    changedState := Map("imeOpen", "0", "conversion", "0x1", "sentence", "0x8")
    AssertTest(noOpProbe.Apply(Map(), changedState) && noOpProbe.SetCalls = 1,
        "IME mode writes only changed fields", failures)
    AssertTest(ApplicationVersion() != "", "Application version discovery", failures)
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
    AssertTest(editableConfig.SetBacktickInChinese(true), "Backtick option write", failures)
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
    AssertTest(firstReconcile["added"] = 3,
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
    AssertTest(generatedChineseModes = 2, "Chinese TIP gets Chinese and English states", failures)
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
    AssertTest(reloadedConfig.BacktickInChinese, "Backtick option reload", failures)
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
    try FileDelete(tempState)
    try FileDelete(tempState ".bak")
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
