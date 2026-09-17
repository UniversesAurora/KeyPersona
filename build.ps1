#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$InstallDirectory,
    [string]$RuntimePath,
    [string]$CompilerPath,
    [switch]$SkipTests,
    [switch]$NoRestart,
    [switch]$Package
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$appInfoPath = Join-Path $sourceRoot 'lib\AppInfo.ahk'
$appInfoText = Get-Content -LiteralPath $appInfoPath -Raw

function Get-AppInfoValue {
    param([Parameter(Mandatory)] [string]$Name)
    $pattern = '(?m)^\s*static\s+' + [regex]::Escape($Name) + '\s*:=\s*"([^"]+)"\s*$'
    $match = [regex]::Match($appInfoText, $pattern)
    if (-not $match.Success) {
        throw "AppInfo.$Name was not found in $appInfoPath"
    }
    return $match.Groups[1].Value
}

function Resolve-ProjectPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $sourceRoot $Path))
}

function Find-FirstFile {
    param([string[]]$Candidates)
    return $Candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -First 1
}

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [string]$WorkingDirectory = $sourceRoot
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "Process failed ($($process.ExitCode)): $FilePath`n$stdout`n$stderr"
    }
    if ($stdout) { Write-Verbose $stdout }
    if ($stderr) { Write-Verbose $stderr }
}

function Get-RunningInstancesByPath {
    param([Parameter(Mandatory)] [string]$ExecutablePath)
    $normalizedTarget = [System.IO.Path]::GetFullPath($ExecutablePath)
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                [System.IO.Path]::GetFullPath($_.ExecutablePath).Equals(
                    $normalizedTarget,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )
}

$sourceFile = Get-AppInfoValue -Name 'SourceFile'
$executableFile = Get-AppInfoValue -Name 'ExecutableFile'
$configFile = Get-AppInfoValue -Name 'ConfigFile'
$productName = Get-AppInfoValue -Name 'Name'
$version = Get-AppInfoValue -Name 'Version'
$sourcePath = Join-Path $sourceRoot $sourceFile
$defaultConfigPath = Join-Path $sourceRoot $configFile
$outputRoot = if ($OutputDirectory) {
    Resolve-ProjectPath $OutputDirectory
} else {
    Join-Path $sourceRoot 'dist'
}
$outputPath = Join-Path $outputRoot $executableFile
$installRoot = Resolve-ProjectPath $InstallDirectory

$runtimeOverride = if ($RuntimePath) {
    Resolve-ProjectPath $RuntimePath
} else {
    [Environment]::GetEnvironmentVariable('KEYPERSONA_AHK_RUNTIME')
}
$runtimeCommand = Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue
$resolvedRuntime = Find-FirstFile @(
    $runtimeOverride
    if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe' }
    if ($runtimeCommand) { $runtimeCommand.Source }
)
if (-not $resolvedRuntime) {
    throw 'AutoHotkey64.exe was not found. Install AutoHotkey v2, pass -RuntimePath, or set KEYPERSONA_AHK_RUNTIME.'
}

$compilerOverride = if ($CompilerPath) {
    Resolve-ProjectPath $CompilerPath
} else {
    [Environment]::GetEnvironmentVariable('KEYPERSONA_AHK_COMPILER')
}
$runtimeDirectory = Split-Path -Parent $resolvedRuntime
$resolvedCompiler = Find-FirstFile @(
    $compilerOverride
    (Join-Path $sourceRoot 'build-tools\Ahk2Exe.exe')
    (Join-Path (Split-Path -Parent $runtimeDirectory) 'Compiler\Ahk2Exe.exe')
    if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'AutoHotkey\Compiler\Ahk2Exe.exe' }
)
if (-not $resolvedCompiler) {
    throw 'Ahk2Exe.exe was not found. Install the official AutoHotkey compiler, pass -CompilerPath, or set KEYPERSONA_AHK_COMPILER.'
}

foreach ($requiredPath in @($appInfoPath, $sourcePath, $defaultConfigPath, $resolvedRuntime, $resolvedCompiler)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$installWasRunningBeforeBuild = $false
if ($installRoot) {
    $preBuildInstalledPath = Join-Path $installRoot $executableFile
    $installWasRunningBeforeBuild = @(Get-RunningInstancesByPath -ExecutablePath $preBuildInstalledPath).Count -gt 0
}

if (-not $SkipTests) {
    Invoke-CheckedProcess -FilePath $resolvedRuntime -Arguments @('/ErrorStdOut', $sourcePath, '--self-test')
    $sourceTestLog = Join-Path $sourceRoot 'self-test.log'
    if (-not (Test-Path -LiteralPath $sourceTestLog)) {
        throw 'Source self-test did not produce self-test.log.'
    }
    $sourceTestResult = Get-Content -LiteralPath $sourceTestLog -Raw
    Remove-Item -LiteralPath $sourceTestLog -Force
    if ($sourceTestResult -notmatch 'SELF-TEST PASSED') {
        throw "Source self-test did not pass:`n$sourceTestResult"
    }
}

Invoke-CheckedProcess -FilePath $resolvedCompiler -Arguments @(
    '/in', $sourcePath,
    '/out', $outputPath,
    '/base', $resolvedRuntime,
    '/silent', 'verbose'
)
Copy-Item -LiteralPath $defaultConfigPath -Destination (Join-Path $outputRoot $configFile) -Force

if (-not $SkipTests) {
    Invoke-CheckedProcess -FilePath $outputPath -Arguments @('--self-test') -WorkingDirectory $outputRoot
    $compiledTestLog = Join-Path $outputRoot 'self-test.log'
    if (-not (Test-Path -LiteralPath $compiledTestLog)) {
        throw 'Compiled self-test did not produce self-test.log.'
    }
    $compiledTestResult = Get-Content -LiteralPath $compiledTestLog -Raw
    Remove-Item -LiteralPath $compiledTestLog -Force
    if ($compiledTestResult -notmatch 'SELF-TEST PASSED') {
        throw "Compiled self-test did not pass:`n$compiledTestResult"
    }

    $systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $smokeRoot = Join-Path $systemTempRoot ('keypersona-smoke-' + [guid]::NewGuid().ToString('N'))
    $smokeRoot = [System.IO.Path]::GetFullPath($smokeRoot)
    if (-not $smokeRoot.StartsWith($systemTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe smoke-test directory: $smokeRoot"
    }
    New-Item -ItemType Directory -Path $smokeRoot | Out-Null
    try {
        $smokeExe = Join-Path $smokeRoot $executableFile
        Copy-Item -LiteralPath $outputPath -Destination $smokeExe
        Copy-Item -LiteralPath $defaultConfigPath -Destination (Join-Path $smokeRoot $configFile)
        Invoke-CheckedProcess -FilePath $smokeExe -Arguments @('--observe-only', '--smoke-seconds=2') -WorkingDirectory $smokeRoot
    } finally {
        if (Test-Path -LiteralPath $smokeRoot) {
            Remove-Item -LiteralPath $smokeRoot -Recurse -Force
        }
    }
}

$restarted = $false
$installedPath = $null
if ($installRoot) {
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    $installedPath = Join-Path $installRoot $executableFile
    $wasRunning = $installWasRunningBeforeBuild
    try {
        $installed = $false
        for ($attempt = 1; $attempt -le 3 -and -not $installed; $attempt++) {
            $runningInstances = @(Get-RunningInstancesByPath -ExecutablePath $installedPath)
            if ($runningInstances.Count) {
                $wasRunning = $true
                foreach ($instance in $runningInstances) {
                    Stop-Process -Id $instance.ProcessId -Force
                    Wait-Process -Id $instance.ProcessId -ErrorAction SilentlyContinue
                }
            }
            try {
                if (-not [System.IO.Path]::GetFullPath($outputPath).Equals(
                    [System.IO.Path]::GetFullPath($installedPath),
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    Copy-Item -LiteralPath $outputPath -Destination $installedPath -Force
                }
                $installed = $true
            } catch [System.IO.IOException] {
                if ($attempt -ge 3) { throw }
                Start-Sleep -Milliseconds 300
            }
        }
        $installedConfigPath = Join-Path $installRoot $configFile
        if (-not (Test-Path -LiteralPath $installedConfigPath)) {
            Copy-Item -LiteralPath $defaultConfigPath -Destination $installedConfigPath
        }
    } finally {
        if ($wasRunning -and -not $NoRestart -and (Test-Path -LiteralPath $installedPath)) {
            Start-Process -FilePath $installedPath -WorkingDirectory $installRoot -WindowStyle Hidden
            $restarted = $true
        }
    }
}

$packagePath = $null
$checksumsPath = $null
if ($Package) {
    $licensePath = Join-Path $sourceRoot 'LICENSE'
    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        throw 'LICENSE is required when -Package is used.'
    }
    $packageName = "$productName-$version-windows-x64.zip"
    $packagePath = Join-Path $outputRoot $packageName
    $packageStage = Join-Path ([System.IO.Path]::GetTempPath()) ('keypersona-package-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $packageStage | Out-Null
    try {
        foreach ($file in @($outputPath, (Join-Path $sourceRoot 'README.md'),
            (Join-Path $sourceRoot 'CHANGELOG.md'), $licensePath)) {
            Copy-Item -LiteralPath $file -Destination $packageStage
        }
        Copy-Item -LiteralPath (Join-Path $outputRoot $configFile) `
            -Destination (Join-Path $packageStage 'config.example.ini')
        if (Test-Path -LiteralPath $packagePath) {
            Remove-Item -LiteralPath $packagePath -Force
        }
        Compress-Archive -Path (Join-Path $packageStage '*') -DestinationPath $packagePath -CompressionLevel Optimal
        $checksumsPath = Join-Path $outputRoot 'SHA256SUMS.txt'
        $checksumLines = @(
            "$((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant())  $executableFile"
            "$((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant())  $packageName"
        )
        Set-Content -LiteralPath $checksumsPath -Value $checksumLines -Encoding utf8NoBOM
    } finally {
        if (Test-Path -LiteralPath $packageStage) {
            Remove-Item -LiteralPath $packageStage -Recurse -Force
        }
    }
}

$builtFile = Get-Item -LiteralPath $outputPath
[pscustomobject]@{
    Output = $builtFile.FullName
    Installed = $installedPath
    Package = $packagePath
    Checksums = $checksumsPath
    Version = $builtFile.VersionInfo.FileVersion
    SHA256 = (Get-FileHash -LiteralPath $builtFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Restarted = $restarted
}
