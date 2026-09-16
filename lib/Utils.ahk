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
    try {
        source := FileRead(A_ScriptFullPath, "UTF-8")
        if RegExMatch(source, "m)^;@Ahk2Exe-SetVersion\s+([^\r\n]+)$", &match)
            return Trim(match[1])
    }
    return "开发版"
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
    marker := Chr(0xE000)
    value := StrReplace(value "", "\\", marker)
    value := StrReplace(value, "\r", "`r")
    value := StrReplace(value, "\n", "`n")
    return StrReplace(value, marker, "\")
}

JoinValues(values, separator := ",") {
    output := ""
    for value in values
        output .= (output = "" ? "" : separator) value
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

ShouldReplaceBacktickState(profileState, imeOpen, optionEnabled := true, appEnabled := true) {
    return optionEnabled && appEnabled && HasKnownProfile(profileState)
        && IsChineseLanguageState(profileState) && (imeOpen = "1")
}

StateLabel(state) {
    if !IsObject(state)
        return "unknown"
    profile := MapGet(state, "profile", "unknown")
    open := MapGet(state, "imeOpen", "unknown")
    if (open = "1")
        return profile "（中文）"
    if (open = "0")
        return profile "（英文）"
    return profile
}

class IniDocument {
    __New() {
        this.Sections := Map()
    }

    static Load(path) {
        doc := IniDocument()
        if !FileExist(path)
            return doc
        text := FileRead(path, "UTF-8")
        current := ""
        for rawLine in StrSplit(StrReplace(text, "`r"), "`n") {
            line := Trim(rawLine)
            if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "#")
                continue
            if RegExMatch(line, "^\[([^\]]+)\]$", &match) {
                current := Trim(match[1])
                if !doc.Sections.Has(current)
                    doc.Sections[current] := Map()
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
        try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " [" level "] " message "`n", this.Path, "UTF-8")
    }
}
