# System & Compatibility Checks
# Version 2.6.1
# Date 11/30/2025
# Author: Quintin Sheppard
# Summary: Hardware and SentinelOne compatibility validation for the upgrade workflow.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Private\\SystemChecks\\SystemChecks.ps1'; Check-SystemRequirements"

function Get-SentinelAgentVersion {
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $versions = foreach ($p in $paths) {
        try {
            Get-ChildItem -Path $p -ErrorAction Stop |
                Get-ItemProperty |
                Where-Object { $_.DisplayName -eq "Sentinel Agent" } |
                Select-Object -ExpandProperty DisplayVersion -ErrorAction SilentlyContinue
        } catch {
            continue
        }
    }

    $candidate = $versions | Where-Object { $_ } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        try {
            $service = Get-Service -Name "SentinelAgent" -ErrorAction Stop
            if ($service) {
                Write-Log -Message "SentinelOne service detected but version could not be determined." -Level "WARN"
                return [version]'0.0.0.0'
            }
        } catch {}

        return $null
    }

    try {
        return [version]$candidate
    } catch {
        Write-Log -Message "Unable to parse SentinelOne version string '$candidate'. Error: $_" -Level "WARN"
        return $null
    }
}

function Ensure-SentinelAgentCompatible {
    $version = Get-SentinelAgentVersion
    if (-not $version) {
        Write-Log -Message "SentinelOne agent not detected; continuing without SentinelOne gating." -Level "INFO"
        return $true
    }

    if ($version -eq [version]'0.0.0.0') {
        Write-Log -Message ("SentinelOne agent detected but version could not be retrieved. Please ensure the agent is upgraded to at least {0} or placed in maintenance mode before retrying the Windows 11 upgrade." -f $minimumSentinelAgentVersion) -Level "WARN"
        Write-FailureMarker "SentinelOne agent version could not be determined."
        return $false
    }

    Write-Log -Message ("SentinelOne agent version detected: {0}" -f $version) -Level "INFO"

    if ($version -lt $minimumSentinelAgentVersion) {
        Write-Log -Message ("SentinelOne agent version {0} is below the required {1}. Upgrade SentinelOne to 24.2.2 or newer, or place the agent in maintenance mode before retrying the Windows 11 upgrade." -f $version, $minimumSentinelAgentVersion) -Level "ERROR"
        Write-FailureMarker ("SentinelOne agent version $version below $minimumSentinelAgentVersion")
        return $false
    }

    return $true
}

function Check-SystemRequirements {
    Write-Log "Starting system requirement checks..."

    # Check TPM version
    $tpm = Get-WmiObject -class Win32_Tpm -namespace root\CIMV2\Security\MicrosoftTpm
    if ($tpm) {
        if ($tpm.SpecVersion -ge "2.0") {
            Write-Log "TPM 2.0 found."
        } else {
            Write-Log "TPM 2.0 not found, this is required for Windows 11."
            throw "TPM 2.0 not found, this is required for Windows 11."
        }
    } else {
        Write-Log "TPM not found."
        throw "TPM not found, this is required for Windows 11."
    }

    # Check Secure Boot
    $secureBootEnabled = $false
    try {
        if (Get-Command -Name Confirm-SecureBootUEFI -ErrorAction Stop) {
            $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
        }
    } catch {
        Write-Log -Message ("Unable to query Secure Boot state. Error: {0}" -f $_) -Level "WARN"
        $secureBootEnabled = $false
    }

    if ($secureBootEnabled) {
        Write-Log "Secure Boot is enabled."
    } else {
        Write-Log "Secure Boot is not enabled. Windows 11 requires Secure Boot."
        throw "Secure Boot is not enabled. Windows 11 requires Secure Boot."
    }

    # Check processor compatibility (Windows 11 supports 64-bit CPUs only)
    $cpu = Get-WmiObject -Class Win32_Processor
    if ($cpu) {
        if ($cpu.Architecture -eq 9) {
            Write-Log "64-bit processor found."
        } else {
            Write-Log "64-bit processor not found. Windows 11 requires a 64-bit CPU."
            throw "64-bit processor not found. Windows 11 requires a 64-bit CPU."
        }
    }

    # Check RAM
    $ram = Get-WmiObject -Class Win32_ComputerSystem
    if ($ram.TotalPhysicalMemory -ge 4GB) {
        Write-Log "Sufficient RAM found (>= 4GB)."
    } else {
        Write-Log "Insufficient RAM. Windows 11 requires at least 4GB."
        throw "Insufficient RAM. Windows 11 requires at least 4GB."
    }

    # Check storage space
    Ensure-SufficientDiskSpace -MinimumGb 64 -AttemptCleanup -Reason "Windows 11 prerequisites" | Out-Null

    Write-Log "System meets the minimum requirements for Windows 11."
    return $true
}
