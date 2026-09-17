#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$installRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $sourceRoot))
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
$sourcePath = Join-Path $sourceRoot (Get-AppInfoValue -Name 'SourceFile')
$outputPath = Join-Path $installRoot (Get-AppInfoValue -Name 'ExecutableFile')
$defaultConfigPath = Join-Path $sourceRoot (Get-AppInfoValue -Name 'ConfigFile')
$installedConfigPath = Join-Path $installRoot (Get-AppInfoValue -Name 'ConfigFile')
$compilerPath = Join-Path $installRoot 'build-tools\Ahk2Exe.exe'
$runtimeOverride = [Environment]::GetEnvironmentVariable('IME_MEMORY_AHK_RUNTIME')
$runtimeCommand = Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue
$runtimeCandidates = @(
    $runtimeOverride
    if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe' }
    if ($runtimeCommand) { $runtimeCommand.Source }
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
$runtimePath = $runtimeCandidates | Select-Object -First 1

if (-not $runtimePath) {
    throw 'AutoHotkey64.exe was not found. Install AutoHotkey v2 or set IME_MEMORY_AHK_RUNTIME.'
}

foreach ($requiredPath in @($sourcePath, $defaultConfigPath, $compilerPath, $runtimePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $sourceRoot
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

$executableName = [System.IO.Path]::GetFileName($outputPath)
$runningInstances = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq $executableName -and
            $_.ExecutablePath -and
            [System.IO.Path]::GetFullPath($_.ExecutablePath).Equals(
                $outputPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
)
$wasRunning = $runningInstances.Count -gt 0
foreach ($instance in $runningInstances) {
    Stop-Process -Id $instance.ProcessId -Force
    Wait-Process -Id $instance.ProcessId -ErrorAction SilentlyContinue
}

$buildSucceeded = $false
try {
    if (-not $SkipTests) {
        Invoke-CheckedProcess -FilePath $runtimePath -Arguments @('/ErrorStdOut', $sourcePath, '--self-test')
        $sourceTestLog = Join-Path $sourceRoot 'self-test.log'
        if (Test-Path -LiteralPath $sourceTestLog) {
            $testResult = Get-Content -LiteralPath $sourceTestLog -Raw
            Remove-Item -LiteralPath $sourceTestLog -Force
            if ($testResult -notmatch 'SELF-TEST PASSED') {
                throw "Source self-test did not pass:`n$testResult"
            }
        }
    }

    Invoke-CheckedProcess -FilePath $compilerPath -Arguments @(
        '/in', $sourcePath,
        '/out', $outputPath,
        '/base', $runtimePath,
        '/silent', 'verbose'
    )

    if (-not (Test-Path -LiteralPath $installedConfigPath)) {
        Copy-Item -LiteralPath $defaultConfigPath -Destination $installedConfigPath
    }

    if (-not $SkipTests) {
        Invoke-CheckedProcess -FilePath $outputPath -Arguments @('--observe-only', '--smoke-seconds=2')
    }

    $buildSucceeded = $true
} finally {
    if ($wasRunning -and -not $NoRestart -and (Test-Path -LiteralPath $outputPath)) {
        Start-Process -FilePath $outputPath -WorkingDirectory $installRoot -WindowStyle Hidden
    }
}

if ($buildSucceeded) {
    $builtFile = Get-Item -LiteralPath $outputPath
    [pscustomobject]@{
        Output = $builtFile.FullName
        Version = $builtFile.VersionInfo.FileVersion
        SHA256 = (Get-FileHash -LiteralPath $builtFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Restarted = $wasRunning -and -not $NoRestart
    }
}
