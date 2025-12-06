# ISO Download Helpers
# Version 2.7.3
# Date 12/04/2025
# Author: Quintin Sheppard
# Summary: Disk space checks, ISO health/hash validation, and BITS download wrapper for the Windows 11 upgrade.
# Example test (download only): powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\Windows11Upgrade\ISO Download\IsoDownload.ps1'; Invoke-TimedIsoDownload -SourceUrl 'https://example.com/test.iso' -DestinationPath 'C:\Temp\WindowsUpdate\Test.iso'"

param()

# Load setup/install helpers if present
$installHelper = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -ChildPath "SetupInstall.ps1"
if (Test-Path -Path $installHelper -PathType Leaf) {
    try { . $installHelper } catch { Write-Verbose ("Failed to load SetupInstall.ps1. Error: {0}" -f $_) }
}

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
    $lastActivity = [datetime]::UtcNow
    $lastBytes = $null
    $inactivityWindow = [timespan]::FromMinutes(5)
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
                    if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
                        Show-UpgradeProgressToast -Phase Download -PercentComplete 100 -Status "Download complete"
                    }
                    break
                }
                'TransferredWithErrors' {
                    Complete-BitsTransfer -BitsJob $status -ErrorAction Stop
                    Write-Log -Message "ISO download completed with recovered errors." -Level "WARN"
                    $downloadCompleted = $true
                    if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
                        Show-UpgradeProgressToast -Phase Download -PercentComplete 100 -Status "Download complete"
                    }
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
                if ($null -ne $status.BytesTransferred -and ($lastBytes -eq $null -or $status.BytesTransferred -ne $lastBytes)) {
                    $lastBytes = $status.BytesTransferred
                    $lastActivity = [datetime]::UtcNow
                }
                if ($percent -ge ($lastPercentLogged + 5)) {
                    Write-Log -Message ("ISO download progress: {0}%" -f $percent) -Level "INFO"
                    $lastPercentLogged = $percent
                    if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
                        Show-UpgradeProgressToast -Phase Download -PercentComplete $percent -Status "Downloading..."
                    }
                }
            }

            if ($status.JobState -eq 'TransientError' -or $status.JobState -eq 'Suspended' -or $status.JobState -eq 'Transferring') {
                if ([datetime]::UtcNow -gt $lastActivity.Add($inactivityWindow)) {
                    Write-Log -Message ("BITS download stalled for more than {0} minutes; cancelling job and falling back to Invoke-WebRequest." -f [math]::Round($inactivityWindow.TotalMinutes, 0)) -Level "WARN"
                    try {
                        Remove-BitsTransfer -BitsJob $status -ErrorAction SilentlyContinue
                    } catch {}
                    try {
                        Invoke-DirectIsoDownload -SourceUrl $SourceUrl -DestinationPath $DestinationPath
                        return
                    } catch {
                        Write-ErrorCode -Code 11 -Detail $_
                    }
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
        try {
            $cimDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            if ($cimDisk) {
                $freeSpace = [math]::Round($cimDisk.FreeSpace / 1GB, 2)
            }
        } catch {
            Write-Log -Message ("Secondary disk space probe via CIM failed. Error: {0}" -f $_) -Level "VERBOSE"
        }
    }

    if ($null -eq $freeSpace) {
        try {
            $psDrive = Get-PSDrive -Name C -ErrorAction Stop
            if ($psDrive -and $psDrive.Free -ne $null) {
                $freeSpace = [math]::Round($psDrive.Free / 1GB, 2)
            }
        } catch {
            Write-Log -Message ("PSDrive free space probe failed. Error: {0}" -f $_) -Level "VERBOSE"
        }
    }

    if ($null -eq $freeSpace) {
        $failureReason = "Unable to determine free space on the system drive; aborting Windows 11 upgrade to avoid disk exhaustion."
        Write-Log -Message $failureReason -Level "ERROR"
        Write-FailureMarker $failureReason
        throw $failureReason
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

# staging/installation moved to SetupInstall.ps1 (Stage-UpgradeFromIso removed here)
