#Requires AutoHotkey v2.0

RunSelfTests(baseDir) {
    progressPath := baseDir "\self-test.log"
    try FileDelete(progressPath)
    FileAppend("start`n", progressPath, "UTF-8")
    failures := []
    AssertTest(Fnv1a32("abc") = Fnv1a32("abc"), "FNV hash is stable", failures)
    escaped := IniEscape("a\b`r`nc")
    AssertTest(IniUnescape(escaped) = "a\b`r`nc" && IniUnescape(IniEscape(Chr(0xE000))) = Chr(0xE000),
        "INI value round-trip including private-use Unicode", failures)
    desired := Map("profile", "0409:00000409", "imeOpen", "unknown", "conversion", "preserve", "sentence", "preserve")
    actual := Map("profile", "0409:00000409", "imeOpen", "unknown", "conversion", "unknown", "sentence", "unknown")
    AssertTest(StateMatches(actual, desired), "State wildcard comparison", failures)
    AssertTest(StateMatches(Map("conversion", "0x9"), Map("conversion", "9")),
        "Equivalent mode flags match across number formats", failures)
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
    AssertTest(!noOpProbe.Apply(Map(), changedState,, (*) => false) && noOpProbe.SetCalls = 1,
        "Cancelled restoration cannot update an IME mode", failures)
    AssertTest(ApplicationVersion() != "", "Application version discovery", failures)
    lockPath := A_Temp "\keypersona-lock-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt")
    AssertTest(AcquireRuntimeLock(lockPath) && !AcquireRuntimeLock(lockPath),
        "A configuration directory is reserved for one writer", failures)
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
    adminCommand := ElevationManager.RestartCommand("a folder\interpreter.exe", "a folder\source.ahk", 42,
        "S-1-5-21-0", true)
    AssertTest(InStr(adminCommand, '"' "a folder\interpreter.exe" '"' " /force " '"' "a folder\source.ahk" '"')
        && InStr(adminCommand, "--admin-parent=42") && InStr(adminCommand, "--enable-admin"),
        "Administrator handoff quotes executable and script paths", failures)
    try scheduler := startupApi.OpenScheduler()
    catch
        scheduler := 0
    if scheduler {
        definition := startupApi.MakeTaskDefinition(scheduler)
        AssertTest(startupApi.TaskUsesCurrentAccount(definition) && definition.Principal.RunLevel = 1
            && definition.Principal.LogonType = 3
            && definition.Triggers.Item(1).Type = 9 && definition.Actions.Item(1).Path = startupApi.TargetPath()
            && definition.Actions.Item(1).Arguments = startupApi.Arguments(),
            "Administrator startup definition uses current-user elevated interactive logon", failures)
    }
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
        "identityKey", "sample.exe|SampleClass|日本語 🚀",
        "exe", "sample.exe", "mode", "window"
    )
    AssertTest(editableConfig.SetWindowRule(configWindow, "wetype-chinese"), "Window rule write", failures)
    storedWindowRule := editableConfig.GetWindowRule(configWindow)
    AssertTest(storedWindowRule.Count && storedWindowRule["stateName"] = "wetype-chinese",
        "Window rule lookup", failures)
    reloadedConfig := KeyPersonaConfig(tempConfigDir)
    AssertTest(reloadedConfig.DefaultState = "english-us", "Default state reload", failures)
    AssertTest(!reloadedConfig.AutoMemory, "Automatic memory setting reload", failures)
    AssertTest(reloadedConfig.SetAppInputOption("Code.exe", "autoMemory", "0")
        && reloadedConfig.SetAppInputOption("CODE.EXE", "force", "1"),
        "Per-app input settings persist both options", failures)
    reloadedConfig := KeyPersonaConfig(tempConfigDir)
    AssertTest(reloadedConfig.GetAppInputOption("Code.exe", "autoMemory") = "0" && reloadedConfig.IsAppInputForced("code.exe")
        && reloadedConfig.GetAppInputOption("Other.exe", "autoMemory") = "inherit" && !reloadedConfig.IsAppInputForced("Other.exe"),
        "Per-app input settings are case-insensitive and opt-in", failures)
    AssertTest(reloadedConfig.SetAppInputOption("code.exe", "autoMemory", "inherit")
        && reloadedConfig.GetAppInputOption("code.exe", "autoMemory") = "inherit" && reloadedConfig.IsAppInputForced("code.exe"),
        "Returning to global memory preserves enforcement", failures)
    AssertTest(reloadedConfig.SetAppInputOption("code.exe", "force", "inherit")
        && !reloadedConfig.AppInputPolicies.Has("code.exe"),
        "Clearing the last input override removes the empty section", failures)
    reloadedConfig.SetAutoSwitch(false)
    reloadedConfig.SetAppInputOption("Code.exe", "autoMemory", "1")
    reloadedConfig.SetAppInputOption("Code.exe", "autoSwitch", "1")
    reloadedConfig.SetRunAsAdmin(true)
    reloadedConfig := KeyPersonaConfig(tempConfigDir)
    AssertTest(reloadedConfig.RunAsAdmin && !reloadedConfig.Enabled && !reloadedConfig.AutoMemory
        && reloadedConfig.ResolveAppInputOption("code.exe", "autoMemory")
        && reloadedConfig.ResolveAppInputOption("code.exe", "autoSwitch")
        && !reloadedConfig.ResolveAppInputOption("other.exe", "autoSwitch"),
        "Administrator preference and positive app overrides persist independently", failures)
    reloadedConfig.SetAutoSwitch(true)
    reloadedConfig.SetRunAsAdmin(false)
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
    TestPunctuationBindings(reloadedConfig, failures)
    AssertTest(reloadedConfig.GetWindowRule(configWindow).Count > 0, "Window rule reload", failures)
    AssertTest(reloadedConfig.RemoveWindowRule(configWindow), "Window rule removal", failures)
    AssertTest(!reloadedConfig.GetWindowRule(configWindow).Count, "Window rule removal verification", failures)
    raycastWindow := Map("exe", "Raycast.exe", "path", "Raycast.exe", "class", "Raycast", "title", "Raycast")
    raycastWindow["identityKey"] := "raycast.exe"
    AssertTest(reloadedConfig.SetWindowRule(raycastWindow, "@global")
        && reloadedConfig.GetWindowRule(raycastWindow)["state"]["profile"]
            = reloadedConfig.GetNamedState(reloadedConfig.DefaultState)["profile"],
        "An explicit global override follows the current global default", failures)
    AssertTest(reloadedConfig.RemoveWindowRule(raycastWindow)
        && RuleEngine(reloadedConfig, testLogger).Match(raycastWindow).Count > 0,
        "Removing a window override preserves the application rule", failures)
    invalidProfileId := "0404:DEADBEEF"
    IniWrite(invalidProfileId, reloadedConfig.Path, "state.invalid-input", "profile")
    IniWrite("unknown", reloadedConfig.Path, "state.invalid-input", "imeOpen")
    IniWrite("1", reloadedConfig.Path, "rule.invalid-input", "enabled")
    IniWrite("invalid.exe", reloadedConfig.Path, "rule.invalid-input", "exe")
    IniWrite("invalid-input", reloadedConfig.Path, "rule.invalid-input", "state")
    IniWrite("invalid-input", reloadedConfig.Path, "general", "defaultState")
    reloadedConfig.WriteChanges([["state.custom-a", "profile", discoveredKeyboardId],
        ["state.custom-a", "conversion", "0x1"], ["state.custom-b", "profile", discoveredKeyboardId],
        ["state.custom-b", "conversion", "0x9"], ["rule.custom", "exe", "custom.exe"],
        ["rule.custom", "state", "custom-b"]])
    reloadedConfig.Reload()
    invalidReconcile := reloadedConfig.ReconcileDiscoveredStates(discoveredCatalog)
    AssertTest(reloadedConfig.GetNamedState("custom-a")["conversion"] = "0x1"
        && RuleEngine(reloadedConfig, testLogger).Match(Map("exe", "custom.exe"))["state"]["conversion"] = "0x9",
        "Distinct custom modes survive reconciliation", failures)
    AssertTest(invalidReconcile["removedStates"] = 1 && invalidReconcile["removedRules"] = 1,
        "Unavailable input state and rule are removed", failures)
    AssertTest(invalidReconcile["defaultChanged"]
        && discoveredCatalog.Has(StrLower(MapGet(reloadedConfig.GetNamedState(reloadedConfig.DefaultState), "profile", ""))),
        "Unavailable global default falls back to a valid state", failures)

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
    missingStore := StateStore(tempState, testLogger)
    AssertTest(missingStore.Records.Count = 1, "Missing main state uses backup", failures)
    FileAppend("[meta]`nschemaVersion=3`nrecordCount=1`nupdatedAt=test`n`n[window.partial]`n", tempState, "UTF-8")
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
    AssertTest(KeyPersonaApp.IsSameTopLevelWindow(Map("hwnd", 100), Map("hwnd", 100)),
        "Foreground observation accepts the current top-level window", failures)
    AssertTest(!KeyPersonaApp.IsSameTopLevelWindow(Map("hwnd", 100), Map("hwnd", 200)),
        "Foreground observation rejects a window after focus leaves it", failures)
    rulesApi := RuleEngine(testConfig, testLogger)
    terminalWindow := Map("exe", "WindowsTerminal.exe", "path", "WindowsTerminal.exe", "class", "CASCADIA_HOSTING_WINDOW_CLASS", "title", "Terminal")
    terminalRule := rulesApi.Match(terminalWindow)
    AssertTest(terminalRule.Count && terminalRule["stateName"] = "english-us", "User rule matching", failures)
    FileAppend("persistence-rules-ok`n", progressPath, "UTF-8")

    TestProfileSyncRetry(tempConfigDir, discoveredCatalog, testLogger, failures)
    TestInputChangeKeys(failures)
    TestInputRestoration(testConfig, testLogger, failures)
    TestAppInputPolicy(testConfig, testLogger, failures)
    TestKeyboardPoll(testConfig, testLogger, failures)
    identityApi := WindowIdentity(testConfig)
    window := identityApi.Resolve()
    AssertTest(!identityApi.Resolve(A_ScriptHwnd).Count, "Window resolution ignores its own process", failures)
    desktop := DllCall("user32\GetShellWindow", "Ptr")
    if desktop
        AssertTest(!identityApi.Resolve(desktop).Count, "Window resolution ignores the shell desktop", failures)
    if window.Count {
        AssertTest(identityApi.IsIgnored("explorer.exe", "Shell_SecondaryTrayWnd", window["hwnd"]),
            "Secondary taskbar surface ignored", failures)
        AssertTest(identityApi.IsIgnored("explorer.exe", "TopLevelWindowForOverflowXamlIsland", window["hwnd"]),
            "Tray overflow surface ignored", failures)
    }
    FileAppend("window-ok`n", progressPath, "UTF-8")
    profileApi := InputProfiles(identityApi, testLogger)
    AssertTest(profileApi.LastRefreshSucceeded && profileApi.Catalog.Count >= 1, "Windows enabled profile discovery", failures)
    FileAppend("profiles-ok count=" profileApi.Catalog.Count "`n", progressPath, "UTF-8")
    if window.Count {
        state := profileApi.Read(window)
        AssertTest(MapGet(state, "profile", "") != "", "Foreground profile read", failures)
        FileAppend("profile-read=" MapGet(state, "profile", "") "`n", progressPath, "UTF-8")
        imeState := ImeMode(identityApi, testConfig).Read(window, MapGet(state, "kind", "unknown"))
        AssertTest(imeState.Has("imeOpen"), "IME mode read path", failures)
        FileAppend("ime-read=" MapGet(imeState, "imeOpen", "") "`n", progressPath, "UTF-8")
    } else {
        FileAppend("No recordable foreground window during self-test.`n", progressPath, "UTF-8")
    }
    try TestInputProfilesAndMenu(profileApi, editableConfig, failures)
    finally DirDelete(tempConfigDir, true)
    if failures.Length {
        text := "SELF-TEST FAILED (" failures.Length ")`n- " JoinValues(failures, "`n- ") "`n"
        FileAppend(text, progressPath, "UTF-8")
        return 1
    }
    FileAppend("SELF-TEST PASSED`n", progressPath, "UTF-8")
    return 0
}

TestPunctuationBindings(config, failures) {
    controller := PunctuationBindingProbe({ObserveOnly: false, Config: config})
    exe := "punctuation-fixture.exe"
    config.SetAutoSwitch(false)
    try {
        controller.RefreshBindings()
        AssertTest(!controller.Registrations.Count, "Disabled conversion does not register hotkeys", failures)

        config.SetPunctuationEnabled(true)
        controller.RefreshBindings()
        AssertTest(MapGet(controller.Registrations, "backtick", {enabled: false}).enabled && config.ShouldConvertPunctuation(exe, "backtick")
            && !config.ResolveAppInputOption(exe, "autoSwitch"),
            "Global punctuation conversion works with automatic switching disabled", failures)

        config.SetPunctuationEnabled(false)
        config.SetAppPunctuationOption(exe, "", false, "1")
        config.SetAppInputOption(exe, "autoSwitch", "0")
        controller.RefreshBindings()
        AssertTest(MapGet(controller.Registrations, "backtick", {enabled: false}).enabled && config.ShouldConvertPunctuation(exe, "backtick")
            && !config.ShouldConvertPunctuation("other.exe", "backtick") && !config.ResolveAppInputOption(exe, "autoSwitch"),
            "Per-app punctuation conversion works independently of per-app automatic switching", failures)
    } finally {
        config.ClearAppPunctuationOptions(exe)
        config.SetAppInputOption(exe, "autoSwitch", "inherit")
        config.SetPunctuationEnabled(false)
        controller.Dispose()
    }
}

class PunctuationBindingProbe extends PunctuationController {
    SetBindingEnabled(rule, enabled) {
        this.Registrations[rule["id"]] := {enabled: enabled}
    }
}

TestProfileSyncRetry(baseDir, catalog, logger, failures) {
    config := ProfileSyncConfigProbe(baseDir)
    savedProfileId := "0404:00000404"
    profileId := "040c:0000040c"
    newCatalog := catalog.Clone()
    newCatalog[profileId] := Map("id", profileId, "kind", "keyboard", "langId", 0x040C, "description", "French")
    config.WriteChanges([["state.removed-for-sync", "profile", savedProfileId],
        ["rule.removed-for-sync", "exe", "sync-fixture.exe"], ["rule.removed-for-sync", "state", "removed-for-sync"]])
    config.Reload()
    original := FileRead(config.Path, "UTF-8")
    config.WriteAttempts := 0
    app := ProfileSyncAppProbe(config, newCatalog, logger)
    try {
        app.SyncDiscoveredProfiles()
        app.SyncDiscoveredProfiles()
        AssertTest(!config.WriteAttempts && app.ProfileCleanupRevision = 1,
            "A single catalog snapshot cannot remove a saved profile", failures)
        recoveredCatalog := catalog.Clone()
        recoveredCatalog[savedProfileId] := Map("id", savedProfileId, "kind", "keyboard", "langId", 0x0404)
        app.NextCatalog := recoveredCatalog
        app.RefreshInputProfiles()
        AssertTest(!config.WriteAttempts && app.SyncedProfileRevision = 2
            && config.GetNamedState("removed-for-sync").Count && FileRead(config.Path, "UTF-8") == original,
            "A temporarily missing profile keeps its state and rule", failures)

        config.FailNextWrite := true
        app.NextCatalog := newCatalog
        app.RefreshInputProfiles()
        app.RefreshInputProfiles()
        app.SyncDiscoveredProfiles()
        AssertTest(config.WriteAttempts = 1 && app.SyncedProfileRevision = 2
            && FileRead(config.Path, "UTF-8") == original,
            "Failed profile reconciliation leaves the complete config intact and does not retry on a hot-path read", failures)
        app.RefreshInputProfiles()
        app.RefreshInputProfiles()
        AssertTest(config.WriteAttempts = 2 && app.SyncedProfileRevision = 3 && app.RuleRefreshes = 1
            && !config.GetNamedState("removed-for-sync").Count
            && !config.Doc.Get("rule.removed-for-sync", "state", "")
            && config.GetNamedState("auto-" StrLower(Fnv1a32(profileId)))["profile"] = profileId,
            "The same catalog revision is retried and applied in a single config write", failures)
    } finally SetTimer(app.ProfileSyncCallback, 0)
}

class ProfileSyncConfigProbe extends KeyPersonaConfig {
    FailNextWrite := false
    WriteAttempts := 0

    WriteChanges(changes) {
        this.WriteAttempts += 1
        if this.FailNextWrite {
            this.FailNextWrite := false
            throw Error("Simulated temporary config write failure")
        }
        super.WriteChanges(changes)
    }
}

class ProfileSyncAppProbe extends KeyPersonaApp {
    __New(config, catalog, logger) {
        this.Config := config
        this.Logger := logger
        this.Profiles := this
        this.Catalog := catalog
        this.NextCatalog := 0
        this.Revision := 1
        this.LastRefreshSucceeded := true
        this.Store := this
        this.Records := Map()
        this.ObserveOnly := false
        this.ShuttingDown := false
        this.SyncedProfileRevision := -1
        this.FailedProfileRevision := -1
        this.ProfileCleanupRevision := -1
        this.ProfileSyncInProgress := false
        this.ProfileSyncCallback := ObjBindMethod(this, "RefreshInputProfiles")
        this.RuleRefreshes := 0
    }

    RefreshCatalog() {
        if this.NextCatalog {
            this.Catalog := this.NextCatalog
            this.NextCatalog := 0
            this.Revision += 1
        }
    }

    RemoveInvalidProfiles(validProfiles) => 0
    RemoveInvalidRuntimeStates(validProfiles) => 0
    RefreshRuleEngine() => this.RuleRefreshes += 1
    QueueWindowCheck() {
    }
}

TestInputProfilesAndMenu(profiles, config, failures) {
    legacyId := "0804:E0200804"
    usId := "0409:00000409"
    japaneseId := "0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}"
    tipId := "0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}{607FDF85-FCC8-4DBD-A365-41296F980C9C}"
    rowSize := InputProfiles.ENABLED_PROFILE_SIZE
    profileBytes := Buffer(rowSize * 4, 0)
    category := GuidBuffer(InputProfiles.CATEGORY_KEYBOARD)
    for index, id in [usId, legacyId, japaneseId, tipId] {
        offset := (index - 1) * rowSize
        NumPut("UInt", index < 3 ? 2 : 1, profileBytes, offset)
        if (index >= 3)
            DllCall("ntdll\RtlMoveMemory", "Ptr", profileBytes.Ptr + offset + 40, "Ptr", category, "UPtr", 16)
        if (index = 4)
            NumPut("UInt", 0x2, profileBytes, offset + 60)
        NumPut("UShort", Integer("0x" SubStr(id, 1, 4)), profileBytes, offset + 4)
        StrPut(index = 2 ? SubStr(id, 6) : id, profileBytes.Ptr + offset + 64, 260, "UTF-16")
    }
    catalog := profiles.ParseEnabledProfiles(profileBytes, 4)
    AssertTest(catalog.Count = 3 && !catalog.Has(StrLower(tipId))
        && catalog[StrLower(legacyId)]["kind"] = "ime", "Discovery includes legacy IMEs and skips disabled TIPs", failures)
    profiles.SetCatalog(catalog)
    profiles.Manager := ""
    usLayout := Map("kind", "keyboard", "hkl", "0x04090409")
    AssertTest(profiles.CanVerifyKeyboardWithLayout(usLayout)
        && !profiles.CanVerifyKeyboardWithLayout(Map("kind", "keyboard", "hkl", "0x04092000")),
        "Only stable keyboard handles qualify for lightweight enforcement", failures)
    profiles.ByLanguage["0409"].Push(profiles.ParseProfile("0409:" SubStr(tipId, 6)))
    AssertTest(!profiles.CanVerifyKeyboardWithLayout(usLayout),
        "A keyboard sharing its language with a TSF input source needs full reads", failures)
    profiles.ByLanguage["0409"].Pop()
    AssertTest(profiles.ResolveProfileForLanguage(0x0804, 0xE0200804)["id"] = legacyId
        && !profiles.ResolveProfileForLanguage(0x0804, 0xE0210804).Count,
        "Legacy IMEs require a matching layout handle", failures)
    AssertTest(profiles.ResolveProfileForLanguage(0x2000, 0x04092000)["id"] = usId,
        "A transient LANGID resolves only through matching layout evidence", failures)
    AssertTest(profiles.ResolveProfileForLanguage(0x0409, 0x04090409)["id"] = usId
        && !profiles.ResolveProfileForLanguage(0x0409, 0xF0020409).Count,
        "Keyboard variants are distinguished from the default layout", failures)
    japaneseKey := "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\CTF\TIP\{03B5835F-F03C-411B-9CE2-AA23E1171E36}"
        . "\LanguageProfile\0x00000411\{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}"
    systemJapanese := profiles.ReadResourceName(RegRead(japaneseKey, "Display Description", ""))
    AssertTest((systemJapanese = "" || profiles.DisplayName(japaneseId) = systemJapanese)
        && !profiles.ResolveProfileForLanguage(0x0411, 0xE0210411).Count,
        "Japanese IME uses the localized system name and does not match unrelated legacy layouts", failures)
    ; Same system name in two language groups must create two distinct items.
    catalog[StrLower(legacyId)]["description"] := profiles.DisplayName(japaneseId)
    profiles.ByLanguage["0804"].Push(profiles.ParseProfile(tipId),
        profiles.ParseProfile("0804:{11111111-1111-1111-1111-111111111111}{22222222-2222-2222-2222-222222222222}"))
    AssertTest(!profiles.ResolveProfileForLanguage(0x0804, 0x08040804).Count
        && profiles.ResolveProfileForLanguage(0x0804, 0xE0200804)["id"] = legacyId,
        "Chinese TIPs are not guessed while an exact legacy IME is recognized", failures)

    config.Reload()
    selection := config.DefaultState
    added := config.ReconcileDiscoveredStates(catalog, false)
    AssertTest(added["added"] = 6 && !added["authoritative"] && config.DefaultState = selection
        && config.NamedStates.Has("wetype-chinese"), "Partial discovery adds choices without deleting existing settings", failures)
    config.ReconcileDiscoveredStates(catalog)
    selectedName := "auto-" StrLower(Fnv1a32(StrLower(legacyId))) "-english"
    tray := TrayMenuController({Profiles: profiles, Config: config})
    choices := Menu()
    try tray.AddInputChoices(choices, selectedName, (*) => 0)
    finally tray.Dispose()
    selectedChoice := ""
    choose := (name, *) => selectedChoice := name
    ObjBindMethod(choose, "Call", selectedName)("ignored", 1, choices)
    AssertTest(selectedChoice = selectedName, "Menu callback binds the selected input state", failures)
    usMenu := DllCall("user32\GetSubMenu", "Ptr", choices.Handle, "Int", 1, "Ptr")
    japaneseMenu := DllCall("user32\GetSubMenu", "Ptr", choices.Handle, "Int", 4, "Ptr")
    wubiMenu := DllCall("user32\GetSubMenu", "Ptr", choices.Handle, "Int", 7, "Ptr")
    for separator in [2, 5] {
        flags := DllCall("user32\GetMenuState", "Ptr", choices.Handle, "UInt", separator, "UInt", 0x400, "UInt")
        AssertTest((flags & 0x860) = 0x800, "Language groups use horizontal menu separators", failures)
    }
    for heading in [0, 3, 6] {
        flags := DllCall("user32\GetMenuState", "Ptr", choices.Handle, "UInt", heading, "UInt", 0x400, "UInt")
        AssertTest((flags & 0x63) = 0x03, "Language headings are disabled and stay in one column", failures)
    }
    AssertTest(!usMenu && wubiMenu && japaneseMenu
        && DllCall("user32\GetMenuItemCount", "Ptr", wubiMenu, "Int") = 3
        && (DllCall("user32\GetMenuState", "Ptr", choices.Handle, "UInt", 7, "UInt", 0x400, "UInt") & 0x8)
        && !(DllCall("user32\GetMenuState", "Ptr", choices.Handle, "UInt", 4, "UInt", 0x400, "UInt") & 0x8)
        && (DllCall("user32\GetMenuState", "Ptr", wubiMenu, "UInt", 1, "UInt", 0x400, "UInt") & 0x8),
        "Tray checks only the selected input source and mode", failures)
    menuProbe := InputRestorationProbe(config, profiles.Logger, Map())
    menuProbe.Profiles := profiles
    menuProbe.Rules := RuleEngine(config, profiles.Logger)
    menuProbe.Startup := {IsEnabled: (*) => false}
    menuWindow := Map("hwnd", 100, "exe", "probe.exe", "mode", "window", "identityKey", "probe")
    tray := TrayMenuController(menuProbe)
    try {
        tray.Build({window: menuWindow, actual: Map("profile", usId), desired: Map(), rule: Map(), cached: false})
        AssertTest(DllCall("user32\GetMenuItemCount", "Ptr", A_TrayMenu.Handle, "Int") > 10,
            "Tray builds the complete native menu from a captured target", failures)
    } finally {
        A_TrayMenu.Delete()
        tray.Dispose()
    }
    AssertTest(InputRestoration.HasKnownModeMismatch(Map("kind", "ime", "imeOpen", "1"), Map("imeOpen", "0"))
        && !InputRestoration.HasKnownModeMismatch(Map("kind", "ime", "imeOpen", "unknown"), Map("imeOpen", "0")),
        "Legacy mode restoration writes only known differences", failures)
}

TestInputChangeKeys(failures) {
    eventGui := Gui()
    keys := InputChangeKeys(eventGui.Hwnd, (*) => 0)
    try {
        AssertTest(keys.SetEnabled(true) && keys.Registered, "Register native keyboard notifications", failures)
        AssertTest(keys.SetEnabled(false) && !keys.Registered, "Unregister keyboard notifications", failures)
    } finally {
        keys.SetEnabled(false)
        eventGui.Destroy()
    }
    keys.IsSwitchGesture(0x5B, false)
    keys.IsSwitchGesture(0x20, false)
    AssertTest(keys.IsSwitchGesture(0x20, true) && keys.IsSwitchGesture(0x5B, true),
        "Win+Space schedules checks on release", failures)

    keys.IsSwitchGesture(0x10, false)
    keys.IsSwitchGesture(0x41, false)
    keys.IsSwitchGesture(0x41, true)
    AssertTest(!keys.IsSwitchGesture(0x10, true), "Typing with Shift does not trigger a check", failures)

    keys.IsSwitchGesture(0x10, false)
    AssertTest(keys.IsSwitchGesture(0x10, true), "Standalone Shift supplies an IME mode hint", failures)
    keys.IsSwitchGesture(0x11, false)
    keys.IsSwitchGesture(0x10, false)
    AssertTest(keys.IsSwitchGesture(0x11, true) && !keys.IsSwitchGesture(0x10, true),
        "Ctrl+Shift signals once on release", failures)

    keys.IsSwitchGesture(0x12, false)
    keys.IsSwitchGesture(0x10, false)
    keys.IsSwitchGesture(0x54, false)
    AssertTest(!keys.IsSwitchGesture(0x10, true), "An unrelated modifier shortcut does not trigger a check", failures)
    keys.Reset()

    keys.IsSwitchGesture(0x12, false)
    keys.IsSwitchGesture(0x10, false)
    AssertTest(keys.IsSwitchGesture(0x10, true), "Alt+Shift supplies a layout hint", failures)
}

TestInputRestoration(config, logger, failures) {
    Critical "On"
    try {
        chinese := Map("profile", "0804:test", "kind", "tip", "imeOpen", "1", "focusHwnd", 101)
        englishMode := StateClone(chinese)
        englishMode["imeOpen"] := "0"
        englishLayout := Map("profile", "0409:00000409", "kind", "keyboard", "source", "rule")

        delayedFocus := StateClone(chinese)
        delayedFocus["focused"] := false
        app := InputRestorationProbe(config, logger, delayedFocus)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        app.Restore.Pending.focusReadyUntil := TickCount64() - 1
        app.Restore.Advance(true)
        AssertTest(app.Restore.Pending && !app.LayoutRequests && !app.StateReads,
            "Unfocused startup waits for a real focus notification after timed checks end", failures)
        app.Actual := chinese
        app.Restore.Advance(true)
        AssertTest(app.LayoutRequests = 1 && app.LastWriteFocus = 101,
            "The first ready focus receives the pending startup request", failures)
        app.Restore.Cancel()

        app := InputRestorationProbe(config, logger, chinese)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        app.ExpireRestoreCheck()
        app.ObserveCurrentWindow()
        app.ObserveCurrentWindow()
        AssertTest(!app.Restore.Pending && MapGet(app.ObservationState, "profile", "") = chinese["profile"]
            && app.LayoutRequests = 1 && !app.SessionStates.Count && !app.Saved.Count,
            "Failed rule uses actual state as a baseline without learning it", failures)

        app.Actual := StateClone(chinese)
        app.Actual["imeOpen"] := "unknown"
        app.ObserveCurrentWindow()
        app.ObserveCurrentWindow()
        AssertTest(MapGet(app.ObservationState, "imeOpen", "") = "1" && !app.Saved.Count,
            "Unreadable IME mode does not replace the last known mode", failures)

        app.Actual := englishMode
        app.ObserveCurrentWindow()
        AssertTest(!app.Saved.Count, "First changed sample is not persisted", failures)
        app.CandidateSince := TickCount64() - 60
        app.ConfirmObservation()
        AssertTest(MapGet(app.Saved, "imeOpen", "") = "0",
            "Stable manual change after a failed restore is learned", failures)

        app.Actual := StateClone(englishLayout)
        app.Actual["focusHwnd"] := 101
        app.ApplyState(app.CurrentWindow, app.Saved, "restore", true)
        app.Restore.Pending.retried := true
        app.ExpireRestoreCheck()
        app.ObserveCurrentWindow()
        app.ObserveCurrentWindow()
        AssertTest(MapGet(app.Saved, "profile", "") = englishMode["profile"]
            && MapGet(app.SessionStates["100"], "imeOpen", "") = "0",
            "Failed restore preserves previously learned state", failures)

        app := InputRestorationProbe(config, logger, chinese)
        app.ApplyState(app.CurrentWindow, englishMode)
        app.ApplyState(app.CurrentWindow, chinese, "window-default", true)
        app.Restore.Advance()
        AssertTest(!app.Restore.Pending && !app.ModeWrites && !app.LayoutRequests,
            "Matching selection cancels stale work without switching", failures)

        app := InputRestorationProbe(config, logger, chinese)
        remembered := StateClone(englishMode)
        remembered["source"] := "learned"
        app.ApplyState(app.CurrentWindow, remembered, "restore", true)
        app.ExpireRestoreCheck()
        AssertTest(app.ModeWrites = 2 && !app.LayoutRequests,
            "Mode-only retry never posts an input source switch", failures)
        app.Restore.Cancel()

        app := InputRestorationProbe(config, logger, chinese)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        app.Actual := StateClone(chinese)
        app.Actual["focusHwnd"] := 102
        app.Restore.Advance(true)
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 1 && !app.ModeWrites,
            "Restoration does not follow a change between editing controls", failures)

        hostChinese := StateClone(chinese)
        hostChinese["focusHwnd"] := 100
        app := InputRestorationProbe(config, logger, hostChinese)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        app.Actual := StateClone(englishLayout)
        app.Actual["focusHwnd"] := 100
        app.Restore.Advance()
        AssertTest(app.Restore.Pending && app.LayoutRequests = 1,
            "A verified host waits for an editing control during activation", failures)
        app.Actual := StateClone(chinese)
        app.Actual["focusThreadId"] := 2
        app.Restore.Advance(true)
        AssertTest(app.Restore.Pending && app.LayoutRequests = 2 && app.LastWriteFocus = 101,
            "A late editing control in the same window gets one new restore request", failures)
        app.Actual["focusHwnd"] := 102
        app.Restore.Advance(true)
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 2 && !app.Saved.Count,
            "After the host handoff restoration does not follow further focus changes", failures)

        app := InputRestorationProbe(config, logger, hostChinese)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        app.Actual := StateClone(englishLayout)
        app.Actual["focusHwnd"] := 101
        app.Restore.Advance(true)
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 1,
            "An already-correct late focus is never written again", failures)

        app := InputRestorationProbe(config, logger, hostChinese)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        app.Restore.Pending.focusUntil := TickCount64() - 1
        app.Actual := StateClone(chinese)
        app.Restore.Advance(true)
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 1,
            "A control that focuses after activation is left alone", failures)

        host := StateClone(englishLayout)
        host["focusHwnd"] := 100
        app := InputRestorationProbe(config, logger, host)
        app.ApplyState(app.CurrentWindow, englishLayout, "default", true)
        AssertTest(app.Restore.Pending && !app.LayoutRequests,
            "Matching host can await an incoming search-field focus", failures)
        app.Actual := StateClone(chinese)
        app.Actual["focusHwnd"] := 100
        app.Restore.Pending.settleUntil := TickCount64() - 1
        app.Restore.Advance()
        AssertTest(app.Restore.Pending && !app.LayoutRequests,
            "A changed host waits for late child focus without sending a switch", failures)
        app.Actual["focusHwnd"] := 101
        app.Restore.Advance(true)
        AssertTest(app.LayoutRequests = 1 && app.LastWriteFocus = 101,
            "Search-field focus advances the pending restore to the actual control", failures)
        app.Actual := StateClone(englishLayout)
        app.Actual["focusHwnd"] := 101
        app.Restore.Advance()
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 1,
            "A matching field completes the restore with a single layout request", failures)

        app := InputRestorationProbe(config, logger, host)
        app.ApplyState(app.CurrentWindow, englishMode, "default", true)
        app.Actual := StateClone(chinese)
        app.Actual["focusHwnd"] := 100
        app.Actual["imeOpen"] := "unknown"
        app.Restore.Advance(true)
        AssertTest(app.LayoutRequests = 1 && !app.ModeWrites,
            "A profile can arrive before its internal mode is readable", failures)
        app.Actual["imeOpen"] := "1"
        app.Restore.Advance()
        AssertTest(app.LayoutRequests = 1 && app.ModeWrites = 1,
            "Readable mode advances the second stage without reposting the layout", failures)
        app.Restore.Cancel()

        app := InputRestorationProbe(config, logger, chinese)
        target := StateClone(englishLayout)
        target["source"] := "learned"
        app.ApplyState(app.CurrentWindow, target, "restore", true)
        app.Actual := Map("profile", "0411:00000411", "kind", "keyboard", "focusHwnd", 101)
        app.ExpireRestoreCheck()
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 1
            && app.ObservationState["profile"] = "0411:00000411" && !app.Saved.Count,
            "An unexpected input source without a gesture ends restoration and is not learned", failures)

        app := InputRestorationProbe(config, logger, chinese)
        app.ApplyState(app.CurrentWindow, target, "restore", true)
        app.Restore.NoteInputGesture(app.CurrentWindow)
        app.Restore.Advance()
        AssertTest(app.Restore.Pending && app.LayoutRequests = 1 && !app.Saved.Count,
            "A shortcut hint waits for a change without posting another request", failures)
        app.Actual := Map("profile", "0411:00000411", "kind", "keyboard", "focusHwnd", 101)
        app.Restore.Advance()
        AssertTest(!app.Restore.Pending && !app.Saved.Count && app.CandidateSignature != "",
            "A different input source after a shortcut enters normal confirmation", failures)
        app.CandidateSince := TickCount64() - 60
        app.ConfirmObservation()
        AssertTest(MapGet(app.Saved, "profile", "") = "0411:00000411" && app.LayoutRequests = 1,
            "A confirmed manual selection during restoration is learned without another switch", failures)

        app := InputRestorationProbe(config, logger, chinese)
        app.ApplyState(app.CurrentWindow, target, "restore", true)
        app.Restore.NoteInputGesture(app.CurrentWindow)
        app.Actual := StateClone(englishLayout)
        app.Actual["focusHwnd"] := 101
        app.Restore.Pending.gesture.until := TickCount64() - 1
        app.Restore.Advance()
        AssertTest(!app.Restore.Pending && !app.Saved.Count && app.CandidateSignature = "",
            "An automatic request reaching its target after a shortcut is not learned", failures)
    } finally {
        Critical "Off"
    }
}

AssertTest(condition, name, failures) {
    if !condition
        failures.Push(name)
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

TestAppInputPolicy(config, logger, failures) {
    originalAutoMemory := config.AutoMemory
    originalPolicies := config.AppInputPolicies
    originalSwitch := config.Enabled
    config.AppInputPolicies := Map("probe.exe", Map("autoMemory", "0", "force", true))
    config.Enabled := true
    config.AutoMemory := true
    try {
        actual := Map("profile", "0804:probe", "kind", "tip", "imeOpen", "1", "focusHwnd", 101)
        remembered := Map("profile", "0409:00000409", "kind", "keyboard", "source", "learned")
        rule := Map("state", Map("profile", "0411:00000411"))
        app := InputRestorationProbe(config, logger, actual)
        app.Saved := remembered
        app.SessionStates["100"] := remembered
        desired := app.SelectDesiredState(app.CurrentWindow, rule)
        AssertTest(!app.CanRemember(app.CurrentWindow) && desired["profile"] = "0411:00000411"
            && !app.StoreReads && app.Saved = remembered,
            "An excluded app skips automatic memory reads and uses its rule", failures)
        AssertTest(!app.SelectDesiredState(app.CurrentWindow, Map()).Count,
            "An excluded app without a rule has no automatic target", failures)

        config.AppInputPolicies["probe.exe"]["autoMemory"] := "inherit"
        freshWindow := Map("hwnd", 200, "exe", "fresh.exe")
        app.Saved := Map()
        initial := app.SelectDesiredState(freshWindow, Map(), true)
        app.Saved := remembered
        AssertTest(initial["profile"] = app.SelectDesiredState(freshWindow, Map())["profile"],
            "A second window learning does not change an existing window's fallback", failures)
        desired := app.SelectDesiredState(app.CurrentWindow, rule)
        app.SetEnforcedTarget(app.CurrentWindow, desired)
        AssertTest(app.Enforcement.Target["profile"] = remembered["profile"],
            "Enforcement picks the remembered input for an app that still uses memory", failures)
        app.ObserveCurrentWindow()
        AssertTest(app.LayoutRequests = 1 && app.Saved = remembered && app.Restore.Pending.reason = "enforce",
            "Observed drift is corrected and does not replace the saved preference", failures)
        app.ExpireRestoreCheck()
        app.ObserveCurrentWindow()
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 1 && app.Enforcement.Failures = 1,
            "A refused forced correction enters backoff without another request", failures)

        app.Actual := StateClone(remembered)
        app.Actual["focusHwnd"] := 101
        app.ObserveCurrentWindow()
        AssertTest(!app.Enforcement.Failures && app.LayoutRequests = 1,
            "A matched target clears backoff without writing", failures)
        app.Actual := actual
        config.AutoMemory := false
        desired := app.SelectDesiredState(app.CurrentWindow, rule)
        app.SetEnforcedTarget(app.CurrentWindow, desired)
        app.ObserveCurrentWindow()
        AssertTest(app.LayoutRequests = 2 && app.Enforcement.Target["profile"] = "0411:00000411",
            "An explicit rule can be forced even with global memory off", failures)
        app.Restore.Cancel()

        config.AppInputPolicies["probe.exe"]["autoMemory"] := "1"
        config.AppInputPolicies["probe.exe"]["autoSwitch"] := "0"
        app.SetEnforcedTarget(app.CurrentWindow, desired)
        AssertTest(app.CanRemember(app.CurrentWindow) && !app.CanSwitch(app.CurrentWindow)
            && !app.Enforcement.Target.Count, "Per-app switch off keeps learning and suspends enforcement", failures)
        app.ApplyState(app.CurrentWindow, desired, "restore", true)
        AssertTest(!app.Restore.Pending && app.LayoutRequests = 2,
            "An explicit switch-off override prevents restoration writes", failures)
        config.Enabled := false
        config.AppInputPolicies["probe.exe"]["autoSwitch"] := "1"
        AssertTest(app.CanSwitch(app.CurrentWindow) && !app.CanSwitch(freshWindow),
            "Per-app switch on takes precedence over the global off setting", failures)

        app.Enforcement.SetTarget("probe.exe", actual)
        AssertTest(!app.Enforcement.ShouldRestore(Map("profile", "0804:unknown"), 1000)
            && !app.Enforcement.ShouldRestore(Map("profile", "0804:probe", "kind", "tip"), 1000)
            && !app.Enforcement.ShouldRestore(Map("profile", "0804:probe", "kind", "tip",
                "imeOpen", "1", "conversion", "0x8"), 1000)
            && app.Enforcement.ShouldRestore(Map("profile", "0804:probe", "kind", "tip", "imeOpen", "0"), 1000),
            "Force mode acts on known source and open-mode differences only", failures)
    } finally {
        config.AutoMemory := originalAutoMemory
        config.AppInputPolicies := originalPolicies
        config.Enabled := originalSwitch
    }
}

TestKeyboardPoll(config, logger, failures) {
    threadId := DllCall("kernel32\GetCurrentThreadId", "UInt")
    hkl := InputProfiles.GetThreadLayout(threadId)
    actual := Map("profile", "0409:00000409", "kind", "keyboard", "hkl", "0x" Hex(hkl),
        "focusHwnd", 101, "focusThreadId", threadId)
    app := InputRestorationProbe(config, logger, actual)
    app.Enforcement.SetTarget("probe.exe", actual)
    app.ObserveCurrentWindow(true)
    app.ObserveCurrentWindow(true)
    AssertTest(app.StateReads = 1 && app.VerifiedKeyboard && !app.LayoutRequests,
        "Stable enforced keyboard skips full reads on timer ticks", failures)

    app.ObserveCurrentWindow()
    app.Revision += 1
    app.ObserveCurrentWindow(true)
    app.Actual["focusHwnd"] := 102
    app.ObserveCurrentWindow(true)
    app.VerifiedKeyboard.hkl := 0
    app.ObserveCurrentWindow(true)
    AssertTest(app.StateReads = 5 && !app.LayoutRequests,
        "Input events and layout, focus or catalog changes use full reads", failures)

    app.Enforcement.SetTarget("probe.exe", Map())
    app.ObserveCurrentWindow(true)
    app.ObserveCurrentWindow(true)
    AssertTest(app.StateReads = 6 && app.VerifiedKeyboard && app.ObservationState.Count && !app.LayoutRequests,
        "The lightweight timer path also applies to automatic memory", failures)

    app.CandidateSignature := "pending-change"
    app.ObserveCurrentWindow(true)
    AssertTest(app.StateReads = 7, "An unconfirmed observation still triggers a full read", failures)
}

class ImeModeNoOpProbe extends ImeMode {
    __New() {
        this.SetCalls := 0
        this.Config := {MessageTimeoutMs: 120}
    }

    GetImeWindow(windowInfo, focus := unset) {
        return 1
    }

    Control(imeWindow, command, value, timeoutMs := 0) {
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

class InputRestorationProbe extends KeyPersonaApp {
    __New(config, logger, actual) {
        this.Config := config
        this.Logger := logger
        this.ShuttingDown := false
        this.ObserveOnly := false
        this.PollPeriod := config.IdlePollMs
        this.Actual := actual
        this.CurrentWindow := Map("hwnd", 100, "exe", "probe.exe")
        this.SessionStates := Map()
        this.ObservationState := Map()
        this.VerifiedKeyboard := 0
        this.CandidateSignature := ""
        this.Restore := InputRestorationClockProbe(this)
        this.Enforcement := InputEnforcement()
        this.LayoutRequests := 0
        this.ModeWrites := 0
        this.LastWriteFocus := 0
        this.Saved := Map()
        this.StoreReads := 0
        this.StateReads := 0
        this.Revision := 1
        this.Tray := this
        this.Store := this
        this.Profiles := this
        this.Mode := this
        this.Identity := this
    }

    GetForegroundFocus(windowInfo) {
        return Map("hwnd", this.Actual["focusHwnd"], "threadId", MapGet(this.Actual, "focusThreadId", 1),
            "focused", MapGet(this.Actual, "focused", true))
    }

    ReadState(windowInfo, focus := unset, enforcedTarget := unset, desiredState := unset) {
        this.StateReads += 1
        if IsSet(focus) && focus["hwnd"] != this.Actual["focusHwnd"]
            return Map()
        return StateClone(this.Actual)
    }

    CanVerifyKeyboardWithLayout(actual) {
        return actual["kind"] = "keyboard"
    }

    MatchRule(windowInfo) {
        return Map()
    }

    Find(windowInfo) {
        this.StoreReads += 1
        return StateClone(this.Saved)
    }

    Switch(windowInfo, desired, focus, canWrite) {
        this.LayoutRequests += 1
        this.LastWriteFocus := focus["hwnd"]
        return true
    }

    Apply(windowInfo, desired, focus, canWrite) {
        this.ModeWrites += 1
        return true
    }

    Upsert(windowInfo, state, source) {
        this.Saved := StateClone(state)
        return true
    }

    ScheduleFlush() {
    }

    ScheduleObservationCheck(delay) {
    }

    ExpireRestoreCheck() {
        this.Restore.Pending.checkUntil := TickCount64() - 1
        this.Restore.Advance()
    }
}

class InputRestorationClockProbe extends InputRestoration {
    ScheduleCheck(delay) {
    }
}
