# Post-Upgrade Cleanup (RMM Trigger)
# Version 2.7.1
# Date 12/04/2025
# Author: Quintin Sheppard
# Summary: Reuses the shared post-upgrade cleanup helper to avoid drift between RMM-triggered and run-once validation flows.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Fallback defaults in case config cannot be loaded
$stateDirectory = "C:\Temp\WindowsUpdate"
$failureMarker  = "C:\Temp\WindowsUpdate\UpgradeFailed.txt"
$logFile = "C:\Windows11UpgradeLog.txt"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","VERBOSE")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp [$Level] $Message"
    try {
        $directory = Split-Path -Path $logFile -Parent
        if ($directory -and -not (Test-Path -Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    } catch {}

    switch ($Level) {
        "ERROR"   { Write-Error $line }
        "WARN"    { Write-Warning $line }
        "VERBOSE" { Write-Verbose $line }
        default   { Write-Information -MessageData $line -InformationAction Continue }
    }
    if ($Level -ne "VERBOSE") { Write-Verbose $line }
}

try {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $configPath = Join-Path -Path $root -ChildPath "UpgradeConfig.ps1"
    if (Test-Path -Path $configPath -PathType Leaf) {
        . $configPath
        try { $config = Set-UpgradeConfig } catch {}
    }

    foreach ($helper in @("MainFunctions.ps1", "UpgradeState.ps1", "ScheduledTasks.ps1", "Detection.ps1", "PostUpgradeCleanup.ps1")) {
        $helperPath = Join-Path -Path $root -ChildPath $helper
        if (Test-Path -Path $helperPath -PathType Leaf) {
            . $helperPath
        }
    }

    if (Get-Command -Name Invoke-PostUpgradeCleanup -ErrorAction SilentlyContinue) {
        Invoke-PostUpgradeCleanup | Out-Null
        return
    }

    Write-Log -Message "Shared Invoke-PostUpgradeCleanup not available; running local fallback cleanup." -Level "WARN"
} catch {
    Write-Log -Message ("Failed to load shared cleanup helpers. Error: {0}" -f $_) -Level "WARN"
}

# Local fallback to ensure RMM cleanup still runs if shared helper cannot be loaded.
try {
    Write-Log -Message "Post-reboot cleanup (fallback) started." -Level "INFO"

    $pendingRebootPath = Join-Path -Path $stateDirectory -ChildPath "PendingReboot.txt"
    $scriptRunningPath = Join-Path -Path $stateDirectory -ChildPath "ScriptRunning.txt"
    $hasPendingState = (Test-Path -Path $pendingRebootPath) -or (Test-Path -Path $scriptRunningPath)

    $isWin11 = $false
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os.Caption -and ($os.Caption -match "Windows 11")) { $isWin11 = $true }
        if ($os.BuildNumber -and ([int]$os.BuildNumber -ge 22000)) { $isWin11 = $true }
    } catch {
        Write-Log -Message "OS detection failed in fallback cleanup; assuming not Windows 11. Error: $_" -Level "WARN"
    }

    if (-not $isWin11) {
        if (-not $hasPendingState) {
            Write-Log -Message "Windows 11 not detected and no pending upgrade state present; skipping cleanup invocation." -Level "WARN"
            return
        }

        Write-Log -Message "Windows 11 not detected; marking upgrade as failed and preserving staging." -Level "WARN"
        try {
            if (-not (Test-Path -Path $stateDirectory)) {
                New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
            }
            $entry = "{0:yyyy-MM-dd HH:mm:ss} - {1}" -f (Get-Date), "Post-reboot validation: Windows 11 not detected after reboot."
            Set-Content -Path $failureMarker -Value $entry -Encoding UTF8
        } catch {}
        foreach ($path in @($scriptRunningPath, $pendingRebootPath)) {
            if (Test-Path -Path $path) {
                try { Remove-Item -Path $path -Force -ErrorAction Stop } catch { Write-Log -Message ("Unable to remove state file {0}. Error: {1}" -f $path, $_) -Level "WARN" }
            }
        }
        return
    }

    $removed = $false
    if (Test-Path -Path $stateDirectory -PathType Container) {
        foreach ($attempt in 1..3) {
            try {
                Remove-Item -Path $stateDirectory -Recurse -Force -ErrorAction Stop
                Write-Log -Message ("Removed state directory {0} on attempt {1}." -f $stateDirectory, $attempt) -Level "INFO"
                $removed = $true
                break
            } catch {
                Write-Log -Message ("Attempt {0} to remove {1} failed. Error: {2}" -f $attempt, $stateDirectory, $_) -Level "WARN"
                Start-Sleep -Seconds 3
            }
        }
    } else {
        Write-Log -Message ("State directory {0} not found; nothing to remove." -f $stateDirectory) -Level "VERBOSE"
        $removed = $true
    }

    if ($removed) {
        Write-Log -Message "Post-reboot cleanup complete (fallback). Log file retained." -Level "INFO"
    } else {
        try {
            $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\WindowsPowerShell\v1.0\powershell.exe"
            $runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            $runOnceName = "Win11_PostCleanup_Retry"
            $cmd = ('"{0}" -ExecutionPolicy Bypass -NoProfile -File "{1}"' -f $powershellExe, $PSCommandPath)
            New-Item -Path $runOnceKey -Force | Out-Null
            Set-ItemProperty -Path $runOnceKey -Name $runOnceName -Value $cmd -Force
            Write-Log -Message ("State directory {0} still present; registered RunOnce {1} to retry cleanup." -f $stateDirectory, $runOnceName) -Level "WARN"
        } catch {
            Write-Log -Message ("State directory {0} still present and RunOnce retry could not be registered. Error: {1}" -f $stateDirectory, $_) -Level "ERROR"
        }
    }
} catch {
    Write-Log -Message ("Post-reboot cleanup (fallback) encountered an error: {0}" -f $_) -Level "ERROR"
    throw
}
