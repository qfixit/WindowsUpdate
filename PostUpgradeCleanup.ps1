# Post-Upgrade Cleanup Helpers
# Version 2.7.1
# Date 12/04/2025
# Author: Quintin Sheppard
# Summary: Validates post-reboot state, removes reminder/runonce entries, and deletes staging artifacts when Windows 11 is present.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Windows11Upgrade\\PostUpgradeCleanup.ps1'; Invoke-PostUpgradeCleanup"

param()

function Invoke-PostUpgradeCleanup {
    param([psobject]$State)

    Write-Log -Message "Starting post-upgrade cleanup workflow." -Level "INFO"

    $pendingRebootPath = if ($script:UpgradeStateFiles.ContainsKey("PendingReboot")) { $script:UpgradeStateFiles["PendingReboot"] } else { Join-Path -Path $stateDirectory -ChildPath "PendingReboot.txt" }
    $scriptRunningPath = if ($script:UpgradeStateFiles.ContainsKey("ScriptRunning")) { $script:UpgradeStateFiles["ScriptRunning"] } else { Join-Path -Path $stateDirectory -ChildPath "ScriptRunning.txt" }

    $isWin11 = $false
    try {
        $isWin11 = Test-IsWindows11
    } catch {
        Write-Log -Message ("Post-upgrade cleanup could not confirm OS version. Error: {0}" -f $_) -Level "WARN"
    }

    $hasPendingState = @($pendingRebootPath, $scriptRunningPath) | Where-Object { Test-Path -Path $_ -PathType Leaf } | Measure-Object | Select-Object -ExpandProperty Count

    if (-not $isWin11) {
        if (-not $hasPendingState) {
            Write-Log -Message "Windows 11 not detected and no pending state present; skipping cleanup invocation." -Level "WARN"
            return $false
        }

        Write-Log -Message "Windows 11 not detected after reboot; marking upgrade failure and preserving staging." -Level "WARN"
        Write-FailureMarker "Post-reboot validation: Windows 11 not detected after reboot."
        foreach ($path in @($pendingRebootPath, $scriptRunningPath)) {
            if (Test-Path -Path $path) {
                try { Remove-Item -Path $path -Force -ErrorAction Stop } catch { Write-Log -Message ("Unable to remove state file {0}. Error: {1}" -f $path, $_) -Level "WARN" }
            }
        }
        return $false
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
        try { Clear-UpgradeState } catch { Write-Log -Message ("Unable to clear upgrade state during cleanup. Error: {0}" -f $_) -Level "WARN" }
        try { Clear-FailureMarker } catch { Write-Log -Message ("Unable to clear failure marker during cleanup. Error: {0}" -f $_) -Level "WARN" }
        try { Remove-RebootReminderTasks } catch { Write-Log -Message ("Failed to remove reboot reminder tasks during cleanup. Error: {0}" -f $_) -Level "WARN" }
        try { Remove-PostRebootValidationTask } catch { Write-Log -Message ("Failed to remove post-reboot validation run-once. Error: {0}" -f $_) -Level "WARN" }
        Write-Log -Message "Post-upgrade cleanup complete; staging artifacts removed." -Level "INFO"
        return $true
    }

    Write-Log -Message ("State directory {0} could not be removed after retries; leaving validation run-once in place to retry cleanup." -f $stateDirectory) -Level "WARN"
    try { Register-PostRebootValidationTask } catch { Write-Log -Message ("Failed to refresh post-reboot validation run-once after cleanup failure. Error: {0}" -f $_) -Level "WARN" }
    return $false
}
