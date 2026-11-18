#Requires AutoHotkey v2.0

MapGet(map, key, defaultValue := "") {
    return IsObject(map) && map.Has(key) ? map[key] : defaultValue
}

ParseBool(value, defaultValue := false) {
    value := StrLower(Trim(value ""))
    if (value = "1" || value = "true" || value = "yes" || value = "on")
        return true
    if (value = "0" || value = "false" || value = "no" || value = "off")
        return false
    return defaultValue
}

ParseInt(value, defaultValue, minimum := "", maximum := "") {
    if !IsNumber(value)
        return defaultValue
    result := Integer(value)
    if (minimum != "" && result < minimum)
        result := minimum
    if (maximum != "" && result > maximum)
        result := maximum
    return result
}

TickCount64() {
    return DllCall("kernel32\GetTickCount64", "UInt64")
}

ApplicationVersion() {
    if A_IsCompiled {
        try return FileGetVersion(A_ScriptFullPath)
    }
    return AppInfo.Version != "" ? AppInfo.Version : "开发版"
}

Hex(value, width := 0) {
    return width ? Format("{:0" width "X}", value) : Format("{:X}", value)
}

Fnv1a32(text) {
    hash := 2166136261
    Loop Parse, text {
        hash := ((hash ^ Ord(A_LoopField)) * 16777619) & 0xFFFFFFFF
    }
    return Format("{:08X}", hash)
}

IniEscape(value) {
    value := StrReplace(value "", "\", "\\")
    value := StrReplace(value, "`r", "\r")
    value := StrReplace(value, "`n", "\n")
    return value
}

IniUnescape(value) {
    result := ""
    offset := 1
    while (position := RegExMatch(value, "\\([\\rn])", &escaped, offset)) {
        result .= SubStr(value, offset, position - offset)
        result .= escaped[1] = "r" ? "`r" : escaped[1] = "n" ? "`n" : "\"
        offset := position + 2
    }
    return result SubStr(value, offset)
}

JoinValues(values, separator := ",") {
    output := ""
    for index, value in values
        output .= (index = 1 ? "" : separator) value
    return output
}

SplitCsv(value) {
    result := []
    for item in StrSplit(value "", ",") {
        item := Trim(item)
        if (item != "")
            result.Push(item)
    }
    return result
}

GuidBuffer(guid) {
    guidBytes := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", guid, "Ptr", guidBytes, "HRESULT")
    return guidBytes
}

GuidString(ptr) {
    chars := Buffer(78, 0)
    count := DllCall("ole32\StringFromGUID2", "Ptr", ptr, "Ptr", chars, "Int", 39, "Int")
    return count ? StrGet(chars, "UTF-16") : ""
}

StateClone(state) {
    clone := Map()
    if IsObject(state) {
        for key, value in state
            clone[key] := value
    }
    return clone
}

StateSignature(state) {
    if !IsObject(state)
        return ""
    return StrLower(MapGet(state, "profile", "unknown")) "|"
        . MapGet(state, "imeOpen", "unknown") "|"
        . StrLower(MapGet(state, "conversion", "unknown")) "|"
        . StrLower(MapGet(state, "sentence", "unknown"))
}

StateMatches(actual, desired) {
    if !IsObject(actual) || !IsObject(desired)
        return false
    desiredProfile := StrLower(MapGet(desired, "profile", "unknown"))
    actualProfile := StrLower(MapGet(actual, "profile", "unknown"))
    if (desiredProfile != "unknown" && actualProfile != desiredProfile)
        return false
    for field in ["imeOpen", "conversion", "sentence"] {
        wanted := StrLower(MapGet(desired, field, "unknown") "")
        if (wanted = "" || wanted = "unknown" || wanted = "preserve")
            continue
        if (StrLower(MapGet(actual, field, "unknown") "") != wanted)
            return false
    }
    return true
}

HasKnownProfile(state) {
    profile := StrLower(Trim(MapGet(state, "profile", "") ""))
    return profile != "" && profile != "unknown" && !RegExMatch(profile, ":unknown$")
}

IsChineseLanguageState(state) {
    langId := Trim(MapGet(state, "langId", "") "")
    if (langId = "" && RegExMatch(MapGet(state, "profile", "") "", "i)^([0-9a-f]{4}):", &match))
        langId := match[1]
    if !RegExMatch(langId, "i)^[0-9a-f]{4}$")
        return false
    try return (Integer("0x" langId) & 0x03FF) = 0x0004
    return false
}

ShouldReplacePunctuationState(profileState, imeOpen, optionEnabled := true, appEnabled := true) {
    return optionEnabled && appEnabled && HasKnownProfile(profileState)
        && IsChineseLanguageState(profileState) && (imeOpen = "1")
}

StateLabel(state) {
    if !IsObject(state)
        return "unknown"
    profile := MapGet(state, "profile", "unknown")
    mode := ImeMode.ModeLabel(profile, MapGet(state, "imeOpen", "unknown"))
    return mode = "" ? profile : profile "（" mode "）"
}

class IniDocument {
    __New() {
        this.Sections := Map()
        this.Sections.CaseSense := "Off"
        this.SectionOrder := []
        this.RepeatedSections := Map()
        this.RepeatedSections.CaseSense := "Off"
    }

    static Update(path, changes, expected := unset) {
        if !changes.Length
            return true
        wasCritical := A_IsCritical
        Critical "On"
        tempPath := path ".tmp." DllCall("kernel32\GetCurrentProcessId", "UInt")
        try {
            original := FileExist(path) ? FileRead(path, "UTF-8") : ""
            if IsSet(expected) && !(original == expected)
                return false
            lines := StrSplit(StrReplace(original, "`r`n", "`n"), "`n")
            for change in changes
                IniDocument.ApplyChange(lines, change)
            updated := JoinValues(lines, "`n")
            if (updated == StrReplace(original, "`r`n", "`n"))
                return true
            if (updated != "" && SubStr(updated, -1) != "`n")
                updated .= "`n"
            configFile := FileOpen(tempPath, "w", "UTF-8")
            try configFile.Write(updated)
            finally configFile.Close()
            if !DllCall("kernel32\MoveFileExW", "WStr", tempPath, "WStr", path, "UInt", 0x9, "Int")
                throw OSError(A_LastError, "MoveFileExW")
            return true
        } finally {
            try FileDelete(tempPath)
            Critical wasCritical
        }
    }

    static ApplyChange(lines, change) {
        section := change[1]
        key := change.Length >= 2 ? change[2] : ""
        writing := change.Length = 3
        start := 0
        finish := lines.Length + 1
        found := 0
        for index, line in lines {
            if RegExMatch(Trim(line), "^\[([^\]]+)\]$", &heading) {
                if start {
                    finish := index
                    break
                }
                if (Trim(heading[1]) = section)
                    start := index
                continue
            }
            equals := InStr(line, "=")
            if start && key != "" && equals && Trim(SubStr(line, 1, equals - 1)) = key
                found := index
        }
        if !start {
            if writing {
                if (lines[lines.Length] != "")
                    lines.Push("")
                lines.Push("[" section "]", key "=" change[3], "")
            }
        } else if (key = "") {
            lines.RemoveAt(start, finish - start)
            if !lines.Length
                lines.Push("")
        } else if found {
            if writing
                lines[found] := key "=" change[3]
            else
                lines.RemoveAt(found)
        } else if writing {
            while (finish > start + 1 && Trim(lines[finish - 1]) = "")
                finish -= 1
            lines.InsertAt(finish, key "=" change[3])
        }
    }

    static Load(path) {
        return IniDocument.Parse(FileExist(path) ? FileRead(path, "UTF-8") : "")
    }

    static Parse(text) {
        doc := IniDocument()
        current := ""
        for rawLine in StrSplit(StrReplace(text, "`r"), "`n") {
            line := Trim(rawLine)
            if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "#")
                continue
            if RegExMatch(line, "^\[([^\]]+)\]$", &match) {
                current := Trim(match[1])
                if !doc.Sections.Has(current) {
                    section := Map()
                    section.CaseSense := "Off"
                    doc.Sections[current] := section
                    doc.SectionOrder.Push(current)
                } else
                    doc.RepeatedSections[current] := true
                continue
            }
            if (current = "")
                continue
            equals := InStr(rawLine, "=")
            if !equals
                continue
            key := Trim(SubStr(rawLine, 1, equals - 1))
            value := Trim(SubStr(rawLine, equals + 1))
            if (key != "")
                doc.Sections[current][key] := value
        }
        return doc
    }

    GetSection(name) {
        return this.Sections.Has(name) ? this.Sections[name] : Map()
    }

    Get(section, key, defaultValue := "") {
        data := this.GetSection(section)
        return data.Has(key) ? data[key] : defaultValue
    }
}

class Logger {
    __New(path, level := "info") {
        this.Path := path
        this.Level := StrLower(level)
        this.Bytes := 0
        try this.Bytes := FileGetSize(path)
    }

    Debug(message) {
        if (this.Level = "debug")
            this.Write("DEBUG", message)
    }

    Info(message) {
        if (this.Level = "debug" || this.Level = "info")
            this.Write("INFO", message)
    }

    Warn(message) {
        if (this.Level != "off")
            this.Write("WARN", message)
    }

    Error(message) {
        if (this.Level != "off")
            this.Write("ERROR", message)
    }

    Write(level, message) {
        if (this.Bytes >= 1024 * 1024) {
            try {
                FileMove(this.Path, this.Path ".old", true)
                this.Bytes := 0
            }
        }
        line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " [" level "] " message "`n"
        try {
            FileAppend(line, this.Path, "UTF-8")
            this.Bytes += StrPut(line, "UTF-8") - 1
        }
    }
}
