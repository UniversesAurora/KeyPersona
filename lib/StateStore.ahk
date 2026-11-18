#Requires AutoHotkey v2.0

class StateStore {
    __New(path, logger) {
        this.Path := path
        this.BackupPath := path ".bak"
        this.Logger := logger
        this.Records := Map()
        this.Dirty := false
        this.ResetBackupOnFlush := false
        this.MainValid := false
        this.Load()
    }

    Load() {
        this.Records := Map()
        snapshot := this.ReadSnapshot(this.Path)
        this.MainValid := snapshot.valid
        if !snapshot.valid {
            backup := this.ReadSnapshot(this.BackupPath)
            if backup.valid {
                snapshot := backup
                this.Logger.Warn("State file was missing or invalid; loaded its backup")
            }
        }
        this.Records := snapshot.records
        this.Dirty := false
        this.Logger.Info("Loaded " this.Records.Count " remembered window state(s)")
    }

    ReadSnapshot(path) {
        records := Map()
        if !FileExist(path)
            return {valid: false, records: records}
        try doc := IniDocument.Load(path)
        catch Error as failure {
            this.Logger.Warn("State file could not be read: " failure.Message)
            return {valid: false, records: records}
        }
        version := doc.Get("meta", "schemaVersion", "")
        if ((version != "3" && version != "2" && version != "1") || doc.Get("meta", "updatedAt", "") = "")
            return {valid: false, records: records}
        for section, values in doc.Sections {
            if !RegExMatch(section, "i)^window\.")
                continue
            identityKey := IniUnescape(MapGet(values, "identityKey", ""))
            if (identityKey = "" || !values.Has("profile") || records.Has(identityKey))
                return {valid: false, records: Map()}
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
                "source", "learned",
                "lastSeen", MapGet(values, "lastSeen", "")
            )
            records[identityKey] := record
        }
        if (version = "3" && (doc.Get("meta", "recordCount", "-1") != records.Count
            || doc.Get("end", "complete", "") != "1"))
            return {valid: false, records: Map()}
        return {valid: true, records: records}
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
        if this.Records.Has(key) && StateSignature(this.Records[key]) = StateSignature(state)
            return false
        record := Map(
            "identityKey", key,
            "mode", MapGet(windowInfo, "mode", "app"),
            "exe", MapGet(windowInfo, "exe", ""),
            "class", MapGet(windowInfo, "mode", "app") = "window" ? MapGet(windowInfo, "class", "") : "",
            "title", MapGet(windowInfo, "mode", "app") = "window" ? MapGet(windowInfo, "normalizedTitle", "") : "",
            "profile", MapGet(state, "profile", "unknown"),
            "imeOpen", MapGet(state, "imeOpen", "unknown"),
            "conversion", MapGet(state, "conversion", "unknown"),
            "sentence", MapGet(state, "sentence", "unknown"),
            "source", source,
            "lastSeen", FormatTime(, "yyyy-MM-dd HH:mm:ss")
        )
        this.Records[key] := record
        this.Dirty := true
        return true
    }

    Remove(windowInfo) {
        key := MapGet(windowInfo, "identityKey", "")
        if (key != "" && this.Records.Has(key)) {
            this.Records.Delete(key)
            this.Dirty := true
            this.ResetBackupOnFlush := true
            return true
        }
        return false
    }

    RemoveInvalidProfiles(validProfiles) {
        removed := 0
        invalidKeys := []
        for identityKey, record in this.Records {
            profileId := StrLower(Trim(MapGet(record, "profile", "") ""))
            isUnknown := profileId = "" || profileId = "unknown" || RegExMatch(profileId, ":unknown$")
            if isUnknown
                invalidKeys.Push(identityKey)
            else if !validProfiles.Has(profileId)
                invalidKeys.Push(identityKey)
        }
        for identityKey in invalidKeys {
            this.Records.Delete(identityKey)
            removed += 1
        }
        if removed
            this.Dirty := true
        return removed
    }

    ClearAll() {
        removed := this.Records.Count
        this.Records := Map()
        this.Dirty := true
        this.ResetBackupOnFlush := true
        return removed
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
        wasCritical := A_IsCritical
        Critical "On"
        tempPath := this.Path ".tmp." DllCall("kernel32\GetCurrentProcessId", "UInt")
        backupTemp := tempPath ".bak"
        try {
            stateFile := FileOpen(tempPath, "w", "UTF-8")
            if !IsObject(stateFile)
                throw Error("Unable to open temporary state file")
            try stateFile.Write(this.Serialize())
            finally stateFile.Close()
            if !this.ResetBackupOnFlush && this.MainValid && FileExist(this.Path) {
                try this.ReplaceBackup(this.Path, backupTemp)
                catch Error as failure
                    this.Logger.Warn("Could not update the state backup: " failure.Message)
            }
            if !DllCall("kernel32\MoveFileExW", "WStr", tempPath, "WStr", this.Path, "UInt", 0x9, "Int")
                throw OSError(A_LastError, "MoveFileExW")
            this.MainValid := true
            if this.ResetBackupOnFlush
                this.ReplaceBackup(this.Path, backupTemp)
            this.Dirty := false
            this.ResetBackupOnFlush := false
            this.Logger.Debug("State file flushed")
            return true
        } catch Error as err {
            this.Logger.Error("State flush failed: " err.Message)
            return false
        } finally {
            try FileDelete(tempPath)
            try FileDelete(backupTemp)
            Critical wasCritical
        }
    }

    ReplaceBackup(sourcePath, backupTemp) {
        FileCopy(sourcePath, backupTemp, true)
        if !DllCall("kernel32\MoveFileExW", "WStr", backupTemp, "WStr", this.BackupPath, "UInt", 0x9, "Int")
            throw OSError(A_LastError, "MoveFileExW")
    }

    Serialize() {
        text := "; Managed by " AppInfo.Name ". Edit " AppInfo.ConfigFile ", not this file, while the app is running.`n"
            . "[meta]`n"
            . "schemaVersion=3`nrecordCount=" this.Records.Count "`n"
            . "updatedAt=" FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n`n"
        used := Map()
        for identityKey, record in this.Records {
            hash := Fnv1a32(identityKey)
            occurrence := MapGet(used, hash, 0) + 1
            used[hash] := occurrence
            text .= "[window." hash (occurrence = 1 ? "" : "-" occurrence) "]`n"
            text .= "identityKey=" IniEscape(identityKey) "`n"
            text .= "mode=" MapGet(record, "mode", "app") "`n"
            text .= "exe=" IniEscape(MapGet(record, "exe", "")) "`n"
            text .= "class=" IniEscape(MapGet(record, "class", "")) "`n"
            text .= "title=" IniEscape(MapGet(record, "title", "")) "`n"
            text .= "profile=" MapGet(record, "profile", "unknown") "`n"
            text .= "imeOpen=" MapGet(record, "imeOpen", "unknown") "`n"
            text .= "conversion=" MapGet(record, "conversion", "unknown") "`n"
            text .= "sentence=" MapGet(record, "sentence", "unknown") "`n"
            text .= "source=" MapGet(record, "source", "learned") "`n"
            text .= "lastSeen=" MapGet(record, "lastSeen", "") "`n`n"
        }
        return text "[end]`ncomplete=1`n"
    }
}
