# Start-Windows11Upgrade Orchestration
# Version 2.7.1
# Date 12/04/2025
# Author: Quintin Sheppard
# Summary: Implements the Expected Workflow to stage the Windows 11 upgrade, handle reboots, and self-heal failures.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Windows11Upgrade\\Start-Windows11Upgrade.ps1'; Start-Windows11Upgrade"

function Start-Windows11Upgrade {
try {
    $autoRebootPending = $false

    function Invoke-AutoReboot {
        param([bool]$ShouldReboot)

        if (-not $AutoReboot -or -not $ShouldReboot) {
            return
        }

        Write-Log -Message "AutoReboot enabled; initiating immediate restart to continue Windows 11 upgrade." -Level "INFO"
        try {
            Start-Process -FilePath "shutdown.exe" -ArgumentList '/r /t 0 /c "Windows 11 upgrade staged; rebooting now."' -WindowStyle Hidden -ErrorAction Stop
        } catch {
            Write-Log -Message ("Failed to trigger auto reboot. Error: {0}" -f $_) -Level "ERROR"
        }
    }

    $banner = if ($script:VersionBanner) { $script:VersionBanner } else { "Version unknown" }
    Write-Log ("Windows 11 25H2 upgrade script started. {0}" -f $banner)

    if (-not (Ensure-SentinelAgentCompatible)) {
        Remove-RebootReminderTasks
        Clear-UpgradeState
        Complete-Execution -Message "Windows 11 25H2 upgrade script finished."
        return
    }

    $state = Get-UpgradeState
    $currentBootTime = Get-LastBootTime
    $needsStaging = $true
    $pendingHandledViaSelfRepair = $false
    $pendingStateDetected = $false

    if ($currentBootTime) {
        Write-Log -Message ("Current boot time: {0:o}" -f $currentBootTime) -Level "VERBOSE"
    }

    if ($state -and $state.Status -eq "UpgradeFailed" -and $state.PSObject.Properties.Match("Reason").Count -gt 0) {
        $reason = $state.Reason
        if ($reason) {
            Write-Log -Message ("Previous upgrade failure detected: {0}" -f $reason) -Level "WARN"
        }
        Invoke-UpgradeFailureCleanup -PreserveHealthyIso
        $state = $null
    }

    if (-not $state -or $state.Status -eq "ScriptRunning") {
        $scriptState = [pscustomobject]@{
            Status            = "ScriptRunning"
            StartedOn         = (Get-Date).ToString("o")
            LastKnownBootTime = if ($currentBootTime) { $currentBootTime.ToString("o") } else { $null }
            ProcessId         = $PID
        }
        Save-UpgradeState -State $scriptState
        $state = $scriptState
    }

    if ($state -and $state.Status -eq "ScriptRunning" -and $state.LastKnownBootTime) {
        $bootChanged = $false
        try {
            $recordedBoot = [datetime]::Parse($state.LastKnownBootTime)
            if ($currentBootTime -and $currentBootTime -gt $recordedBoot.AddSeconds(30)) {
                $bootChanged = $true
            }
        } catch {
            $bootChanged = $false
        }
        if ($bootChanged) {
            Write-Log -Message "Detected interrupted run (ScriptRunning persisted across reboot). Initiating self-repair restage." -Level "WARN"
            $restaged = Invoke-SelfRepair -State $state
            $pendingHandledViaSelfRepair = $true
            if (-not $restaged) {
                $needsStaging = $true
            } else {
                $needsStaging = $false
            }
        }
    }

    if (Test-IsWindows11) {
        Write-Log -Message "Windows 11 already detected on this device." -Level "INFO"
        Invoke-PostUpgradeCleanup -State $state
        Complete-Execution -Message "Windows 11 25H2 upgrade script finished."
        Invoke-AutoReboot -ShouldReboot $autoRebootPending
        return
    }

    if ($state -and $state.Status -eq "PendingReboot") {
        $pendingStateDetected = $true
        $needsStaging = $false
        if ($AutoReboot) {
            $autoRebootPending = $true
        }
        Write-Log -Message "Pending reboot state detected from previous run." -Level "INFO"

        $deviceRestartedAfterStaging = $false
        if ($state.LastKnownBootTime) {
            try {
                $recordedBoot = [datetime]::Parse($state.LastKnownBootTime)
            } catch {
                $recordedBoot = $null
            }

            if ($recordedBoot -and $currentBootTime -and $currentBootTime -gt $recordedBoot.AddSeconds(30)) {
                $deviceRestartedAfterStaging = $true
            }
        }

        if ($deviceRestartedAfterStaging) {
            Write-Log -Message "Device has rebooted since staging but upgrade did not complete. Initiating self-repair." -Level "WARN"
            $restaged = Invoke-SelfRepair -State $state
            $pendingHandledViaSelfRepair = $true
            if (-not $restaged) {
                $needsStaging = $true
            }
        } else {
            Write-Log -Message "Awaiting reboot to finalize the upgrade." -Level "VERBOSE"
            Clear-FailureMarker
            Register-RebootReminderTasks
            Register-PostRebootValidationTask
        }
    }

    if ($needsStaging) {
        Write-Log -Message "Pre-flight checks completed; beginning staging pipeline." -Level "INFO"
        try {
            Check-SystemRequirements | Out-Null
        } catch {
            Write-Log -Message "System requirements validation failed prior to ISO download. Error: $_" -Level "ERROR"
            Write-FailureMarker "Hardware requirements validation failed."
            Complete-Execution -Message "Windows 11 25H2 upgrade script finished."
            return
        }

        Write-Log -Message "System requirements confirmed; proceeding to ISO download and staging." -Level "INFO"

        try {
            Register-PostRebootValidationTask
        } catch {
            Write-Log -Message "Failed to register post-reboot validation task before download. Error: $_" -Level "WARN"
        }

        try {
            $isoPath = Download-Windows11Iso
            $stagingResult = Stage-UpgradeFromIso -IsoPath $isoPath -SkipCompatCheck

            if ($stagingResult) {
                Clear-FailureMarker
                if ($AutoReboot) {
                    $autoRebootPending = $true
                }

                $stateToSave = [pscustomobject]@{
                    Status            = "PendingReboot"
                    StagedOn          = (Get-Date).ToString("o")
                    LastKnownBootTime = if ($currentBootTime) { $currentBootTime.ToString("o") } else { (Get-Date).ToString("o") }
                    RebootReminders   = $true
                }

                try {
                    Register-PostRebootValidationTask
                } catch {
                    Write-Log -Message "Failed to register post-reboot validation task after staging. Error: $_" -Level "WARN"
                }

                try {
                    Register-RebootReminderTasks
                } catch {
                    Write-Log -Message "Failed to register reboot reminder tasks after staging. Error: $_" -Level "WARN"
                }

                if ($script:ReminderRegistrationMode) {
                    $stateToSave | Add-Member -NotePropertyName "ReminderMode" -NotePropertyValue $script:ReminderRegistrationMode -Force
                } else {
                    $stateToSave | Add-Member -NotePropertyName "ReminderMode" -NotePropertyValue "ImmediateUser" -Force
                }

                Save-UpgradeState -State $stateToSave
                try {
                    $toastRoot = if ($privateRoot) { $privateRoot } elseif ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
                    $toastScript = Join-Path -Path (Join-Path -Path $toastRoot -ChildPath "Toast-Notification") -ChildPath "Toast-Windows11RebootReminder.ps1"
                    $powershellExe = [System.IO.Path]::Combine($env:SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")

                    if (Test-Path -Path $toastScript -PathType Leaf) {
                        Start-Process -FilePath $powershellExe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$toastScript`"" -WindowStyle Hidden -ErrorAction Stop
                        Write-Log -Message ("Reboot reminder toast invoked via {0}." -f $toastScript) -Level "INFO"
                    } else {
                        Write-Log -Message ("Reboot reminder toast script missing at {0}; skipping notification." -f $toastScript) -Level "WARN"
                    }
                } catch {
                    Write-Log -Message ("Reboot reminder toast failed; script={0}; error={1}" -f $toastScript, $_) -Level "WARN"
                }
            } else {
                Write-Log -Message "Staging routine did not complete successfully." -Level "ERROR"
                if (-not (Test-Path -Path $failureMarker)) {
                    try {
                        Write-FailureMarker "Upgrade staging failed. See Windows11UpgradeLog.txt for details."
                    } catch {
                        Write-Log -Message ("Failed to record failure marker after staging failure. Error: {0}" -f $_) -Level "WARN"
                    }
                }
                try {
                    Clear-UpgradeState
                    Write-Log -Message "Cleared ScriptRunning/PendingReboot sentinels after staging failure to surface failure marker on next run." -Level "VERBOSE"
                } catch {
                    Write-Log -Message ("Failed to clear upgrade state after staging failure. Error: {0}" -f $_) -Level "WARN"
                }

                if (Test-Path -Path $failureMarker) {
                    try {
                        $failureReason = (Get-Content -Path $failureMarker -Raw -ErrorAction Stop).Trim()
                        if ($failureReason) {
                            Write-Log -Message ("Staging failure reason preserved in marker: {0}" -f $failureReason) -Level "WARN"
                        }
                    } catch {
                        Write-Log -Message ("Unable to read failure marker after staging failure. Error: {0}" -f $_) -Level "WARN"
                    }
                }

                $detailForExit = if ($failureReason) { $failureReason } else { "Upgrade staging failed." }
                Write-ErrorCode -Code 1 -Detail $detailForExit
                return
            }
        } catch {
            Write-Log -Message "Unhandled error during staging: $_" -Level "ERROR"
            throw
        }
    } elseif (-not $pendingHandledViaSelfRepair) {
        if ($pendingStateDetected) {
            Write-Log -Message "Upgrade staging already in place. No further action required until reboot." -Level "INFO"
        } else {
            Write-Log -Message "A previous staging attempt is pending review. Scheduling reboot reminders." -Level "INFO"
            Clear-FailureMarker
            Register-RebootReminderTasks
            Register-PostRebootValidationTask
        }
    }

    Complete-Execution -Message "Windows 11 upgrade script finished."
    Invoke-AutoReboot -ShouldReboot $autoRebootPending
} catch {
    Write-Log -Message "Windows 11 upgrade script encountered an unexpected interruption or error: $_" -Level "ERROR"
    $failureReason = ("Unexpected termination: {0}" -f $_)
    try {
        Clear-UpgradeState
    } catch {
        Write-Log -Message ("Unable to clear upgrade state after interruption. Error: {0}" -f $_) -Level "WARN"
    }

    try {
        Write-FailureMarker $failureReason
    } catch {
        Write-Log -Message ("Failed to record failure marker during interruption handling. Error: {0}" -f $_) -Level "WARN"
    }
    try {
        Invoke-UpgradeFailureCleanup -PreserveHealthyIso
    } catch {
        Write-Log -Message "Cleanup after failure encountered an additional error: $_" -Level "WARN"
    }

    Complete-Execution -Message "Windows 11 25H2 upgrade script finished with errors."
}
}
