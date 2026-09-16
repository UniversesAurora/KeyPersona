#Requires AutoHotkey v2.0

class RuleEngine {
    __New(config, logger) {
        this.Config := config
        this.Logger := logger
        this.Rules := config.RuleSections
    }

    Match(windowInfo) {
        best := Map()
        bestPriority := -2147483648
        for rule in this.Rules {
            if !ParseBool(MapGet(rule, "enabled", "1"), true)
                continue
            priority := ParseInt(MapGet(rule, "priority", "0"), 0)
            if (priority < bestPriority || !this.MatchesFields(rule, windowInfo))
                continue
            stateName := MapGet(rule, "state", "")
            state := this.Config.GetNamedState(stateName)
            if !state.Count {
                this.Logger.Warn("Rule '" MapGet(rule, "name", "") "' refers to unknown state '" stateName "'")
                continue
            }
            best := Map(
                "name", MapGet(rule, "name", ""),
                "priority", priority,
                "stateName", stateName,
                "state", state
            )
            bestPriority := priority
        }
        return best
    }

    MatchesFields(rule, windowInfo) {
        expectedExe := MapGet(rule, "exe", "")
        if (expectedExe != "" && StrLower(expectedExe) != StrLower(MapGet(windowInfo, "exe", "")))
            return false
        checks := [
            ["pathRegex", MapGet(windowInfo, "path", "")],
            ["classRegex", MapGet(windowInfo, "class", "")],
            ["titleRegex", MapGet(windowInfo, "title", "")]
        ]
        for check in checks {
            pattern := MapGet(rule, check[1], "")
            if (pattern = "")
                continue
            try {
                if !RegExMatch(check[2], pattern)
                    return false
            } catch Error as err {
                this.Logger.Warn("Invalid regex in rule '" MapGet(rule, "name", "") "': " err.Message)
                return false
            }
        }
        return expectedExe != "" || MapGet(rule, "pathRegex", "") != ""
            || MapGet(rule, "classRegex", "") != "" || MapGet(rule, "titleRegex", "") != ""
    }
}
