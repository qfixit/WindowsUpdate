# Windows 11 Upgrade Orchestrator (Modular)
# Quintin Sheppard
# Updated 12/04/2025
# Author: Quintin Sheppard
# Script Version 2.7.1
# Summary: Downloads/validates the Windows 11 25H2 ISO, stages setup.exe /noreboot, writes state markers, self-heals failed runs, and registers reminder/validation tasks.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\Windows11Upgrade.ps1" -VerboseLogging

param(
    [switch]$VerboseLogging
)

if ($VerboseLogging) {
    $VerbosePreference = 'Continue'
}
$ErrorActionPreference = 'Stop'

$script:InstanceMutex = $null
try {
    $createdNew = $false
    $mutexName = "Global\\Windows11UpgradeMutex"
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        # Another instance is already running; exit quietly.
        return
    }
} catch {
    # If mutex creation fails, fall back to a process command-line check; exit quietly if another instance is found.
    try {
        $currentPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
        if ($currentPath) {
            $others = Get-Process -Name "powershell","pwsh" -ErrorAction SilentlyContinue | Where-Object {
                $_.Id -ne $PID -and $_.Path -and $_.Path -match "powershell" -and $_.CommandLine -and ($_.CommandLine -like "*$currentPath*")
            }
            if ($others) {
                return
            }
        }
    } catch {
        # As a last resort, continue.
    }
}

$script:CurrentScriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
$script:PrivateRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($script:CurrentScriptPath) { Split-Path -Path $script:CurrentScriptPath -Parent } else { (Get-Location).ProviderPath }
Set-Variable -Name privateRoot -Value $script:PrivateRoot -Scope Global -Force

$configPath = Join-Path -Path $script:PrivateRoot -ChildPath "UpgradeConfig.ps1"
if (-not (Test-Path -Path $configPath -PathType Leaf)) {
    throw ("Upgrade configuration script not found at {0}" -f $configPath)
}
. $configPath
$config = Set-UpgradeConfig
$logFile = $config.LogFile
$script:UpgradeStateFiles = $config.UpgradeStateFiles

$script:ScriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:IsoDownloadDuration = $null
$script:SetupExecutionDuration = $null
$script:SummaryLogged = $false
$script:ReminderRegistrationMode = $null
$script:VersionBanner = $null

try {
    $versionInfoPath = Join-Path -Path $script:PrivateRoot -ChildPath "Version.txt"
    if (Test-Path -Path $versionInfoPath -PathType Leaf) {
        $versionText = Get-Content -Path $versionInfoPath -TotalCount 1 -ErrorAction Stop
        $script:VersionBanner = $versionText
        Write-Log -Message ("Starting Windows11Upgrade.ps1 ({0})" -f $versionText) -Level "INFO"
    } else {
        Write-Log -Message "Starting Windows11Upgrade.ps1 (Version.txt not found)" -Level "INFO"
    }
} catch {
    # If logging fails this early, continue silently
}

$helperModules = Get-ChildItem -Path $script:PrivateRoot -Filter "*.ps1" -File |
    Where-Object { $_.Name -notin @("Windows11Upgrade.ps1", "UpgradeConfig.ps1") } |
    Sort-Object Name

foreach ($module in $helperModules) {
    try {
        . $module.FullName
    } catch {
        throw ("Failed to load required helper module {0}: {1}" -f $module.FullName, $_)
    }
}

if (Get-Command -Name Clean-BitsTempFiles -ErrorAction SilentlyContinue) {
    Clean-BitsTempFiles
}

try {
    Start-Windows11Upgrade
} catch {
    Write-Log -Message ("Windows 11 upgrade script encountered a fatal error at the entry point: {0}" -f $_) -Level "ERROR"
    try {
        if (Get-Command -Name Clear-UpgradeState -ErrorAction SilentlyContinue) {
            Clear-UpgradeState
        }
    } catch {
        Write-Log -Message ("Unable to clear upgrade state after fatal error. Error: {0}" -f $_) -Level "WARN"
    }
    try {
        if (Get-Command -Name Write-FailureMarker -ErrorAction SilentlyContinue) {
            Write-FailureMarker ("Fatal error at entry point: {0}" -f $_)
        }
    } catch {
        Write-Log -Message ("Unable to record failure marker after fatal error. Error: {0}" -f $_) -Level "WARN"
    }
    throw
} finally {
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch {}
        try { $script:InstanceMutex.Dispose() } catch {}
    }
}
