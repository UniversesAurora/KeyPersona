# 发布流程

## 什么时候发布

- 功能、修复、文档和资源的日常改动只创建普通 commit。
- 构建或安装一次不等于发布新版本。
- 只有维护者明确决定发布并给出版本号时，才修改版本、创建 tag 和 GitHub Release。
- 已发布的 tag 和附件不覆盖、不重写。发布后发现问题时，使用新的补丁版本。

## 发布前准备

发布操作从仓库根目录执行。需要以下工具：

- Git：提交、创建 annotated tag、推送并核对远端引用。
- PowerShell 7：运行 `build.ps1`。它只是构建脚本的 shell，不是 KeyPersona 的运行依赖。
- 64 位 AutoHotkey v2 和官方 Ahk2Exe：源码自检、编译和编译后自检。
- GitHub CLI `gh`：创建 GitHub Release 和上传附件。先用 `gh auth status` 确认已经登录正确账号。

开始前确认工作区没有无关改动：

```powershell
git status --short
git fetch origin --tags
```

## 1. 准备版本内容

假设准备发布 `1.0.1`：

1. 在 `lib/AppInfo.ahk` 中同时更新 `AppInfo.Version` 和 `Ahk2Exe-SetVersion`。
2. 在 `CHANGELOG.md` 顶部新增 `1.0.1`，写明发布日期和用户能感知的新增、修改、修复。没有内容的分类可以省略。
3. 新建 `docs/releases/v1.0.1.md`。这份文件会直接作为 GitHub Release notes，至少写清下载文件、主要变更、升级提示、已知限制和验证情况。
4. 检查 README、配置示例和架构文档是否仍与实际行为一致。
5. 确认仓库里没有运行时配置、状态文件、日志、构建产物、凭据或本机绝对路径。

## 2. 构建并打包

```powershell
pwsh -NoProfile -File .\build.ps1 -Package
```

构建脚本会依次执行源码自检、编译、编译后自检和隔离烟雾测试，并在 `dist` 生成：

- `KeyPersona.exe`
- `config.ini`：构建过程使用的默认配置副本，不直接作为发布附件。
- `KeyPersona-1.0.1-windows-x64.zip`
- `SHA256SUMS.txt`

ZIP 中应只有：

- `KeyPersona.exe`
- `config.example.ini`
- `README.md`
- `CHANGELOG.md`
- `LICENSE`

`config.example.ini` 不能命名为 `config.ini`，否则用户解压升级时可能覆盖已有配置。

## 3. 检查产物

先检查 EXE 的版本和哈希：

```powershell
$version = '1.0.1'
$exe = Get-Item -LiteralPath '.\dist\KeyPersona.exe'
$exe.VersionInfo | Select-Object ProductName, FileDescription, FileVersion, ProductVersion
Get-Content -LiteralPath '.\dist\SHA256SUMS.txt'
Get-FileHash -Algorithm SHA256 -LiteralPath $exe.FullName
Get-FileHash -Algorithm SHA256 -LiteralPath ".\dist\KeyPersona-$version-windows-x64.zip"
```

再核对 ZIP 内容，不需要解压：

```powershell
$archive = [System.IO.Compression.ZipFile]::OpenRead(
    (Resolve-Path ".\dist\KeyPersona-$version-windows-x64.zip")
)
try {
    $archive.Entries.FullName
} finally {
    $archive.Dispose()
}
```

检查结果必须满足：

- 两处版本号和 EXE 文件版本一致。
- `SHA256SUMS.txt` 中的 EXE、ZIP 哈希与重新计算结果一致。
- ZIP 使用 `config.example.ini`，不包含 `config.ini`、`state.ini`、日志或本机路径。
- 构建脚本报告的三项测试全部通过。

## 4. 提交、创建 tag 并推送

```powershell
$version = '1.0.1'
$tag = "v$version"

git add --all
git commit -m "Release KeyPersona $version"
git tag -a $tag -m "KeyPersona $version"
git push origin main
git push origin $tag
```

确认本地 tag、远端 `main` 和远端 tag 指向同一个 commit：

```powershell
git rev-parse HEAD
git rev-parse $tag
git ls-remote origin refs/heads/main "refs/tags/$tag^{}"
```

如果这里不一致，先查明原因，不要创建 Release，也不要强制移动已经发布的 tag。

## 5. 创建 GitHub Release

正式版本同时上传 ZIP、单文件 EXE 和校验文件：

```powershell
$version = '1.0.1'
$tag = "v$version"

gh release create $tag `
  ".\dist\KeyPersona-$version-windows-x64.zip" `
  '.\dist\KeyPersona.exe' `
  '.\dist\SHA256SUMS.txt' `
  --verify-tag `
  --latest `
  --title "KeyPersona $version" `
  --notes-file ".\docs\releases\$tag.md"
```

`--verify-tag` 可以防止 GitHub CLI 在 tag 不存在时悄悄创建一个新 tag。预发布版本改用 `--prerelease --latest=false`。

## 6. 发布后核对

```powershell
$tag = 'v1.0.1'
gh release view $tag --json tagName,name,isDraft,isPrerelease,assets,url
gh release list --limit 5 --json tagName,name,isLatest,isDraft,isPrerelease,publishedAt
git status --short --branch
```

最后在浏览器中打开 Release，确认：

- title 是 `KeyPersona <版本号>`。
- Release notes 来自对应的 `docs/releases/v<版本号>.md`。
- Release 不是 draft，也没有被误标为 prerelease。
- ZIP、EXE、`SHA256SUMS.txt` 三个附件都能看到，名称和版本号正确。
- 正式版本被标记为 Latest。
- 工作区干净，远端 `main` 和 tag 已包含发布 commit。
