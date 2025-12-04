# Self-Repair Routine
# Version 2.6.3
# Date 11/30/2025
# Author: Quintin Sheppard
# Summary: Restages the upgrade if a pending reboot failed to complete.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Windows11Upgrade\\SelfRepair\\SelfRepair.ps1'; Invoke-SelfRepair"

function Invoke-SelfRepair {
    param ([psobject]$State)

    if (-not $privateRoot) {
        $privateRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    }

    Write-Log -Message "Self-repair routine triggered. Attempting to recover staged upgrade." -Level "WARN"

    $restaged = $false
    $repairErrors = @()

    try {
        Check-SystemRequirements | Out-Null
    } catch {
        Write-Log -Message "Self-repair aborted because the system does not meet Windows 11 requirements. Error: $_" -Level "ERROR"
        Write-FailureMarker "Hardware requirements validation failed."
        return $false
    }

    Invoke-UpgradeFailureCleanup -PreserveHealthyIso

    try {
        Ensure-SufficientDiskSpace -MinimumGb 64 -AttemptCleanup -Reason "Windows 11 prerequisites" | Out-Null
        $isoPath = Download-Windows11Iso
        if ($isoPath) {
            $restaged = Stage-UpgradeFromIso -IsoPath $isoPath -SkipCompatCheck
            if (-not $restaged) {
                Write-Log -Message "ISO-based staging retry did not complete successfully." -Level "ERROR"
                $repairErrors += "ISO staging retry returned failure."
            }
        }
    } catch {
        Write-Log -Message "Self-repair could not re-stage the upgrade using ISO. Error: $_" -Level "ERROR"
        $repairErrors += ("Self-repair exception: {0}" -f $_)
    }

    if ($restaged) {
        Clear-FailureMarker
        Register-RebootReminderTasks
        try {
            Register-PostRebootValidationTask
        } catch {
            Write-Log -Message "Failed to register post-reboot validation task during self-repair. Error: $_" -Level "WARN"
        }
        try {
            $toastRoot = if ($privateRoot) { $privateRoot } elseif ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
            $toastScript = Join-Path -Path (Join-Path -Path $toastRoot -ChildPath "Toast-Notification") -ChildPath "Toast-Windows11RebootReminder.ps1"
            $powershellExe = [System.IO.Path]::Combine($env:SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")

            if (Test-Path -Path $toastScript -PathType Leaf) {
                Start-Process -FilePath $powershellExe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$toastScript`"" -WindowStyle Hidden -ErrorAction Stop
                Write-Log -Message ("Reboot reminder toast invoked via {0} during self-repair." -f $toastScript) -Level "INFO"
            } else {
                Write-Log -Message ("Reboot reminder toast script missing at {0}; skipping notification during self-repair." -f $toastScript) -Level "WARN"
            }
        } catch {
            Write-Log -Message "Reboot reminder toast failed during self-repair; continuing without user notification. Error: $_" -Level "WARN"
        }
        try {
            Register-PostRebootValidationTask
        } catch {
            Write-Log -Message "Failed to register post-reboot validation task during self-repair. Error: $_" -Level "WARN"
        }
        if ($State) {
            $latestBoot = Get-LastBootTime
            if ($latestBoot) {
                $State.LastKnownBootTime = $latestBoot.ToString("o")
            }
            $State.Status = "PendingReboot"
            $State.StagedOn = (Get-Date).ToString("o")
            $State.RebootReminders = $true
            if ($script:ReminderRegistrationMode) {
                $State.ReminderMode = $script:ReminderRegistrationMode
            }
            Save-UpgradeState -State $State
        }
    } else {
        $summary = if ($repairErrors.Count -gt 0) { $repairErrors -join "; " } else { "Self-repair failed without a captured reason." }
        Write-FailureMarker ("Self-repair could not restore a reboot-ready upgrade: {0}" -f $summary)
        Write-Log -Message "Self-repair could not create a pending reboot state and recorded a failure marker." -Level "ERROR"
    }

    Write-Log -Message "Self-repair routine completed. Please reboot to reattempt the upgrade." -Level "INFO"
    return $restaged
}
