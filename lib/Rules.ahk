#Requires AutoHotkey v2.0

class RuleEngine {
    __New(config, logger) {
        this.Config := config
        this.Logger := logger
        this.Rules := []
        this.PathRules := []
        this.ClassOnlyRules := []
        for rule in config.RuleSections {
            if !ParseBool(MapGet(rule, "enabled", "1"), true)
                continue
            match := {rule: rule, rank: RuleEngine.MatchRank(rule), priority: ParseInt(MapGet(rule, "priority", "0"), 0)}
            this.Rules.Push(match)
            if match.rank = 5
                this.PathRules.Push(rule)
            if match.rank = 2 && !ParseBool(MapGet(rule, "processLookup", "1"), true)
                this.ClassOnlyRules.Push(match)
        }
    }

    static MatchRank(rule) {
        if MapGet(rule, "path", "") != "" || MapGet(rule, "pathRegex", "") != ""
            return 5
        if MapGet(rule, "packageFamily", "") != ""
            return 4
        selector := MapGet(rule, "exe", "")
        if InStr(selector, "class:") = 1
            return 2
        if selector != "" && !InStr(selector, "*") && !InStr(selector, "?")
            return 3
        if MapGet(rule, "classRegex", "") != ""
            return 2
        return 1
    }

    Match(windowInfo, classOnly := false) {
        best := Map()
        bestRank := 0
        bestPriority := 0
        for candidate in (classOnly ? this.ClassOnlyRules : this.Rules) {
            if (candidate.rank < bestRank || (candidate.rank = bestRank && candidate.priority < bestPriority))
                continue
            rule := candidate.rule
            if !this.MatchesFields(rule, windowInfo)
                continue
            stateName := MapGet(rule, "state", "")
            state := this.Config.GetNamedState(stateName)
            if !state.Count {
                this.Logger.Warn("Rule '" MapGet(rule, "name", "") "' refers to unknown state '" stateName "'")
                continue
            }
            best := Map(
                "name", MapGet(rule, "name", ""),
                "rank", candidate.rank,
                "priority", candidate.priority,
                "stateName", stateName,
                "state", state
            )
            bestRank := candidate.rank
            bestPriority := candidate.priority
        }
        return best
    }

    UsesPathIdentity(windowInfo) {
        path := MapGet(windowInfo, "path", "")
        if path = ""
            return false
        for rule in this.PathRules {
            selector := MapGet(rule, "exe", "")
            ; Window captions and classes may change without changing the executable.
            if (InStr(selector, "class:") = 1 || this.MatchesExecutable(rule, windowInfo))
                && this.MatchesPackage(rule, windowInfo)
                && this.MatchesPath(rule, path)
                return true
        }
        return false
    }

    MatchesExecutable(rule, windowInfo) {
        selector := MapGet(rule, "exe", "")
        exe := MapGet(windowInfo, "exe", "")
        if InStr(exe, "class:") = 1
            exe := ""
        if selector != "" && selector != "*" {
            if InStr(selector, "class:") = 1 {
                if selector != MapGet(windowInfo, "classSelector", "")
                    return false
            } else if InStr(selector, "*") || InStr(selector, "?") {
                if exe = "" || InStr(selector, "\")
                    return false
                pattern := "i)^\Q" StrReplace(StrReplace(selector, "*", "\E.*\Q"), "?", "\E.\Q") "\E$"
                if !RegExMatch(exe, pattern)
                    return false
            } else if selector != exe {
                return false
            }
        }

        return true
    }

    MatchesPath(rule, path) {
        expectedPath := MapGet(rule, "path", "")
        pattern := MapGet(rule, "pathRegex", "")
        return (expectedPath = "" || path = expectedPath)
            && (pattern = "" || (path != "" && this.MatchesPattern(rule, pattern, path)))
    }

    MatchesPackage(rule, windowInfo) {
        expected := MapGet(rule, "packageFamily", "")
        return expected = "" || expected = MapGet(windowInfo, "packageFamily", "")
    }

    MatchesFields(rule, windowInfo) {
        if !this.MatchesExecutable(rule, windowInfo) || !this.MatchesPackage(rule, windowInfo)
            || !this.MatchesPath(rule, MapGet(windowInfo, "path", ""))
            return false
        classPattern := MapGet(rule, "classRegex", "")
        titlePattern := MapGet(rule, "titleRegex", "")
        return this.MatchesPattern(rule, classPattern, MapGet(windowInfo, "class", ""))
            && this.MatchesPattern(rule, titlePattern, MapGet(windowInfo, "title", ""))
            && (MapGet(rule, "exe", "") != "" || MapGet(rule, "path", "") != ""
                || MapGet(rule, "packageFamily", "") != ""
                || MapGet(rule, "pathRegex", "") != "" || classPattern != "" || titlePattern != "")
    }

    MatchesPattern(rule, pattern, value) {
        if pattern = ""
            return true
        try return !!RegExMatch(value, pattern)
        catch Error as failure {
            this.Logger.Warn("Invalid regex in rule '" MapGet(rule, "name", "") "': " failure.Message)
            return false
        }
    }
}
