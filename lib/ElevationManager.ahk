#Requires AutoHotkey v2.0

class ElevationManager {
    static AccountSid(pid := 0, requireElevated := false) {
        process := pid
            ? DllCall("kernel32\OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
            : DllCall("kernel32\GetCurrentProcess", "Ptr")
        if !process
            throw OSError(A_LastError, "OpenProcess")
        token := 0
        try {
            if !DllCall("advapi32\OpenProcessToken", "Ptr", process, "UInt", 0x8, "Ptr*", &token, "Int")
                throw OSError(A_LastError, "OpenProcessToken")
            if requireElevated {
                elevated := 0
                length := 0
                if !DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 20,
                    "UInt*", &elevated, "UInt", 4, "UInt*", &length, "Int")
                    throw OSError(A_LastError, "GetTokenInformation")
                if !elevated
                    throw Error("Windows 未授予管理员权限。")
            }
            size := 0
            DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 1, "Ptr", 0, "UInt", 0, "UInt*", &size, "Int")
            if !size
                throw OSError(A_LastError, "GetTokenInformation")
            userInfo := Buffer(size)
            if !DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 1, "Ptr", userInfo,
                "UInt", size, "UInt*", &size, "Int")
                throw OSError(A_LastError, "GetTokenInformation")
            return ElevationManager.SidString(NumGet(userInfo, 0, "Ptr"))
        } finally {
            if token
                DllCall("kernel32\CloseHandle", "Ptr", token)
            if pid
                DllCall("kernel32\CloseHandle", "Ptr", process)
        }
    }

    static ResolveAccountSid(account) {
        if account = "" || RegExMatch(account, "i)^S-\d+(-\d+)+$")
            return account
        sidSize := 0
        domainSize := 0
        use := 0
        DllCall("advapi32\LookupAccountNameW", "Ptr", 0, "WStr", account, "Ptr", 0, "UInt*", &sidSize,
            "Ptr", 0, "UInt*", &domainSize, "UInt*", &use, "Int")
        if !sidSize
            return ""
        sid := Buffer(sidSize)
        domain := Buffer(Max(2, domainSize * 2))
        if !DllCall("advapi32\LookupAccountNameW", "Ptr", 0, "WStr", account, "Ptr", sid, "UInt*", &sidSize,
            "Ptr", domain, "UInt*", &domainSize, "UInt*", &use, "Int")
            return ""
        return ElevationManager.SidString(sid)
    }

    static SidString(sid) {
        address := 0
        if !DllCall("advapi32\ConvertSidToStringSidW", "Ptr", sid, "Ptr*", &address, "Int")
            throw OSError(A_LastError, "ConvertSidToStringSidW")
        try return StrGet(address, "UTF-16")
        finally DllCall("kernel32\LocalFree", "Ptr", address)
    }

    static RestartCommand(executable, script, parentPid, sid, enablePreference) {
        quote := Chr(34)
        target := quote executable quote " /force"
        if script != ""
            target .= " " quote script quote
        return "*RunAs " target " --admin-parent=" parentPid " --admin-owner=" sid
            . (enablePreference ? " --enable-admin" : "")
    }

    static RequestRestart(baseDir, enablePreference := false) {
        sid := ElevationManager.AccountSid()
        target := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
        script := A_IsCompiled ? "" : A_ScriptFullPath
        pid := DllCall("kernel32\GetCurrentProcessId", "UInt")
        Run(ElevationManager.RestartCommand(target, script, pid, sid, enablePreference), baseDir, "Hide", &childPid)
        if !childPid || ElevationManager.AccountSid(childPid, true) != sid
            throw Error("请使用当前登录的 Windows 账户批准管理员授权。")
    }

    static WaitForHandoff(parentPid, ownerSid) {
        if !A_IsAdmin || ownerSid != ElevationManager.AccountSid()
            throw Error("管理员授权需使用当前登录的 Windows 账户。")
        if ProcessWaitClose(parentPid, 8)
            throw Error("原实例仍在运行，未接管设置。")
    }
}
