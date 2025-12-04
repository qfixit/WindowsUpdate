# Detection Helpers
# Version 2.5.9
# Date 11/29/2025
# Author: Quintin Sheppard
# Summary: OS detection and boot-time helpers.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Private\\Detection\\Detection.ps1'; Test-IsWindows11"

function Test-IsWindows11 {
    try {
        $osProps = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
        $productName = $osProps.ProductName
        $buildNumber = 0
        if ($osProps.PSObject.Properties.Match("CurrentBuildNumber").Count -gt 0) {
            [void][int]::TryParse($osProps.CurrentBuildNumber, [ref]$buildNumber)
        }
        $displayVersion = $null
        if ($osProps.PSObject.Properties.Match("DisplayVersion").Count -gt 0) {
            $displayVersion = $osProps.DisplayVersion
        }

        $isWindows11 = ($buildNumber -ge 22000) -or ($productName -like "*Windows 11*")
        Write-Log -Message ("OS detection: Product={0}; Build={1}; DisplayVersion={2}; DetectedWindows11={3}" -f $productName, $buildNumber, $displayVersion, $isWindows11) -Level "VERBOSE"
        return $isWindows11
    } catch {
        Write-Log -Message "Unable to determine Windows version. Error: $_" -Level "WARN"
        return $false
    }
}

function Get-LastBootTime {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return $os.LastBootUpTime
    } catch {
        Write-Log -Message "Unable to determine the last boot time. Error: $_" -Level "WARN"
        return $null
    }
}
