# 为 KeyPersona 贡献代码

感谢参与 KeyPersona。提交改动前，请先确认问题能够复现，并尽量把一次提交限制在一个清晰目标内。

## 开发环境

- Windows 10 或 Windows 11（64 位）
- [PowerShell 7](https://learn.microsoft.com/powershell/)
- [AutoHotkey v2](https://www.autohotkey.com/)（64 位）
- [官方 Ahk2Exe 编译器](https://github.com/AutoHotkey/Ahk2Exe/releases)

构建脚本依次从命令参数、`KEYPERSONA_AHK_RUNTIME` / `KEYPERSONA_AHK_COMPILER`、标准安装目录和 `PATH` 查找依赖。
也可以把 `Ahk2Exe.exe` 放入仓库根目录的 `build-tools`。

## 构建与测试

在任意克隆目录运行：

```powershell
pwsh -NoProfile -File .\build.ps1
```

默认产物写入 `dist`。安装到指定目录：

```powershell
pwsh -NoProfile -File .\build.ps1 -InstallDirectory '<install-directory>'
```

依赖不在标准位置时：

```powershell
pwsh -NoProfile -File .\build.ps1 `
  -RuntimePath '<path-to-AutoHotkey64.exe>' `
  -CompilerPath '<path-to-Ahk2Exe.exe>'
```

构建默认执行源码自检、编译后自检和隔离烟雾测试。请勿为了绕过失败而提交 `-SkipTests` 产物。

## 提交要求

- 不提交 `config.ini` 的个人运行副本、`state.ini`、日志、构建产物或本机绝对路径。
- 用户规则属于 `config.ini`；程序学习状态属于 `state.ini`。
- 新功能应补充自检和文档。
- 日常提交不修改版本号或创建标签；正式发布遵循 `docs/RELEASING.md`。
