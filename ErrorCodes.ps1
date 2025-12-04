# Error Code Definitions for Windows11Upgrade
# Version 2.7.0
# Date 12/03/2025
# Author: Quintin Sheppard
# Summary: Loads error code metadata from ErrorCodes.json to provide technician-friendly descriptions and remediation.

$script:ErrorCatalog = $null

function Get-ErrorCatalog {
    if ($script:ErrorCatalog) {
        return $script:ErrorCatalog
    }

    $jsonPath = if ($PSScriptRoot) { Join-Path -Path $PSScriptRoot -ChildPath "ErrorCodes.json" } else { "ErrorCodes.json" }
    if (Test-Path -Path $jsonPath -PathType Leaf) {
        try {
            $raw = Get-Content -Path $jsonPath -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($parsed) {
                $script:ErrorCatalog = $parsed
                return $script:ErrorCatalog
            }
        } catch {
            Write-Verbose ("Failed to load ErrorCodes.json. Error: {0}" -f $_)
        }
    }

    # Minimal fallback to keep logging useful
    $script:ErrorCatalog = @(
        [pscustomobject]@{ Code = "10"; Title = "System shutdown in progress"; Description = "Windows reported a shutdown during upgrade."; Remediation = "Let the device reboot, then rerun the upgrade to self-heal." },
        [pscustomobject]@{ Code = "11"; Title = "ISO download transport unavailable"; Description = "BITS/web request could not fetch the Windows 11 ISO."; Remediation = "Verify internet/proxy/BITS health and rerun." },
        [pscustomobject]@{ Code = "12"; Title = "ISO validation failed"; Description = "ISO health/hash checks failed after retries."; Remediation = "Confirm ISO URL and SHA256, then retry." },
        [pscustomobject]@{ Code = "13"; Title = "ISO mount/staging failed"; Description = "setup.exe could not mount or stage from the ISO after retries."; Remediation = "Check disk space, ISO health, and setup logs under C:\Temp\WindowsUpdate\SetupLogs." },
        [pscustomobject]@{ Code = "14"; Title = "App/driver compatibility block (0xC1900208)"; Description = "setup.exe reported an application or driver compatibility block."; Remediation = "Review setup logs for the blocker, remediate, then rerun." }
    )
    return $script:ErrorCatalog
}

function Normalize-ErrorCode {
    param([Parameter(Mandatory)][object]$Code)

    $codes = @()
    if ($null -eq $Code) { return $codes }

    $codeString = $Code.ToString().Trim()
    if ($codeString) { $codes += $codeString }

    $numeric = $null
    if ([int64]::TryParse($codeString, [ref]$numeric)) {
        $masked = $numeric -band 0xFFFFFFFFL
        $hex = "0x{0}" -f ([uint32]$masked).ToString("X8")
        $codes += $hex
    }

    return $codes | Select-Object -Unique
}

function Get-ErrorCodeInfo {
    param(
        [Parameter(Mandatory)][object]$Code
    )

    $catalog = Get-ErrorCatalog
    $candidates = Normalize-ErrorCode -Code $Code

    foreach ($candidate in $candidates) {
        $match = $catalog | Where-Object { $_.Code -eq $candidate } | Select-Object -First 1
        if ($match) { return $match }
    }

    # Try case-insensitive match
    foreach ($candidate in $candidates) {
        $match = $catalog | Where-Object { $_.Code -eq $candidate.ToUpper() } | Select-Object -First 1
        if ($match) { return $match }
    }

    return [pscustomobject]@{
        Code        = ($candidates | Select-Object -First 1)
        Title       = "Unknown error"
        Description = "No description available."
        Remediation = "Review logs for additional details."
    }
}
