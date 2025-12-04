# State & Marker Helpers
# Version 2.6.2
# Date 11/30/2025
# Author: Quintin Sheppard
# Summary: Handles upgrade markers, state files, and failure tracking.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Private\\State\\UpgradeState.ps1'; Write-FailureMarker 'test reason'"

function Write-FailureMarker {
    param([string]$Reason)

    try {
        Ensure-Directory -Path $stateDirectory
        Clear-UpgradeState
        $entry = "{0:yyyy-MM-dd HH:mm:ss} - {1}" -f (Get-Date), $Reason
        $entry | Set-Content -Path $failureMarker -Encoding UTF8
        Write-Log -Message "Failure marker recorded: $Reason" -Level "WARN"
    } catch {
        Write-Log -Message "Unable to record failure marker. Error: $_" -Level "ERROR"
    }
}

function Clear-FailureMarker {
    try {
        if (Test-Path -Path $failureMarker) {
            Remove-Item -Path $failureMarker -Force -ErrorAction Stop
            Write-Log -Message "Failure marker cleared." -Level "VERBOSE"
        }
    } catch {
        Write-Log -Message "Unable to clear failure marker. Error: $_" -Level "WARN"
    }
}

function Read-UpgradeStateFile {
    param(
        [string]$Path,
        [string]$Status
    )

    try {
        $content = Get-Content -Path $Path -ErrorAction Stop
    } catch {
        Write-Log -Message "Failed to read state file $Path. Error: $_" -Level "WARN"
        return $null
    }

    $data = [ordered]@{}
    foreach ($line in $content) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $separatorIndex = $line.IndexOf("=")
        if ($separatorIndex -lt 1) {
            continue
        }

        $key = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim()

        if (-not $key) {
            continue
        }

        $parsedValue = $value
        if ($value -match '^(?i)true|false$') {
            try {
                $parsedValue = [bool]::Parse($value)
            } catch {
                $parsedValue = $value
            }
        }

        $data[$key] = $parsedValue
    }

    if ($Status -and -not $data.Contains("Status")) {
        $data["Status"] = $Status
    }

    if ($data.Count -eq 0) {
        if ($Status) {
            return [pscustomobject]@{ Status = $Status }
        }
        return $null
    }

    return [pscustomobject]$data
}

function Write-UpgradeStateFile {
    param(
        [psobject]$State,
        [string]$DestinationPath
    )

    if (-not $State -or -not $DestinationPath) {
        return
    }

    $lines = @()
    foreach ($property in $State.PSObject.Properties) {
        if ($null -eq $property.Value) {
            continue
        }
        $lines += ("{0}={1}" -f $property.Name, $property.Value)
    }

    if ($lines.Count -eq 0 -and $State.Status) {
        $lines = @("Status=$($State.Status)")
    }

    Ensure-Directory -Path (Split-Path -Path $DestinationPath -Parent)
    $lines | Set-Content -Path $DestinationPath -Encoding UTF8
}

function Get-UpgradeState {
    foreach ($entry in $script:UpgradeStateFiles.GetEnumerator()) {
        $path = $entry.Value
        if (Test-Path -Path $path) {
            $stateObject = Read-UpgradeStateFile -Path $path -Status $entry.Key
            if (-not $stateObject) {
                $stateObject = [pscustomobject]@{ Status = $entry.Key }
            } elseif ($stateObject.PSObject.Properties.Match("Status").Count -eq 0) {
                $stateObject | Add-Member -NotePropertyName "Status" -NotePropertyValue $entry.Key -Force
            }

            return $stateObject
        }
    }

    if (Test-Path -Path $failureMarker) {
        try {
            $reason = Get-Content -Path $failureMarker -Raw -ErrorAction Stop
        } catch {
            $reason = "Unknown failure (marker unreadable)."
        }

        return [pscustomobject]@{
            Status = "UpgradeFailed"
            Reason = $reason
        }
    }

    return $null
}

function Save-UpgradeState {
    param ([psobject]$State)

    if (-not $State -or [string]::IsNullOrWhiteSpace($State.Status) -or $State.Status -eq "Completed") {
        Clear-UpgradeState
        return
    }

    if (-not $script:UpgradeStateFiles.ContainsKey($State.Status)) {
        Write-Log -Message ("Unknown upgrade state '{0}'. Clearing sentinel files." -f $State.Status) -Level "WARN"
        Clear-UpgradeState
        return
    }

    $targetPath = $script:UpgradeStateFiles[$State.Status]

    try {
        Clear-UpgradeState
        Clear-FailureMarker
        Write-UpgradeStateFile -State $State -DestinationPath $targetPath
        Write-Log -Message ("Upgrade state saved to {0} ({1})." -f $targetPath, $State.Status) -Level "VERBOSE"
    } catch {
        Write-Log -Message "Failed to persist upgrade state. Error: $_" -Level "ERROR"
    }
}

function Clear-UpgradeState {
    foreach ($path in $script:UpgradeStateFiles.Values) {
        if (Test-Path -Path $path) {
            try {
                Remove-Item -Path $path -Force -ErrorAction Stop
                Write-Log -Message ("Removed upgrade state file {0}." -f $path) -Level "VERBOSE"
            } catch {
                Write-Log -Message ("Unable to remove upgrade state file {0}. Error: {1}" -f $path, $_) -Level "WARN"
            }
        }
    }
}

function Invoke-UpgradeFailureCleanup {
    param(
        [switch]$PreserveHealthyIso
    )

    try {
        Clear-UpgradeState
    } catch {
        Write-Log -Message ("Failed to clear upgrade state during failure cleanup. Error: {0}" -f $_) -Level "WARN"
    }

    $pathsToRemove = @()
    if (-not $PreserveHealthyIso) {
        if ($isoFilePath) { $pathsToRemove += $isoFilePath }
        if ($isoHashCacheFile) { $pathsToRemove += $isoHashCacheFile }
    }

    $setupLogsPath = Join-Path -Path $stateDirectory -ChildPath "SetupLogs"
    $pathsToRemove += $setupLogsPath

    foreach ($p in $pathsToRemove) {
        if (Test-Path -Path $p) {
            try {
                Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                Write-Log -Message ("Removed artifact {0} during failure cleanup." -f $p) -Level "VERBOSE"
            } catch {
                Write-Log -Message ("Unable to remove artifact {0} during failure cleanup. Error: {1}" -f $p, $_) -Level "WARN"
            }
        }
    }
}
