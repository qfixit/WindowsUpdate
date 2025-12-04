# ISO Download and Setup Helpers
# Version 2.7.0
# Date 12/03/2025
# Author: Quintin Sheppard
# Summary: Disk space checks, ISO health/hash validation, BITS download wrapper, and setup.exe staging helpers for the Windows 11 upgrade.
# Example test (download only): powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\Windows11Upgrade\ISO Download\IsoDownload.ps1'; Invoke-TimedIsoDownload -SourceUrl 'https://example.com/test.iso' -DestinationPath 'C:\Temp\WindowsUpdate\Test.iso'"

param()

function Invoke-DirectIsoDownload {
    param(
        [string]$SourceUrl,
        [string]$DestinationPath
    )
    try {
        Write-Log -Message "BITS unavailable; falling back to Invoke-WebRequest for ISO download (may be slower)." -Level "WARN"
        if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
            Show-UpgradeProgressToast -Phase Download -PercentComplete 0 -Status "Downloading..."
        }
        Invoke-WebRequest -Uri $SourceUrl -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        Write-Log -Message "Invoke-WebRequest ISO download completed." -Level "INFO"
        if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
            Show-UpgradeProgressToast -Phase Download -PercentComplete 100 -Status "Download complete"
        }
    } catch {
        Write-Log -Message "Invoke-WebRequest ISO download failed. Error: $_" -Level "ERROR"
        Write-FailureMarker ("ISO download failed or was interrupted: {0}" -f $_)
        throw
    }
}

function Clean-BitsTempFiles {
    try {
        if (Test-Path -Path $stateDirectory) {
            Get-ChildItem -Path $stateDirectory -Filter "BIT*.tmp" -File -ErrorAction Stop | ForEach-Object {
                try { Remove-Item -Path $_.FullName -Force -ErrorAction Stop } catch {}
            }
        }
    } catch {
        Write-Log -Message ("Unable to clean BITS temp files. Error: {0}" -f $_) -Level "WARN"
    }
}

function Invoke-TimedIsoDownload {
    param(
        [string]$SourceUrl,
        [string]$DestinationPath
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $job = $null
    $lastPercentLogged = -5
    $downloadCompleted = $false
    $bitsAttempted = $false
    try {
        if (Get-Command -Name Clean-BitsTempFiles -ErrorAction SilentlyContinue) {
            Clean-BitsTempFiles
        }
        try {
            $bitsService = Get-Service -Name BITS -ErrorAction Stop
            if ($bitsService.Status -ne 'Running') {
                Start-Service -Name BITS -ErrorAction Stop
                Write-Log -Message "Started BITS service to enable ISO download." -Level "INFO"
            }
        } catch {
            Write-Log -Message "BITS service not available. Falling back to Invoke-WebRequest." -Level "WARN"
            Invoke-DirectIsoDownload -SourceUrl $SourceUrl -DestinationPath $DestinationPath
            return
        }

        $job = Start-BitsTransfer -Source $SourceUrl -Destination $DestinationPath -DisplayName "Windows11ISO" -Description "Windows 11 ISO download" -Asynchronous
        $bitsAttempted = $true
        if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
            Show-UpgradeProgressToast -Phase Download -PercentComplete 0 -Status "Downloading..."
        }

        while ($true) {
            Start-Sleep -Seconds 5
            $status = $null
            try {
                $status = Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop
            } catch {
                $message = $_.Exception.Message
                if ($message -match "(?i)cannot find a bits transfer that has the specified id") {
                    Write-Log -Message ("BITS job {0} already finalized when polled; continuing quietly." -f $job.JobId) -Level "VERBOSE"
                    break
                } else {
                    if ($message -match "(?i)shutdown is in progress") {
                        Write-ErrorCode -Code 10 -Detail $message
                    }
                    Write-Log -Message "BITS job disappeared unexpectedly. Error: $_" -Level "WARN"
                    break
                }
            }

            if (-not $status) { break }

            switch ($status.JobState) {
                'Transferred' {
                    Complete-BitsTransfer -BitsJob $status -ErrorAction Stop
                    Write-Log -Message "ISO download completed: 100%" -Level "INFO"
                    $downloadCompleted = $true
                    break
                }
                'TransferredWithErrors' {
                    Complete-BitsTransfer -BitsJob $status -ErrorAction Stop
                    Write-Log -Message "ISO download completed with recovered errors." -Level "WARN"
                    $downloadCompleted = $true
                    break
                }
                'Error' {
                    $errorInfo = $status | Select-Object -ExpandProperty Error
                    $message = if ($errorInfo) { $errorInfo.Message } else { "Unknown BITS error." }
                    throw "BITS reported error: $message"
                }
                'TransientError' {
                    $errorInfo = $status | Select-Object -ExpandProperty Error
                    $message = if ($errorInfo) { $errorInfo.Message } else { "Unknown transient error." }
                    Write-Log -Message "BITS transient error: $message" -Level "WARN"
                }
                default { }
            }

            if ($downloadCompleted) { break }

            if ($status.BytesTotal -gt 0 -and $status.JobState -eq 'Transferring') {
                $percent = [math]::Round(($status.BytesTransferred / $status.BytesTotal) * 100, 1)
                if ($percent -ge ($lastPercentLogged + 5)) {
                    Write-Log -Message ("ISO download progress: {0}%" -f $percent) -Level "INFO"
                    $lastPercentLogged = $percent
                }
            }

            if ($status.JobState -in @('Transferred', 'TransferredWithErrors')) {
                break
            }
        }
    } catch {
        if ($bitsAttempted) {
            Write-Log -Message "BITS ISO download failed; attempting Invoke-WebRequest fallback. Error: $_" -Level "WARN"
            try {
                Invoke-DirectIsoDownload -SourceUrl $SourceUrl -DestinationPath $DestinationPath
                return
            } catch {
                Write-ErrorCode -Code 11 -Detail $_
            }
        }
        Write-Log -Message "ISO download interrupted or failed. This may be due to network loss, device sleep, or power changes. Error: $_" -Level "ERROR"
        Write-FailureMarker ("ISO download failed or was interrupted: {0}" -f $_)
        throw
    } finally {
        if ($job) {
            try {
                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            } catch {}
        }
        if (Test-Path -Path $DestinationPath -PathType Leaf) {
            try {
                $fileInfo = Get-Item -Path $DestinationPath -ErrorAction Stop
                if ($fileInfo.Length -lt $minimumIsoSizeBytes) {
                    Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        $stopwatch.Stop()
        $elapsed = $stopwatch.Elapsed
        $script:IsoDownloadDuration = $elapsed
        try {
            Write-Log -Message ("ISO download duration: {0:hh\:mm\:ss\.fff} ({1:N2} seconds)" -f $elapsed, $elapsed.TotalSeconds) -Level "INFO"
            if ($downloadCompleted -and (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue)) {
                Show-UpgradeProgressToast -Phase Download -PercentComplete 100 -Status "Download complete"
            }
        } catch {
            Write-Log -Message ("Failed to format ISO download duration. Error: {0}" -f $_) -Level "WARN"
        }
    }
}

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
                }
            }

            if ($ProgressTimeoutMinutes -gt 0) {
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

function Get-SystemDriveFreeSpaceGb {
    try {
        $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($disk) {
            return [math]::Round($disk.FreeSpace / 1GB, 2)
        }
    } catch {
        Write-Log -Message ("Unable to query system drive free space. Error: {0}" -f $_) -Level "WARN"
    }

    return $null
}

function Ensure-SufficientDiskSpace {
    param(
        [int]$MinimumGb = 64,
        [switch]$AttemptCleanup,
        [string]$Reason = ""
    )

    $freeSpace = Get-SystemDriveFreeSpaceGb
    if ($null -eq $freeSpace) {
        Write-Log -Message "Free space could not be determined; continuing with caution." -Level "WARN"
        return $true
    }

    if ($freeSpace -ge $MinimumGb) {
        return $true
    }

    $reasonText = if ($Reason) { " for $Reason" } else { "" }
    Write-Log -Message ("Detected insufficient free space{0} (free: {1} GB, required: {2} GB)." -f $reasonText, $freeSpace, $MinimumGb) -Level "WARN"

    if ($AttemptCleanup) {
        Write-Log -Message "Attempting to reclaim space from prior upgrade artifacts." -Level "INFO"
        if (Get-Command -Name Invoke-UpgradeFailureCleanup -ErrorAction SilentlyContinue) {
            Invoke-UpgradeFailureCleanup -PreserveHealthyIso
        }
        $freeSpace = Get-SystemDriveFreeSpaceGb

        if ($freeSpace -ge $MinimumGb) {
            Write-Log -Message ("Free space recovered to {0} GB after cleanup." -f $freeSpace) -Level "INFO"
            return $true
        }
    }

    $failureReason = "Insufficient free space{0}: {1} GB available, {2} GB required." -f $reasonText, $freeSpace, $MinimumGb
    Write-FailureMarker $failureReason
    throw $failureReason
}

function Test-IsoFileHealthy {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Write-Log -Message "ISO validation failed because $Path does not exist." -Level "WARN"
        return $false
    }

    try {
        $fileInfo = Get-Item -Path $Path -ErrorAction Stop
        $sizeGb = [math]::Round($fileInfo.Length / 1GB, 2)
        $minGb = [math]::Round($minimumIsoSizeBytes / 1GB, 2)

        if ($fileInfo.Length -lt $minimumIsoSizeBytes) {
            Write-Log -Message ("Downloaded ISO at {0} is only {1} GB (minimum expected {2} GB). Source may have returned an HTML or error page instead of the ISO." -f $Path, $sizeGb, $minGb) -Level "WARN"
            return $false
        }

        return $true
    } catch {
        Write-Log -Message ("Unable to validate ISO file {0}. Error: {1}" -f $Path, $_) -Level "WARN"
        return $false
    }
}

function Get-FileSha256 {
    param([string]$Path)

    try {
        $hash = Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash.ToLowerInvariant()
    } catch {
        Write-Log -Message ("Unable to compute SHA256 for {0}. Error: {1}" -f $Path, $_) -Level "WARN"
        return $null
    }
}

function Get-ExpectedIsoHashes {
    $hashes = @()

    if (-not [string]::IsNullOrWhiteSpace($expectedIsoSha256)) {
        $hashes += $expectedIsoSha256.ToLowerInvariant()
    }

    if (Test-Path -Path $isoHashCacheFile) {
        try {
            $cached = (Get-Content -Path $isoHashCacheFile -Raw -ErrorAction Stop).Trim()
            if ($cached) {
                $hashes += $cached.ToLowerInvariant()
            }
        } catch {
            Write-Log -Message "Unable to read cached ISO hash file. Error: $_" -Level "WARN"
        }
    }

    return $hashes
}

function Set-CachedIsoHash {
    param([string]$Hash)

    if ([string]::IsNullOrWhiteSpace($Hash)) {
        return
    }

    try {
        Ensure-Directory -Path $stateDirectory
        $normalized = $Hash.ToLowerInvariant()
        Set-Content -Path $isoHashCacheFile -Value $normalized -Encoding ASCII
        Write-Log -Message ("Cached ISO hash {0} to {1}." -f $normalized, $isoHashCacheFile) -Level "VERBOSE"
    } catch {
        Write-Log -Message "Failed to cache ISO hash. Error: $_" -Level "WARN"
    }
}

function Test-IsoHashValid {
    param(
        [string]$Path,
        [switch]$AllowUnknownCache
    )

    $computedHash = Get-FileSha256 -Path $Path
    if (-not $computedHash) {
        return $false
    }

    $expectedHashes = Get-ExpectedIsoHashes

    if ($expectedHashes.Count -eq 0) {
        if ($AllowUnknownCache) {
            Set-CachedIsoHash -Hash $computedHash
            Write-Log -Message ("No expected ISO hash configured. Cached current hash ({0}) for future validation." -f $computedHash) -Level "INFO"
            return $true
        }

        Write-Log -Message ("Computed ISO hash {0} but no expected hash is configured for validation." -f $computedHash) -Level "WARN"
        return $false
    }

    if ($expectedHashes -contains $computedHash) {
        Set-CachedIsoHash -Hash $computedHash
        Write-Log -Message ("ISO hash validation succeeded (SHA256={0})." -f $computedHash) -Level "INFO"
        return $true
    }

    Write-Log -Message ("ISO hash validation failed. Expected {0}; actual {1}." -f ($expectedHashes -join ", "), $computedHash) -Level "WARN"
    return $false
}

function Download-Windows11Iso {
    if ([string]::IsNullOrWhiteSpace($windows11IsoUrl) -or $windows11IsoUrl -like "*example.com*") {
        Write-Log -Message "Windows 11 ISO URL is not configured. Set $windows11IsoUrl to a valid download location." -Level "ERROR"
        throw "ISO URL not configured"
    }

    Ensure-SufficientDiskSpace -MinimumGb 64 -AttemptCleanup -Reason "ISO staging" | Out-Null
    if (Get-Command -Name Clean-BitsTempFiles -ErrorAction SilentlyContinue) {
        Write-Log -Message "Removing orphaned BITS temp files before ISO validation and download." -Level "VERBOSE"
        Clean-BitsTempFiles
    }

    $isoPath = $isoFilePath

    if (Test-Path -Path $isoPath) {
        Write-Log -Message "Existing ISO detected at $isoPath. Validating..." -Level "VERBOSE"

        $isoHealthy = Test-IsoFileHealthy -Path $isoPath
        $isoHashValid = $false
        if ($isoHealthy) {
            $isoHashValid = Test-IsoHashValid -Path $isoPath -AllowUnknownCache
        }

        if ($isoHealthy -and $isoHashValid) {
            Write-Log -Message "Existing ISO passed health and hash validation. Reusing cached media." -Level "INFO"
            return $isoPath
        }

        Write-Log -Message "Existing ISO failed validation and will be replaced." -Level "WARN"
        try {
            Remove-Item -Path $isoPath -Force -ErrorAction Stop
        } catch {
            Write-Log -Message "Unable to remove invalid ISO prior to re-download. Error: $_" -Level "WARN"
        }
        if (Test-Path -Path $isoHashCacheFile) {
            Remove-Item -Path $isoHashCacheFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Launch download toast by invoking the self-scheduling toast script
    try {
        $toastRoot = if ($privateRoot) { $privateRoot } elseif ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
        $toastScript = Join-Path -Path (Join-Path -Path $toastRoot -ChildPath "Toast-Notification") -ChildPath "Toast-Windows11Download.ps1"
        $powershellExe = [System.IO.Path]::Combine($env:SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")

        if (Test-Path -Path $toastScript -PathType Leaf) {
            Start-Process -FilePath $powershellExe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$toastScript`"" -WindowStyle Hidden -ErrorAction Stop
            Write-Log -Message ("Toast notification (Download) invoked") -Level "INFO"
        } else {
            Write-Log -Message ("Download toast script missing at {0}; skipping notification." -f $toastScript) -Level "WARN"
        }
    } catch {
        Write-Log -Message ("Download toast failed; script={0}; error={1}" -f $toastScript, $_) -Level "WARN"
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Log -Message ("Downloading Windows 11 25H2 ISO (attempt {0}/{1})..." -f $attempt, $maxAttempts) -Level "INFO"
        if (Get-Command -Name Clean-BitsTempFiles -ErrorAction SilentlyContinue) {
            Clean-BitsTempFiles
        }

        try {
            Invoke-TimedIsoDownload -SourceUrl $windows11IsoUrl -DestinationPath $isoPath
            Write-Log -Message "Windows 11 ISO downloaded to $isoPath." -Level "INFO"

            if (-not (Test-IsoFileHealthy -Path $isoPath)) {
                Remove-Item -Path $isoPath -Force -ErrorAction SilentlyContinue
                Write-Log -Message "Downloaded ISO failed validation (file too small or unreadable). Will retry download." -Level "WARN"
                if ($attempt -eq $maxAttempts) {
                    Write-FailureMarker "Downloaded ISO failed validation (file too small or unreadable). Check download URL or authentication requirements."
                    throw "Downloaded ISO failed validation. Verify that $windows11IsoUrl is reachable without authentication."
                }
                continue
            }

            if (-not (Test-IsoHashValid -Path $isoPath -AllowUnknownCache)) {
                if (Test-Path -Path $isoPath) {
                    Remove-Item -Path $isoPath -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path -Path $isoHashCacheFile) {
                    Remove-Item -Path $isoHashCacheFile -Force -ErrorAction SilentlyContinue
                }
                Write-Log -Message "Downloaded ISO hash does not match the expected value. Will retry download." -Level "WARN"
                if ($attempt -eq $maxAttempts) {
                    Write-FailureMarker "Downloaded ISO hash does not match the expected value."
                    throw "Downloaded ISO hash verification failed after $maxAttempts attempts."
                }
                continue
            }

            return $isoPath
        } catch {
            Write-Log -Message "Failed to download Windows 11 ISO. Error: $_" -Level "ERROR"
            if ($attempt -eq $maxAttempts) {
                Write-FailureMarker ("ISO download failed after {0} attempts: {1}" -f $maxAttempts, $_)
                throw
            }
        }
    }
}

function Stage-UpgradeFromIso {
    param (
        [string]$IsoPath,
        [switch]$SkipCompatCheck
    )

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

    $maxAttempts = 3
    $attempt = 0
    $success = $false
    $failureReason = $null
    $exitCode = $null
    $recoveryAttempted = $false

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
                    $proc = Start-Process -FilePath $cmdPath -ArgumentList "/c $($errorInfo.Command)" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    if ($proc.ExitCode -eq 0) {
                        Write-Log -Message ("Self-repair command succeeded for {0}; retrying staging." -f $codeForLookup) -Level "INFO"
                        $failureReason = $null
                        $exitCode = $null
                        Start-Sleep -Seconds 5
                        continue
                    } else {
                        Write-Log -Message ("Self-repair command for {0} exited with code {1}; continuing failure handling." -f $codeForLookup, $proc.ExitCode) -Level "WARN"
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
        } else {
            if (-not $failureReason) {
                $failureReason = "ISO staging failed for unspecified reason."
            }

            $codeForLookup = if ($exitCodeHex -and $exitCodeHex -notmatch "\?") { $exitCodeHex } elseif ($exitCode) { $exitCode } else { $failureReason }
            $info = $null
            if (Get-Command -Name Get-ErrorCodeInfo -ErrorAction SilentlyContinue) {
                $info = Get-ErrorCodeInfo -Code $codeForLookup
            }
            if ($info -and $info.Title -and $info.Title -ne "Unknown error") {
                $failureReason = ("setup.exe exited with {0}. {1}. {2}" -f $codeForLookup, $info.Title, $info.Description)
                if ($info.Remediation) {
                    $failureReason = "$failureReason. Remediation: $($info.Remediation)"
                }
            } else {
                $failureReason = ("setup.exe exited with {0}. {1}" -f $codeForLookup, $failureReason)
            }

            Write-FailureMarker $failureReason

            if (Get-Command -Name Invoke-UpgradeFailureCleanup -ErrorAction SilentlyContinue) {
                Invoke-UpgradeFailureCleanup -PreserveHealthyIso
            }

            Write-ErrorCode -Code $codeForLookup -Detail $failureReason
        }

        return $success
    } catch {
        Write-Log -Message ("Stage-UpgradeFromIso encountered a fatal error. Error: {0}" -f $_) -Level "ERROR"
        Write-FailureMarker ("ISO staging failed unexpectedly: {0}" -f $_)
        return $false
    }
}
