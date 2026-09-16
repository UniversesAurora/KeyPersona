#Requires AutoHotkey v2.0

class StateStore {
    __New(path, logger) {
        this.Path := path
        this.BackupPath := path ".bak"
        this.Logger := logger
        this.Records := Map()
        this.Dirty := false
        this.Load()
    }

    Load() {
        this.Records := Map()
        doc := IniDocument()
        try {
            doc := IniDocument.Load(this.Path)
        } catch Error as err {
            this.Logger.Warn("State file could not be read: " err.Message)
        }
        if (FileExist(this.Path) && !doc.Sections.Has("meta") && FileExist(this.BackupPath)) {
            try {
                backup := IniDocument.Load(this.BackupPath)
                if backup.Sections.Has("meta") {
                    doc := backup
                    this.Logger.Warn("State file was invalid; loaded the backup instead")
                }
            } catch Error as err {
                this.Logger.Warn("State backup could not be read: " err.Message)
            }
        }
        for section, values in doc.Sections {
            if !RegExMatch(section, "i)^window\.")
                continue
            identityKey := IniUnescape(MapGet(values, "identityKey", ""))
            if (identityKey = "")
                continue
            record := Map(
                "identityKey", identityKey,
                "mode", MapGet(values, "mode", "app"),
                "exe", IniUnescape(MapGet(values, "exe", "")),
                "path", IniUnescape(MapGet(values, "path", "")),
                "class", IniUnescape(MapGet(values, "class", "")),
                "title", IniUnescape(MapGet(values, "title", "")),
                "profile", MapGet(values, "profile", "unknown"),
                "imeOpen", MapGet(values, "imeOpen", "unknown"),
                "conversion", MapGet(values, "conversion", "unknown"),
                "sentence", MapGet(values, "sentence", "unknown"),
                "source", MapGet(values, "source", "learned"),
                "lastSeen", MapGet(values, "lastSeen", "")
            )
            this.Records[identityKey] := record
        }
        this.Dirty := false
        this.Logger.Info("Loaded " this.Records.Count " remembered window state(s)")
    }

    Find(windowInfo) {
        key := MapGet(windowInfo, "identityKey", "")
        if (key = "" || !this.Records.Has(key))
            return Map()
        return this.StateFromRecord(this.Records[key])
    }

    Upsert(windowInfo, state, source := "learned") {
        key := MapGet(windowInfo, "identityKey", "")
        if (key = "")
            return false
        record := Map(
            "identityKey", key,
            "mode", MapGet(windowInfo, "mode", "app"),
            "exe", MapGet(windowInfo, "exe", ""),
            "path", MapGet(windowInfo, "path", ""),
            "class", MapGet(windowInfo, "class", ""),
            "title", MapGet(windowInfo, "normalizedTitle", MapGet(windowInfo, "title", "")),
            "profile", MapGet(state, "profile", "unknown"),
            "imeOpen", MapGet(state, "imeOpen", "unknown"),
            "conversion", MapGet(state, "conversion", "unknown"),
            "sentence", MapGet(state, "sentence", "unknown"),
            "source", source,
            "lastSeen", FormatTime(, "yyyy-MM-dd HH:mm:ss")
        )
        oldSignature := this.Records.Has(key) ? StateSignature(this.StateFromRecord(this.Records[key])) : ""
        oldSource := this.Records.Has(key) ? MapGet(this.Records[key], "source", "learned") : ""
        newSignature := StateSignature(state)
        this.Records[key] := record
        this.Dirty := true
        return oldSignature != newSignature || oldSource != source
    }

    Remove(windowInfo) {
        key := MapGet(windowInfo, "identityKey", "")
        if (key != "" && this.Records.Has(key)) {
            this.Records.Delete(key)
            this.Dirty := true
            return true
        }
        return false
    }

    StateFromRecord(record) {
        return Map(
            "profile", MapGet(record, "profile", "unknown"),
            "imeOpen", MapGet(record, "imeOpen", "unknown"),
            "conversion", MapGet(record, "conversion", "unknown"),
            "sentence", MapGet(record, "sentence", "unknown"),
            "source", MapGet(record, "source", "learned")
        )
    }

    Flush() {
        if !this.Dirty
            return true
        tempPath := this.Path ".tmp." DllCall("kernel32\GetCurrentProcessId", "UInt")
        try {
            try FileDelete(tempPath)
            stateFile := FileOpen(tempPath, "w", "UTF-8")
            if !IsObject(stateFile)
                throw Error("Unable to open temporary state file")
            stateFile.Write(this.Serialize())
            stateFile.Close()
            if FileExist(this.Path) {
                try FileCopy(this.Path, this.BackupPath, true)
            }
            flags := 0x1 | 0x8
            if !DllCall("kernel32\MoveFileExW", "WStr", tempPath, "WStr", this.Path, "UInt", flags, "Int")
                throw OSError(A_LastError, "MoveFileExW")
            this.Dirty := false
            this.Logger.Debug("State file flushed")
            return true
        } catch Error as err {
            this.Logger.Error("State flush failed: " err.Message)
            try FileDelete(tempPath)
            return false
        }
    }

    Serialize() {
        text := "; Managed by IME Memory. Edit config.ini, not this file, while the app is running.`n"
            . "[meta]`n"
            . "schemaVersion=2`n"
            . "updatedAt=" FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n`n"
        for identityKey, record in this.Records {
            text .= "[window." Fnv1a32(identityKey) "]`n"
            text .= "identityKey=" IniEscape(identityKey) "`n"
            text .= "mode=" MapGet(record, "mode", "app") "`n"
            text .= "exe=" IniEscape(MapGet(record, "exe", "")) "`n"
            text .= "path=" IniEscape(MapGet(record, "path", "")) "`n"
            text .= "class=" IniEscape(MapGet(record, "class", "")) "`n"
            text .= "title=" IniEscape(MapGet(record, "title", "")) "`n"
            text .= "profile=" MapGet(record, "profile", "unknown") "`n"
            text .= "imeOpen=" MapGet(record, "imeOpen", "unknown") "`n"
            text .= "conversion=" MapGet(record, "conversion", "unknown") "`n"
            text .= "sentence=" MapGet(record, "sentence", "unknown") "`n"
            text .= "source=" MapGet(record, "source", "learned") "`n"
            text .= "lastSeen=" MapGet(record, "lastSeen", "") "`n`n"
        }
        return text
    }
}
