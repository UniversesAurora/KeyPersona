#Requires AutoHotkey v2.0

class InputProfiles {
    static CLSID_MANAGER := "{33C53A50-F456-4884-B049-85FD643ECFED}"
    static IID_MANAGER := "{71C6E74C-0F28-11D8-A82A-00065B84435C}"
    static IID_DESCRIPTIONS := "{1F02B6C5-7842-4EE6-8A0B-9A24183A95CA}"
    static CATEGORY_KEYBOARD := "{34745C63-B2F0-4784-8B67-5E12C8701A31}"
    static ENABLED_PROFILE_SIZE := 584 ; LAYOUTORTIPPROFILE

    __New(identity, config, logger) {
        this.Identity := identity
        this.Config := config
        this.Logger := logger
        this.Catalog := Map()
        this.ByLanguage := Map()
        this.Revision := 0
        this.LastCatalogRefreshTick := 0
        this.LastRefreshSucceeded := false
        this.Manager := ""
        this.Descriptions := ""
        try this.Manager := ComObject(InputProfiles.CLSID_MANAGER, InputProfiles.IID_MANAGER)
        catch Error as err
            this.Logger.Warn("TSF profile manager unavailable: " err.Message)
        try this.Descriptions := ComObject(InputProfiles.CLSID_MANAGER, InputProfiles.IID_DESCRIPTIONS)
        this.RefreshCatalog()
    }

    RefreshCatalog() {
        this.LastCatalogRefreshTick := TickCount64()
        try catalog := this.ReadEnabledProfiles()
        catch Error as err {
            this.LastRefreshSucceeded := false
            this.Logger.Warn("Input profile discovery failed: " err.Message)
            if !this.Catalog.Count {
                try {
                    fallback := this.ReadLanguageSettings()
                    this.AddPreloadedImes(fallback)
                    this.SetCatalog(fallback)
                }
            }
            return
        }
        this.LastRefreshSucceeded := true
        this.SetCatalog(catalog)
    }

    SetCatalog(catalog) {
        byLanguage := Map()
        for profileId, profile in catalog {
            langKey := Hex(profile["langId"], 4)
            if !byLanguage.Has(langKey)
                byLanguage[langKey] := []
            byLanguage[langKey].Push(profile)
        }
        this.Catalog := catalog
        this.ByLanguage := byLanguage
        this.Revision += 1
        this.Logger.Info("Discovered " catalog.Count " enabled input profile(s)")
    }

    ReadEnabledProfiles() {
        enumerate := A_WinDir "\System32\input.dll\EnumEnabledLayoutOrTip"
        count := DllCall(enumerate, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt", 0, "UInt")
        if !count
            throw Error("Windows returned an empty input profile list")
        profileBytes := Buffer(count * InputProfiles.ENABLED_PROFILE_SIZE, 0)
        written := DllCall(enumerate, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", profileBytes, "UInt", count, "UInt")
        if (written != count
            || DllCall(enumerate, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt", 0, "UInt") != count)
            throw Error("Windows input profile list changed during discovery")
        catalog := this.ParseEnabledProfiles(profileBytes, written)
        this.AddPreloadedImes(catalog)
        if !catalog.Count
            throw Error("Windows returned no enabled keyboard input profiles")
        return catalog
    }

    ParseEnabledProfiles(profileBytes, count) {
        catalog := Map()
        Loop count {
            row := (A_Index - 1) * InputProfiles.ENABLED_PROFILE_SIZE
            if NumGet(profileBytes, row + 60, "UInt") & 0x2 ; LOT_DISABLED
                continue
            profileType := NumGet(profileBytes, row, "UInt")
            if (profileType = 1 && GuidString(profileBytes.Ptr + row + 40) != InputProfiles.CATEGORY_KEYBOARD)
                continue
            id := StrGet(profileBytes.Ptr + row + 64, 260, "UTF-16")
            if (profileType = 2 && !InStr(id, ":"))
                id := Hex(NumGet(profileBytes, row + 4, "UShort"), 4) ":" id
            profile := this.ParseProfile(id)
            if (!profile.Count || (profileType = 1) != (profile["kind"] = "tip") || (profileType != 1 && profileType != 2))
                throw Error("Windows returned an unrecognized keyboard input profile")
            this.DescribeProfile(profile)
            catalog[StrLower(profile["id"])] := profile
        }
        return catalog
    }

    ReadLanguageSettings() {
        catalog := Map()
        root := "HKEY_CURRENT_USER\Control Panel\International\User Profile"
        Loop Reg root, "K" {
            languageKey := root "\" A_LoopRegName
            Loop Reg languageKey, "V" {
                profile := this.ParseProfile(A_LoopRegName)
                if !profile.Count || !RegRead(languageKey, A_LoopRegName, 0)
                    continue
                this.DescribeProfile(profile)
                catalog[StrLower(profile["id"])] := profile
            }
        }
        return catalog
    }

    AddPreloadedImes(catalog) {
        preload := "HKEY_CURRENT_USER\Keyboard Layout\Preload"
        substitutes := "HKEY_CURRENT_USER\Keyboard Layout\Substitutes"
        Loop Reg preload, "V" {
            inputId := RegRead(preload, A_LoopRegName, "")
            if !RegExMatch(inputId, "i)^[0-9a-f]{8}$")
                continue
            layoutId := RegRead(substitutes, inputId, inputId)
            if !RegExMatch(layoutId, "i)^e[0-9a-f]{7}$")
                continue
            profile := this.ParseProfile(SubStr(inputId, -4) ":" layoutId)
            key := StrLower(profile["id"])
            if catalog.Has(key)
                continue
            this.DescribeProfile(profile)
            if (profile["description"] != profile["layoutId"])
                catalog[key] := profile
        }
    }

    ParseProfile(profileId) {
        if !RegExMatch(profileId, "i)^([0-9a-f]{4}):(.+)$", &match)
            return Map()
        langId := Integer("0x" match[1])
        tail := match[2]
        if RegExMatch(tail, "i)^([0-9a-f]{8})$") {
            return Map(
                "id", StrUpper(match[1]) ":" StrUpper(tail),
                "kind", SubStr(StrUpper(tail), 1, 1) = "E" ? "ime" : "keyboard",
                "langId", langId,
                "layoutId", StrUpper(tail),
                "clsid", "{00000000-0000-0000-0000-000000000000}",
                "profileGuid", "{00000000-0000-0000-0000-000000000000}"
            )
        }
        if RegExMatch(tail, "i)^(\{[0-9a-f-]{36}\})(\{[0-9a-f-]{36}\})$", &tip) {
            return Map(
                "id", StrUpper(match[1]) ":" StrUpper(tip[1]) StrUpper(tip[2]),
                "kind", "tip",
                "langId", langId,
                "layoutId", "0000" StrUpper(match[1]),
                "clsid", StrUpper(tip[1]),
                "profileGuid", StrUpper(tip[2])
            )
        }
        return Map()
    }

    DescribeProfile(profile) {
        if (profile["kind"] = "tip") {
            profile["description"] := this.ReadTipName(profile)
            return
        }
        key := "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\" profile["layoutId"]
        layoutName := this.ReadResourceName(RegRead(key, "Layout Display Name", ""))
        if (layoutName = "")
            layoutName := this.ReadResourceName(RegRead(key, "Layout Text", ""))
        if (RegRead(key, "Ime File", "") != "")
            profile["kind"] := "ime"
        layoutCode := RegRead(key, "Layout Id", "")
        if RegExMatch(layoutCode, "i)^[0-9a-f]{4}$")
            profile["layoutCode"] := Integer("0x" layoutCode)
        profile["description"] := layoutName != "" ? layoutName : profile["layoutId"]
    }

    ReadTipName(profile) {
        key := "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\CTF\TIP\" profile["clsid"]
            . "\LanguageProfile\0x0000" Hex(profile["langId"], 4) "\" profile["profileGuid"]
        name := this.ReadResourceName(RegRead(key, "Display Description", ""))
        if (name != "")
            return name
        if IsObject(this.Descriptions) {
            descriptionPtr := 0
            try {
                clsid := GuidBuffer(profile["clsid"])
                profileGuid := GuidBuffer(profile["profileGuid"])
                ComCall(12, this.Descriptions, "Ptr", clsid, "UShort", profile["langId"],
                    "Ptr", profileGuid, "Ptr*", &descriptionPtr)
                if descriptionPtr
                    name := this.ReadResourceName(StrGet(descriptionPtr, "UTF-16"))
            } catch Error {
                ; Some older TIPs supply only a registry description.
            } finally {
                if descriptionPtr
                    DllCall("oleaut32\SysFreeString", "Ptr", descriptionPtr)
            }
        }
        if (name = "")
            name := this.ReadResourceName(RegRead(key, "Description", ""))
        return name != "" ? name : profile["id"]
    }

    ReadResourceName(value) {
        if (SubStr(value, 1, 1) != "@")
            return value
        chars := Buffer(2048, 0)
        return DllCall("shlwapi\SHLoadIndirectString", "WStr", value, "Ptr", chars, "UInt", 1024, "Ptr", 0, "Int") = 0
            ? StrGet(chars, "UTF-16") : ""
    }

    static LanguageId(profileId) {
        return RegExMatch(profileId, "i)^([0-9a-f]{4}):", &language) ? Integer("0x" language[1]) : 0
    }

    static LanguageDisplayName(langId) {
        if !langId
            return ""
        locale := Buffer(170, 0) ; LOCALE_NAME_MAX_LENGTH UTF-16 characters.
        if !DllCall("kernel32\LCIDToLocaleName", "UInt", langId, "Ptr", locale, "Int", 85, "UInt", 0, "Int")
            return ""
        chars := Buffer(512, 0)
        length := DllCall("kernel32\GetLocaleInfoEx", "Ptr", locale, "UInt", 0x2, ; LOCALE_SLOCALIZEDDISPLAYNAME
            "Ptr", chars, "Int", 256, "Int")
        return length ? StrGet(chars, "UTF-16") : StrGet(locale, "UTF-16")
    }

    Read(windowInfo, focus := unset) {
        if !IsSet(focus)
            focus := this.Identity.GetFocusTarget(windowInfo)
        threadId := focus["threadId"]
        hkl := threadId ? DllCall("user32\GetKeyboardLayout", "UInt", threadId, "Ptr") : 0
        langId := hkl & 0xFFFF
        profile := this.ResolveProfileForLanguage(langId, hkl)
        catalogKey := profile.Count ? StrLower(profile["id"]) : ""
        if ((!profile.Count || !this.Catalog.Has(catalogKey))
            && TickCount64() - this.LastCatalogRefreshTick >= 30000) {
            this.RefreshCatalog()
            profile := this.ResolveProfileForLanguage(langId, hkl)
        }
        return Map(
            "profile", profile.Count ? profile["id"] : Hex(langId, 4) ":unknown",
            "kind", profile.Count ? profile["kind"] : "unknown",
            "langId", Hex(langId, 4),
            "hkl", "0x" Hex(hkl)
        )
    }

    ResolveProfileForLanguage(langId, hkl) {
        langKey := Hex(langId, 4)
        candidates := MapGet(this.ByLanguage, langKey, [])
        keyboard := Map()
        for candidate in candidates {
            if (candidate["kind"] = "tip" || !InputProfiles.MatchesKeyboardLayout(candidate, hkl))
                continue
            if (candidate["kind"] = "ime")
                return candidate
            if keyboard.Count {
                keyboard := Map()
                break
            }
            keyboard := candidate
        }
        active := this.GetActiveProfile()
        legacyHandle := (hkl & 0xF0000000) = 0xE0000000
        if (active.Count && active["langId"] = langId) {
            substitute := active["substituteHkl"]
            if (substitute ? substitute = hkl : !legacyHandle)
                return MapGet(this.Catalog, StrLower(active["id"]), active)
        }
        if keyboard.Count
            return keyboard
        ; A single TIP can use the language's plain carrier HKL.
        if (candidates.Length = 1 && candidates[1]["kind"] = "tip"
            && InputProfiles.KeyboardLayoutId(hkl) = "0000" langKey)
            return candidates[1]
        return Map()
    }

    GetActiveProfile() {
        if !IsObject(this.Manager)
            return Map()
        category := GuidBuffer(InputProfiles.CATEGORY_KEYBOARD)
        profileBytes := Buffer(A_PtrSize = 8 ? 88 : 72, 0)
        try hr := ComCall(10, this.Manager, "Ptr", category, "Ptr", profileBytes, "Int")
        catch
            return Map()
        if (hr != 0 || NumGet(profileBytes, 0, "UInt") != 1)
            return Map()
        langId := NumGet(profileBytes, 4, "UShort")
        clsid := GuidString(profileBytes.Ptr + 8)
        profileGuid := GuidString(profileBytes.Ptr + 24)
        return Map(
            "id", Hex(langId, 4) ":" StrUpper(clsid) StrUpper(profileGuid),
            "kind", "tip", "langId", langId,
            "substituteHkl", NumGet(profileBytes, 56, "Ptr")
        )
    }

    static KeyboardLayoutId(hkl) {
        layout := hkl & 0xFFFFFFFF
        if (layout >> 16) = (layout & 0xFFFF)
            layout &= 0xFFFF
        return Hex(layout, 8)
    }

    static MatchesKeyboardLayout(profile, hkl) {
        if (!hkl || (hkl & 0xFFFF) != profile["langId"])
            return false
        layoutId := profile["layoutId"]
        if (InputProfiles.KeyboardLayoutId(hkl) = layoutId)
            return true
        device := (hkl >> 16) & 0xFFFF
        if ((device & 0xF000) = 0xF000)
            return device = (0xF000 | MapGet(profile, "layoutCode", -1))
        return profile["kind"] = "keyboard" && layoutId = "0000" Hex(device, 4)
    }

    FindLoadedKeyboardLayout(profile) {
        count := DllCall("user32\GetKeyboardLayoutList", "Int", 0, "Ptr", 0, "Int")
        if !count
            return 0
        layouts := Buffer(count * A_PtrSize)
        written := DllCall("user32\GetKeyboardLayoutList", "Int", count, "Ptr", layouts, "Int")
        Loop written {
            hkl := NumGet(layouts, (A_Index - 1) * A_PtrSize, "Ptr")
            if InputProfiles.MatchesKeyboardLayout(profile, hkl)
                return hkl
        }
        return 0
    }

    Switch(windowInfo, desiredState, focus) {
        if !this.Identity.IsForegroundFocus(windowInfo, focus)
            return false
        profileId := MapGet(desiredState, "profile", "")
        profile := MapGet(this.Catalog, StrLower(profileId), Map())
        if !profile.Count {
            this.Logger.Warn("Cannot switch unknown profile '" profileId "'")
            return false
        }
        if (profile["kind"] = "tip")
            this.PrimeTsfProfile(profile)
        hkl := profile["kind"] = "tip" ? 0 : this.FindLoadedKeyboardLayout(profile)
        if !hkl
            hkl := DllCall("user32\LoadKeyboardLayoutW", "WStr", profile["layoutId"], "UInt", 0x2, "Ptr")
        if (!hkl || (hkl & 0xFFFF) != profile["langId"]
            || (profile["kind"] != "tip" && !InputProfiles.MatchesKeyboardLayout(profile, hkl))) {
            this.Logger.Warn("No matching keyboard layout handle for " profile["id"])
            return false
        }
        if !this.Identity.IsForegroundFocus(windowInfo, focus)
            return false
        target := focus["hwnd"]
        ok := DllCall("user32\PostMessageW", "Ptr", target, "UInt", 0x0050, "Ptr", 0, "Ptr", hkl, "Int")
        if !ok
            this.Logger.Warn("WM_INPUTLANGCHANGEREQUEST was blocked for " MapGet(windowInfo, "exe", "") " (" A_LastError ")")
        return !!ok
    }

    PrimeTsfProfile(profile) {
        if !IsObject(this.Manager)
            return false
        clsid := GuidBuffer(profile["clsid"])
        profileGuid := GuidBuffer(profile["profileGuid"])
        try {
            hr := ComCall(3, this.Manager,
                "UInt", 1,
                "UShort", profile["langId"],
                "Ptr", clsid,
                "Ptr", profileGuid,
                "Ptr", 0,
                "UInt", 0x4, ; TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE
                "Int")
            return hr = 0
        } catch Error as err {
            this.Logger.Debug("TSF profile priming failed: " err.Message)
            return false
        }
    }

    DisplayName(profileId, includeLanguage := false) {
        key := StrLower(profileId)
        if !this.Catalog.Has(key)
            return profileId
        profile := this.Catalog[key]
        name := profile["description"]
        language := includeLanguage ? InputProfiles.LanguageDisplayName(profile["langId"]) : ""
        return language = "" ? name : language " · " name
    }
}
