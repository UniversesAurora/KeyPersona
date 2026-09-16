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
    noOpProbe := ImeModeNoOpProbe()
    noOpState := Map("imeOpen", "1", "conversion", "0x1", "sentence", "0x8")
    AssertTest(noOpProbe.Apply(Map(), noOpState) && noOpProbe.SetCalls = 0,
        "IME mode skips redundant writes", failures)
    changedState := Map("imeOpen", "0", "conversion", "0x1", "sentence", "0x8")
    AssertTest(noOpProbe.Apply(Map(), changedState) && noOpProbe.SetCalls = 1,
        "IME mode writes only changed fields", failures)
    AssertTest(ApplicationVersion() != "", "Application version discovery", failures)

    tempPath := A_Temp "\ime-memory-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt") ".ini"
    try FileDelete(tempPath)
    FileAppend("[one]`nkey=value`n", tempPath, "UTF-8")
    doc := IniDocument.Load(tempPath)
    AssertTest(doc.Get("one", "key", "") = "value", "INI parser", failures)
    try FileDelete(tempPath)
    FileAppend("utilities-ok`n", progressPath, "UTF-8")

    testConfig := ImeMemoryConfig(baseDir)
    testLogger := Logger(testConfig.LogPath, "off")
    startupApi := StartupManager(testLogger)
    AssertTest(InStr(startupApi.CommandLine(), "--startup") > 0, "Startup command generation", failures)

    tempConfigDir := A_Temp "\ime-memory-config-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt")
    try DirDelete(tempConfigDir, true)
    DirCreate(tempConfigDir)
    FileCopy(baseDir "\config.ini", tempConfigDir "\config.ini", true)
    editableConfig := ImeMemoryConfig(tempConfigDir)
    AssertTest(editableConfig.SetDefaultState("english-us"), "Default state write", failures)
    reloadedConfig := ImeMemoryConfig(tempConfigDir)
    AssertTest(reloadedConfig.DefaultState = "english-us", "Default state reload", failures)
    try DirDelete(tempConfigDir, true)

    tempState := A_Temp "\ime-memory-state-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt") ".ini"
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
    storeApi.Upsert(syntheticWindow, learnedState)
    AssertTest(storeApi.Flush(), "State store atomic flush", failures)
    loadedStore := StateStore(tempState, testLogger)
    AssertTest(StateMatches(loadedStore.Find(syntheticWindow), learnedState), "State store round-trip", failures)
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
    AssertTest(terminalRule.Count && terminalRule["stateName"] = "english-us", "Force rule matching", failures)
    FileAppend("persistence-rules-ok`n", progressPath, "UTF-8")

    identityApi := WindowIdentity(testConfig, testLogger)
    window := identityApi.Resolve()
    AssertTest(window.Count > 0, "Foreground window resolution", failures)
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
