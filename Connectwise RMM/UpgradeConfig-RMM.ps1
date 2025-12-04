# Upgrade Configuration (RMM Parameter-Aware Builder)
# Version 2.7.0
# Date 12/03/2025
# Author: Quintin Sheppard
# Summary: Emits C:\Temp\WindowsUpdate\config.json for ConnectWise RMM with @Parameter@ placeholders for later substitution.
# Example (RMM task build step):
#   powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Temp\WindowsUpdate\UpgradeConfig-RMM.ps1" -Windows11IsoUrl @Windows11IsoUrl@ -ISOHash @ISOHash@ -DynamicUpdate @DynamicUpdate@ -AutoReboot @AutoReboot@ -RebootReminder1Time @RebootReminder1Time@ -RebootReminder2Time @RebootReminder2Time@

param(
    [string]$Windows11IsoUrl,
    [string]$ISOHash,
    [string]$DynamicUpdate,
    [string]$AutoReboot,
    [string]$RebootReminder1Time,
    [string]$RebootReminder2Time,
    [string]$DocLink
)

$logFile = "C:\Windows11UpgradeLog.txt"
$stateDirectory = "C:\Temp\WindowsUpdate"
$configPath = Join-Path -Path $stateDirectory -ChildPath "config.json"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "VERBOSE")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"

    $directory = Split-Path -Path $logFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    try {
        Add-Content -Path $logFile -Value $logMessage -Encoding UTF8
    } catch {
        Write-Warning ("Failed to append to {0}. Error: {1}" -f $logFile, $_)
    }

    switch ($Level) {
        "ERROR"   { Write-Error $logMessage }
        "WARN"    { Write-Warning $logMessage }
        "VERBOSE" { Write-Verbose $logMessage }
        default   { Write-Information -MessageData $logMessage -InformationAction Continue }
    }

    if ($Level -ne "VERBOSE") {
        Write-Verbose $logMessage
    }
}

function Resolve-ParameterOrToken {
    param(
        [string]$Value,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Token
    }

    return $Value
}

function Resolve-BoolOrToken {
    param(
        [string]$Value,
        [string]$Token,
        [bool]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Token
    }

    $parsed = $null
    if ([bool]::TryParse($Value, [ref]$parsed)) {
        return [bool]$parsed
    }

    return $Token
}

function New-UpgradeConfigObject {
    $config = [PSCustomObject][ordered]@{
        # Logging & state paths
        BaseLogFile                  = "C:\Windows11UpgradeLog.txt"
        LogFile                      = $null
        StateDirectory               = $stateDirectory
        UpgradeStateFiles            = @{
            ScriptRunning = "C:\Temp\WindowsUpdate\ScriptRunning.txt"
            PendingReboot = "C:\Temp\WindowsUpdate\PendingReboot.txt"
        }
        FailureMarker                = "C:\Temp\WindowsUpdate\UpgradeFailed.txt"

        # ISO download/validation
        Windows11IsoUrl              = Resolve-ParameterOrToken -Value $Windows11IsoUrl -Token "@Windows11IsoUrl@"
        ExpectedIsoSha256            = Resolve-ParameterOrToken -Value $ISOHash -Token "@ISOHash@"
        IsoFilePath                  = "C:\Temp\WindowsUpdate\Windows11_25H2.iso"
        IsoHashCacheFile             = "C:\Temp\WindowsUpdate\Windows11_25H2.iso.sha256"
        MinimumIsoSizeBytes          = [int64](4 * 1GB)

        # Setup execution
        SetupExeBaseArguments        = "/Auto Upgrade /copylogs `"{0}`" /NoReboot /EULA accept /Quiet"
        SetupExeArguments            = ""
        MoSetupVolatileKey           = "HKLM:\SYSTEM\Setup\MoSetup\Volatile"

        # Tasks and reminders
        PostRebootValidationTaskName = "Win11_PostRebootValidation"
        PostRebootValidationRunOnce  = "Win11_PostRebootValidation_RunOnce"
        ReminderTaskNames            = @("Win11_RebootReminder_1", "Win11_RebootReminder_2")
        RebootReminder1Time          = Resolve-ParameterOrToken -Value $RebootReminder1Time -Token "@RebootReminder1Time@"
        RebootReminder2Time          = Resolve-ParameterOrToken -Value $RebootReminder2Time -Token "@RebootReminder2Time@"
        RebootReminderScript         = "C:\Temp\WindowsUpdate\RebootReminderNotification.ps1"
        RebootReminderVbs            = "C:\Temp\WindowsUpdate\RunHiddenReminder.vbs"
        PostRebootScriptPath         = "C:\Temp\WindowsUpdate\Windows11Upgrade.ps1"

        # Toast configuration
        ToastAssetsRoot              = "C:\Temp\WindowsUpdate\Toast-Notification"
        ToastHeroImage               = "hero.jpg"
        ToastLogoImage               = "logo.jpg"
        DocLink                      = Resolve-ParameterOrToken -Value $DocLink -Token "@UpgradeGuide@"
        ToastAttributionText         = "Koltiv"
        ToastHeaderText              = "Windows 11 Upgrade"

        # Compatibility & behavior toggles
        MinimumSentinelAgentVersion  = "24.2.2.0"
        DynamicUpdate                = Resolve-BoolOrToken -Value $DynamicUpdate -Token "@DynamicUpdate@" -Default $true
        AutoReboot                   = Resolve-BoolOrToken -Value $AutoReboot -Token "@AutoReboot@" -Default $false
    }

    return $config
}

function Write-ConfigJson {
    param(
        [Parameter(Mandatory)]
        [psobject]$ConfigObject,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $json = $ConfigObject | ConvertTo-Json -Depth 5
    Set-Content -Path $Path -Value $json -Encoding ASCII
    Write-Log -Message ("config.json written to {0}" -f $Path) -Level "INFO"
}

$config = New-UpgradeConfigObject
Write-ConfigJson -ConfigObject $config -Path $configPath
