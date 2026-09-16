#Requires AutoHotkey v2.0

class InputProfiles {
    static CLSID_MANAGER := "{33C53A50-F456-4884-B049-85FD643ECFED}"
    static IID_MANAGER := "{71C6E74C-0F28-11D8-A82A-00065B84435C}"
    static CATEGORY_KEYBOARD := "{34745C63-B2F0-4784-8B67-5E12C8701A31}"

    __New(identity, config, logger) {
        this.Identity := identity
        this.Config := config
        this.Logger := logger
        this.Catalog := Map()
        this.ByLanguage := Map()
        this.Manager := ""
        try this.Manager := ComObject(InputProfiles.CLSID_MANAGER, InputProfiles.IID_MANAGER)
        catch Error as err
            this.Logger.Warn("TSF profile manager unavailable: " err.Message)
        this.RefreshCatalog()
    }

    RefreshCatalog() {
        this.Catalog := Map()
        this.ByLanguage := Map()
        root := "HKEY_CURRENT_USER\Control Panel\International\User Profile"
        try {
            Loop Reg root, "K" {
                languageKey := root "\" A_LoopRegName
                Loop Reg languageKey, "V" {
                    profileId := A_LoopRegName
                    if !RegExMatch(profileId, "i)^([0-9a-f]{4}):(.+)$", &match)
                        continue
                    try enabled := RegRead(languageKey, profileId, 0)
                    catch
                        enabled := 0
                    if !enabled
                        continue
                    profile := this.ParseProfile(profileId)
                    if !profile.Count
                        continue
                    profile["languageTag"] := SubStr(languageKey, InStr(languageKey, "\",, -1) + 1)
                    profile["description"] := this.ReadDescription(profile)
                    this.Catalog[StrLower(profileId)] := profile
                    langKey := Hex(profile["langId"], 4)
                    if !this.ByLanguage.Has(langKey)
                        this.ByLanguage[langKey] := []
                    this.ByLanguage[langKey].Push(profile)
                }
            }
        } catch Error as err {
            this.Logger.Warn("Input profile discovery failed: " err.Message)
        }
        this.Logger.Info("Discovered " this.Catalog.Count " enabled input profile(s)")
    }

    ParseProfile(profileId) {
        if !RegExMatch(profileId, "i)^([0-9a-f]{4}):(.+)$", &match)
            return Map()
        langId := Integer("0x" match[1])
        tail := match[2]
        if RegExMatch(tail, "i)^([0-9a-f]{8})$") {
            return Map(
                "id", StrUpper(match[1]) ":" StrUpper(tail),
                "kind", "keyboard",
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

    ReadDescription(profile) {
        if (profile["kind"] = "tip") {
            key := "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\CTF\TIP\" profile["clsid"]
                . "\LanguageProfile\0x0000" Hex(profile["langId"], 4) "\" profile["profileGuid"]
            try return RegRead(key, "Description", profile["id"])
        }
        if (profile["id"] = "0409:00000409")
            return "English (United States) - US"
        return profile["id"]
    }

    Read(windowInfo) {
        focus := this.Identity.GetFocusTarget(windowInfo)
        targetHwnd := MapGet(focus, "hwnd", MapGet(windowInfo, "hwnd", 0))
        pid := 0
        threadId := targetHwnd
            ? DllCall("user32\GetWindowThreadProcessId", "Ptr", targetHwnd, "UInt*", &pid, "UInt")
            : MapGet(windowInfo, "threadId", 0)
        hkl := threadId ? DllCall("user32\GetKeyboardLayout", "UInt", threadId, "Ptr") : 0
        langId := hkl & 0xFFFF
        profile := this.ResolveProfileForLanguage(langId, hkl)
        return Map(
            "profile", profile.Count ? profile["id"] : Hex(langId, 4) ":unknown",
            "kind", profile.Count ? profile["kind"] : "unknown",
            "langId", Hex(langId, 4),
            "hkl", "0x" Hex(hkl)
        )
    }

    ResolveProfileForLanguage(langId, hkl) {
        langKey := Hex(langId, 4)
        active := this.GetActiveProfile()
        if (active.Count && active["langId"] = langId) {
            catalogKey := StrLower(active["id"])
            if this.Catalog.Has(catalogKey)
                return this.Catalog[catalogKey]
            return active
        }
        if !this.ByLanguage.Has(langKey)
            return Map()
        candidates := this.ByLanguage[langKey]
        if (candidates.Length = 1)
            return candidates[1]
        lowHkl := hkl & 0xFFFFFFFF
        for candidate in candidates {
            if (candidate["kind"] = "keyboard" && Integer("0x" candidate["layoutId"]) = lowHkl)
                return candidate
        }
        this.Logger.Warn("Multiple profiles share language " langKey "; exact foreground TIP is ambiguous")
        return candidates[1]
    }

    GetActiveProfile() {
        if !IsObject(this.Manager)
            return Map()
        category := GuidBuffer(InputProfiles.CATEGORY_KEYBOARD)
        profileBytes := Buffer(A_PtrSize = 8 ? 88 : 72, 0)
        try hr := ComCall(10, this.Manager, "Ptr", category, "Ptr", profileBytes, "Int")
        catch
            return Map()
        if (hr != 0)
            return Map()
        profileType := NumGet(profileBytes, 0, "UInt")
        langId := NumGet(profileBytes, 4, "UShort")
        if (profileType = 1) {
            clsid := GuidString(profileBytes.Ptr + 8)
            profileGuid := GuidString(profileBytes.Ptr + 24)
            return Map(
                "id", Hex(langId, 4) ":" StrUpper(clsid) StrUpper(profileGuid),
                "kind", "tip", "langId", langId,
                "clsid", StrUpper(clsid), "profileGuid", StrUpper(profileGuid),
                "layoutId", "0000" Hex(langId, 4)
            )
        }
        hklOffset := A_PtrSize = 8 ? 72 : 64
        hkl := NumGet(profileBytes, hklOffset, "Ptr")
        layoutId := Hex(hkl & 0xFFFFFFFF, 8)
        return Map(
            "id", Hex(langId, 4) ":" layoutId,
            "kind", "keyboard", "langId", langId,
            "layoutId", layoutId,
            "clsid", "{00000000-0000-0000-0000-000000000000}",
            "profileGuid", "{00000000-0000-0000-0000-000000000000}"
        )
    }

    Switch(windowInfo, desiredState) {
        profileId := MapGet(desiredState, "profile", "")
        profile := this.ParseProfile(profileId)
        if !profile.Count {
            this.Logger.Warn("Cannot switch unknown profile '" profileId "'")
            return false
        }
        if (profile["kind"] = "tip")
            this.PrimeTsfProfile(profile)
        hkl := DllCall("user32\LoadKeyboardLayoutW", "WStr", profile["layoutId"], "UInt", 0x2, "Ptr")
        if !hkl {
            this.Logger.Warn("LoadKeyboardLayout failed for " profile["layoutId"] " (" A_LastError ")")
            return false
        }
        focus := this.Identity.GetFocusTarget(windowInfo)
        target := MapGet(focus, "hwnd", MapGet(windowInfo, "hwnd", 0))
        if !target
            return false
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
                "UInt", 0x4,
                "Int")
            return hr = 0
        } catch Error as err {
            this.Logger.Debug("TSF profile priming failed: " err.Message)
            return false
        }
    }

    DisplayName(profileId) {
        key := StrLower(profileId)
        return this.Catalog.Has(key) ? this.Catalog[key]["description"] : profileId
    }
}
