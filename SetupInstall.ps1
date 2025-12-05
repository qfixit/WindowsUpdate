# Setup Install Helpers
# Version 2.7.0
# Date 12/03/2025
# Author: Quintin Sheppard
# Summary: Mounts ISO, runs setup.exe with progress tracking, applies self-repair for recoverable errors, and records state/markers.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '.\\SetupInstall.ps1'; Stage-UpgradeFromIso -IsoPath 'C:\Temp\WindowsUpdate\Windows11_25H2.iso'"

param()

function Invoke-TimedSetupExecution {
    param(
        [string]$ExecutablePath,
        [string]$Arguments,
        [int]$ProgressTimeoutMinutes = 45
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $progressTracker = @{
        LastProgress   = $null
        SourceDetected = $false
        MissingLogged  = $false
    }
    $lastProgressChange = [datetime]::UtcNow
    $progressSeen = $false
    $stallGuardArmed = $false
    $lastCpuTime = $null
    try {
        $process = Start-Process -FilePath $ExecutablePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden
        if (-not $process) {
            throw "setup.exe did not return a process handle."
        }

        while (-not $process.WaitForExit(5000)) {
            if (Get-Command -Name Write-SetupProgressUpdate -ErrorAction SilentlyContinue) {
                Write-SetupProgressUpdate -Tracker $progressTracker
                if ($progressTracker.LastProgress -ne $null) {
                    $lastProgressChange = [datetime]::UtcNow
                    $progressSeen = $true
                    $stallGuardArmed = $true
                }
            }

            try {
                $procSample = Get-Process -Id $process.Id -ErrorAction Stop
                if ($procSample -and $procSample.TotalProcessorTime -ne $lastCpuTime) {
                    $lastCpuTime = $procSample.TotalProcessorTime
                    $lastProgressChange = [datetime]::UtcNow
                    $stallGuardArmed = $true
                }
            } catch {
                # If sampling fails, keep existing timers.
            }

            if ($ProgressTimeoutMinutes -gt 0 -and $stallGuardArmed) {
                $stallWindow = $lastProgressChange.AddMinutes($ProgressTimeoutMinutes)
                if ([datetime]::UtcNow -gt $stallWindow) {
                    try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
                    throw ("setup.exe progress stalled at {0}% for more than {1} minutes." -f ($progressTracker.LastProgress -as [string]), $ProgressTimeoutMinutes)
                }
            }
        }

        if (Get-Command -Name Write-SetupProgressUpdate -ErrorAction SilentlyContinue) {
            Write-SetupProgressUpdate -Tracker $progressTracker -Force
        }
        return $process
    } finally {
        $stopwatch.Stop()
        $elapsed = $stopwatch.Elapsed
        $script:SetupExecutionDuration = $elapsed
        try {
            if ($elapsed) {
                $durationText = ("{0} ({1} seconds)" -f $elapsed.ToString("hh':'mm':'ss'.'fff", [System.Globalization.CultureInfo]::InvariantCulture), [math]::Round($elapsed.TotalSeconds, 2))
            } else {
                throw "Elapsed duration is null."
            }
        } catch {
            Write-Log -Message ("Failed to format setup.exe duration. Error: {0}" -f $_) -Level "WARN"
            $durationText = "$($elapsed)"
        }
        Write-Log -Message ("setup.exe execution duration: {0}" -f $durationText) -Level "INFO"
    }
}

function Stage-UpgradeFromIso {
    param (
        [string]$IsoPath,
        [switch]$SkipCompatCheck
    )

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        if (-not $SkipCompatCheck) {
            try {
                if (Get-Command -Name Check-SystemRequirements -ErrorAction SilentlyContinue) {
                    Check-SystemRequirements | Out-Null
                }
            } catch {
                Write-Log -Message "System does not meet Windows 11 requirements. Aborting. Error: $_" -Level "ERROR"
                Write-FailureMarker "Hardware requirements validation failed."
                return $false
            }
        }

        if (-not (Test-Path -Path $IsoPath)) {
            Write-Log -Message "ISO not found at $IsoPath. Aborting." -Level "ERROR"
            Write-FailureMarker "ISO not found at $IsoPath"
            return $false
        }

        if (-not (Get-Command -Name Mount-DiskImage -ErrorAction SilentlyContinue)) {
            Write-Log -Message "Mount-DiskImage cmdlet not available on this system. Cannot continue." -Level "ERROR"
            Write-ErrorCode -Code 13 -Detail "Mount-DiskImage cmdlet unavailable"
        }

        $setupLogPath = Join-Path -Path $stateDirectory -ChildPath "SetupLogs"
        Ensure-Directory -Path $setupLogPath

        $maxAttempts = 2
        $attempt = 0
        $success = $false
        $failureReason = $null
        $exitCode = $null
        $recoveryAttempted = $false
        $lastExitCodeHex = $null

        while ($attempt -lt $maxAttempts -and -not $success) {
            $attempt++
            $mountedImage = $null
            try {
                $mountedImage = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
                $volume = $mountedImage | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1

                if (-not $volume) {
                    throw "Mounted ISO did not expose a drive letter."
                }

                $driveLetter = $volume.DriveLetter
                $setupPath = "{0}:\setup.exe" -f $driveLetter

                if (-not (Test-Path -Path $setupPath)) {
                    throw "setup.exe not found on mounted ISO ($setupPath)."
                }

                $arguments = if ($SetupExeArguments) { ($SetupExeArguments -f $setupLogPath) } else { "/Auto Upgrade /copylogs `"$setupLogPath`" /DynamicUpdate Enable /EULA accept /noreboot /Quiet" }

                Write-Log -Message ("Launching setup.exe from ISO with arguments: {0}" -f $arguments) -Level "INFO"
                $process = Invoke-TimedSetupExecution -ExecutablePath $setupPath -Arguments $arguments
                $exitCode = $process.ExitCode

                $exitCodeHex = "0x????????"
                if ($null -ne $exitCode) {
                    $exitCodeValue = [int64]0
                    if (-not [int64]::TryParse($exitCode.ToString(), [ref]$exitCodeValue)) {
                        try { $exitCodeValue = [int64]$exitCode } catch { $exitCodeValue = [int64]0 }
                    }

                    $masked = $exitCodeValue -band 0xFFFFFFFFL
                    $exitCodeHex = "0x{0}" -f ([uint32]$masked).ToString("X8")
                }

                Write-Log -Message ("setup.exe exited with code {0}." -f $exitCodeHex) -Level "INFO"
                $lastExitCodeHex = $exitCodeHex

                $successCodes = @(0, 3010, 1641)
                if ($successCodes -contains $exitCode) {
                    $success = $true
                } else {
                    Write-Log -Message "Setup.exe reported a failure staging the upgrade." -Level "ERROR"
                    $failureReason = "setup.exe exited with code {0}" -f $exitCodeHex
                }
            } catch {
                Write-Log -Message "Failed to stage upgrade using ISO. Error: $_" -Level "ERROR"
                $failureReason = "ISO staging threw exception: $_"
            } finally {
                if ($mountedImage) {
                    try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue } catch { }
                }
            }

            if ($success) { break }

            if (-not $success -and -not $recoveryAttempted) {
                $codeForLookup = if ($exitCodeHex -and $exitCodeHex -notmatch "\?") { $exitCodeHex } elseif ($exitCode) { $exitCode } else { $failureReason }
                $errorInfo = $null
                if (Get-Command -Name Get-ErrorCodeInfo -ErrorAction SilentlyContinue) {
                    $errorInfo = Get-ErrorCodeInfo -Code $codeForLookup
                }

                if ($errorInfo -and $errorInfo.Recoverable -and $errorInfo.Command) {
                    $recoveryAttempted = $true
                    try {
                        Write-Log -Message ("Attempting self-repair for {0}: {1}" -f $codeForLookup, $errorInfo.Command) -Level "WARN"
                        $cmdPath = Join-Path -Path $env:SystemRoot -ChildPath "System32\\cmd.exe"
                        $output = & $cmdPath /c $errorInfo.Command 2>&1
                        $procExit = $LASTEXITCODE
                        Write-Log -Message ("Self-repair output for {0}: {1}" -f $codeForLookup, ($output -join "; ")) -Level "INFO"
                        if ($procExit -eq 0) {
                            Write-Log -Message ("Self-repair command succeeded for {0}; retrying staging." -f $codeForLookup) -Level "INFO"
                            $failureReason = $null
                            $exitCode = $null
                            Start-Sleep -Seconds 5
                            continue
                        } else {
                            Write-Log -Message ("Self-repair command for {0} exited with code {1}; continuing failure handling." -f $codeForLookup, $procExit) -Level "WARN"
                        }
                    } catch {
                        Write-Log -Message ("Self-repair command for {0} failed. Error: {1}" -f $codeForLookup, $_) -Level "WARN"
                    }
                }
            }

            if ($failureReason -match "(?i)corrupt|unreadable|0xc1900107" -or $exitCode -eq 0xC1900107) {
                try {
                    Remove-Item -Path $IsoPath -Force -ErrorAction Stop
                    Write-Log -Message "Removed suspected corrupt ISO at $IsoPath so the next attempt will download a fresh copy." -Level "WARN"
                } catch {
                    Write-Log -Message "Failed to delete suspected corrupt ISO at $IsoPath. Error: $_" -Level "WARN"
                }
                if (Test-Path -Path $isoHashCacheFile) {
                    Remove-Item -Path $isoHashCacheFile -Force -ErrorAction SilentlyContinue
                }
            }

            if ($exitCode -eq 0xC1900107) {
                $btPath = Join-Path -Path $env:SystemDrive -ChildPath "$WINDOWS.~BT"
                try {
                    if (Test-Path -Path $btPath) {
                        Remove-Item -Path $btPath -Recurse -Force -ErrorAction Stop
                        Write-Log -Message ("Removed stale setup directory {0} after setup error 0xC1900107." -f $btPath) -Level "WARN"
                    }
                } catch {
                    Write-Log -Message ("Unable to remove stale setup directory {0}. Error: {1}" -f $btPath, $_) -Level "WARN"
                }
            }

            if ($exitCode -eq 0xC1900208) {
                Write-Log -Message "Setup.exe exited with 0xC1900208 (app/driver compatibility block). Technician review required." -Level "ERROR"
                break
            }

            if ($attempt -lt $maxAttempts) {
                Write-Log -Message ("Retrying ISO staging (attempt {0}/{1}) after failure." -f ($attempt + 1), $maxAttempts) -Level "WARN"
                try {
                    $IsoPath = Download-Windows11Iso
                } catch {
                    Write-Log -Message ("Retry download failed during staging recovery. Error: {0}" -f $_) -Level "ERROR"
                    break
                }
            }
        }

        if ($success) {
            Clear-FailureMarker
            return $true
        }

        if (-not $failureReason) {
            $failureReason = "ISO staging failed for unspecified reason."
        }

        $codeForLookup = if ($exitCodeHex -and $exitCodeHex -notmatch "\?") { $exitCodeHex } elseif ($exitCode) { $exitCode } else { $failureReason }
        $info = $null
        if (Get-Command -Name Get-ErrorCodeInfo -ErrorAction SilentlyContinue) {
            $info = Get-ErrorCodeInfo -Code $codeForLookup
        }
        if ($info -and $info.Title -and $info.Title -ne "Unknown error") {
            Write-Log -Message ("Error Title: {0}." -f $info.Title) -Level "INFO"
            Write-Log -Message ("Error Description: {0}." -f $info.Description) -Level "INFO"
            if ($info.Remediation) { Write-Log -Message ("Error Remediation: {0}" -f $info.Remediation) -Level "INFO" }
            if ($info.PSObject.Properties.Match("Recoverable").Count -gt 0) {
                Write-Log -Message ("Error Recoverable: {0}" -f $info.Recoverable) -Level "INFO"
            }
            $failureReason = ("setup.exe exited with {0}. {1}. {2}" -f $codeForLookup, $info.Title, $info.Description)
            if ($info.Remediation) {
                $failureReason = "$failureReason. Remediation: $($info.Remediation)"
            }
        } else {
            $failureReason = ("setup.exe exited with {0}. {1}" -f $codeForLookup, $failureReason)
        }

        Write-FailureMarker $failureReason
        try {
            if (Get-Command -Name Clear-UpgradeState -ErrorAction SilentlyContinue) {
                Clear-UpgradeState
            }
        } catch {
            Write-Log -Message ("Unable to clear upgrade state after staging failure. Error: {0}" -f $_) -Level "WARN"
        }

        if ($recoveryAttempted -and $lastExitCodeHex -and $exitCodeHex -and $exitCodeHex -eq $lastExitCodeHex) {
            Write-Log -Message ("Recoverable error {0} persisted after self-repair attempt; marking failure." -f $exitCodeHex) -Level "ERROR"
        }

        return $false
    } catch {
        Write-Log -Message ("Stage-UpgradeFromIso encountered a fatal error. Error: {0}" -f $_) -Level "ERROR"
        Write-FailureMarker ("ISO staging failed unexpectedly: {0}" -f $_)
        try { if (Get-Command -Name Clear-UpgradeState -ErrorAction SilentlyContinue) { Clear-UpgradeState } } catch { }
        return $false
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
}
