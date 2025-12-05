# Upgrade Configuration
# Version 2.7.1
# Date 12/04/2025
# Author: Quintin Sheppard
# Summary: Loads configuration from JSON (C:\Temp\WindowsUpdate\config.json) and exports it for the upgrade workflow.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Windows11Upgrade\\UpgradeConfig.ps1'; $cfg = Set-UpgradeConfig; $cfg.BaseLogFile"

function Resolve-Value {
    param(
        $Raw,
        $Default
    )

    if ($null -eq $Raw) {
        return $Default
    }

    if ($Raw -is [string] -and $Raw.StartsWith("@") -and $Raw.EndsWith("@")) {
        return $Default
    }

    if ($Default -is [bool]) {
        if ($Raw -is [bool]) { return $Raw }
        $parsed = $null
        if ([bool]::TryParse($Raw.ToString(), [ref]$parsed)) { return [bool]$parsed }
        return $Default
    }

    if ($Default -is [int64]) {
        $number = $null
        if ([int64]::TryParse($Raw.ToString(), [ref]$number)) { return $number }
        return $Default
    }

    if ($Default -is [version]) {
        try { return [version]$Raw } catch { return $Default }
    }

    if ($Default -is [System.Collections.IEnumerable] -and -not ($Default -is [string])) {
        if ($Raw -is [System.Collections.IEnumerable] -and -not ($Raw -is [string])) {
            $items = @()
            foreach ($item in $Raw) { $items += Resolve-Value -Raw $item -Default ($Default | Select-Object -First 1) }
            return $items
        }
        return $Default
    }

    if ($Default -is [hashtable] -or $Default -is [pscustomobject]) {
        $result = [ordered]@{}
        $rawProps = if ($Raw -is [pscustomobject]) { $Raw.PSObject.Properties } elseif ($Raw -is [hashtable]) { $Raw.GetEnumerator() } else { @() }
        $rawLookup = @{}
        foreach ($p in $rawProps) { $rawLookup[$p.Name] = $p.Value }
        foreach ($prop in ($Default.PSObject.Properties)) {
            $rawValue = $null
            if ($rawLookup.ContainsKey($prop.Name)) { $rawValue = $rawLookup[$prop.Name] }
            $result[$prop.Name] = Resolve-Value -Raw $rawValue -Default $prop.Value
        }
        return [pscustomobject]$result
    }

    return $Raw
}

function Get-ConfigData {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw ("Configuration file not found at {0}. Ensure UpgradeConfig-RMM.ps1 generated config.json before running the upgrade." -f $Path)
    }

    try {
        return Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw ("Unable to read configuration at {0}. Error: {1}" -f $Path, $_)
    }
}

function Build-SetupArguments {
    param(
        [string]$BaseArguments,
        [bool]$DynamicUpdateEnabled
    )

    $dynamicPart = if ($DynamicUpdateEnabled) { "/DynamicUpdate Enable" } else { "/DynamicUpdate Disable" }
    $args = "$BaseArguments $dynamicPart"
    if ($args -notmatch "(?i)/noreboot") {
        $args = "$args /NoReboot"
    }
    return $args.Trim()
}

function Set-UpgradeConfig {
    $primaryConfigPath = "C:\Temp\WindowsUpdate\config.json"
    $config = Get-ConfigData -Path $primaryConfigPath

    if ($config.PSObject.Properties.Match("LogFile").Count -eq 0) {
        $config | Add-Member -NotePropertyName "LogFile" -NotePropertyValue $null -Force
    }
    if ($config.PSObject.Properties.Match("SetupExeArguments").Count -eq 0) {
        $config | Add-Member -NotePropertyName "SetupExeArguments" -NotePropertyValue $null -Force
    }

    $config.LogFile = $config.BaseLogFile
    if ($config.DynamicUpdate -isnot [bool]) {
        $parsedDynamic = $true
        if ([bool]::TryParse($config.DynamicUpdate.ToString(), [ref]$parsedDynamic)) {
            $config.DynamicUpdate = $parsedDynamic
        }
    }
    $config.SetupExeArguments = Build-SetupArguments -BaseArguments $config.SetupExeBaseArguments -DynamicUpdateEnabled $config.DynamicUpdate
    if ($config.AutoReboot -isnot [bool]) {
        $parsedAuto = $false
        if ([bool]::TryParse($config.AutoReboot.ToString(), [ref]$parsedAuto)) {
            $config.AutoReboot = $parsedAuto
        }
    }

    if ($config.UpgradeStateFiles) {
        $stateFiles = @{}
        foreach ($entry in $config.UpgradeStateFiles.PSObject.Properties) {
            $stateFiles[$entry.Name] = $entry.Value
        }
        $config.UpgradeStateFiles = $stateFiles
    }

    try { $config.MinimumSentinelAgentVersion = [version]$config.MinimumSentinelAgentVersion } catch {}
    if ($config.MinimumIsoSizeBytes -isnot [int64]) {
        try { $config.MinimumIsoSizeBytes = [int64]$config.MinimumIsoSizeBytes } catch {}
    }

    foreach ($dir in @($config.StateDirectory, $config.ToastAssetsRoot)) {
        if (-not (Test-Path -Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    if (-not (Test-Path -Path $config.LogFile)) {
        try { New-Item -Path $config.LogFile -ItemType File -Force | Out-Null } catch {}
    }

    foreach ($key in $config.PSObject.Properties.Name) {
        Set-Variable -Name $key -Value $config.$key -Scope Global -Force
    }

    return $config
}
