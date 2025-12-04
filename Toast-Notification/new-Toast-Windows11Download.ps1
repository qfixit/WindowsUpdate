# Windows 11 Upgrade Progress Toast Notification
# Version 2.7.0
# Date 12/03/2025
# Author Remark: Quintin Sheppard

[CmdletBinding()]
param(
    [switch]$Scheduled,
    [ValidateSet('Download', 'Install')]
    [string]$Phase = 'Download',
    [double]$PercentComplete = -1,
    [string]$Status,
    [string]$TitleText,
    [string]$BodyText,
    [string]$DocLink = ""
)

$scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } elseif ($PSCommandPath) { $PSCommandPath } else { $null }
$system32Path = Join-Path -Path $env:SystemRoot -ChildPath "System32"
$powershellExe = [System.IO.Path]::Combine($system32Path, "WindowsPowerShell", "v1.0", "powershell.exe")
$wscriptExe = [System.IO.Path]::Combine($system32Path, "wscript.exe")
$tempRoot = "C:\Temp\WindowsUpdate"
$vbsPath = Join-Path -Path $tempRoot -ChildPath "RunHidden_ProgressToast.vbs"
$taskName = "Win11_ProgressToast_Local"

if (-not $Scheduled) {
    if (-not $scriptPath) {
        Write-Warning "Unable to resolve script path for scheduling; skipping toast."
        return
    }

    if (-not (Test-Path -Path $tempRoot)) {
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    }

    $safeStatus = if ($Status) { $Status } else { "" }
    $safeTitle = if ($TitleText) { $TitleText } else { "" }
    $safeBody = if ($BodyText) { $BodyText } else { "" }

    @'
Dim objShell
Set objShell = CreateObject("WScript.Shell")
objShell.Run "POWERSHELLEXE -ExecutionPolicy Bypass -NoProfile -File """ & WScript.Arguments(0) & """ -Scheduled -Phase PHASEVALUE -PercentComplete PERCENTVALUE -Status ""STATUSVALUE"" -TitleText ""TITLEVALUE"" -BodyText ""BODYVALUE"" -DocLink ""DOCLINKVALUE""", 0, False
Set objShell = Nothing
'@.Replace("POWERSHELLEXE", $powershellExe).
    Replace("PHASEVALUE", $Phase).
    Replace("PERCENTVALUE", $PercentComplete).
    Replace("STATUSVALUE", ($safeStatus -replace '"', '""')).
    Replace("TITLEVALUE", ($safeTitle -replace '"', '""')).
    Replace("BODYVALUE", ($safeBody -replace '"', '""')).
    Replace("DOCLINKVALUE", (($DocLink -replace '"', '""'))) | Set-Content -Path $vbsPath -Encoding ASCII

    $user = $null
    try { $user = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty UserName } catch {}
    if (-not $user) {
        Write-Warning "No logged-on user detected; toast not scheduled."
        return
    }

    $action = "$wscriptExe $vbsPath $scriptPath"
    schtasks /Delete /TN $taskName /F 2>$null
    schtasks /Create /TN $taskName /SC ONCE /TR $action /RL HIGHEST /ST 00:00 /F /IT /RU $user 2>$null
    Start-Sleep -Seconds 1
    schtasks /Run /TN $taskName 2>$null
    Start-Sleep -Seconds 5
    schtasks /Delete /TN $taskName /F 2>$null
    Remove-Item -Path $vbsPath -Force -ErrorAction SilentlyContinue
    return
}

$toastAssetsDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$heroPath = Join-Path -Path $toastAssetsDirectory -ChildPath "hero.jpg"
$logoPath = Join-Path -Path $toastAssetsDirectory -ChildPath "logo.png"

if (-not (Test-Path -Path $heroPath)) { $heroPath = "C:\Windows\Web\Wallpaper\Windows\img0.jpg" }
if (-not (Test-Path -Path $logoPath)) { $logoPath = "" }

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

$App = "Koltiv.Windows11Upgrade"
$AttributionText = "Koltiv"
$HeaderText = "Upgrade in Progress"

$statusText = if ($Status) { $Status } else { if ($Phase -eq 'Install') { "Installing" } else { "Downloading" } }
$titleDefault = "Upgrade in Progress"
$bodyDefault = if ($Phase -eq 'Install') {
    "Windows 11 installation is running. Keep your device powered on and connected until the upgrade completes."
} else {
    "Windows 11 installation files are downloading. Keep your device powered on and online while we prepare the upgrade."
}
$title = if ($TitleText) { $TitleText } else { $titleDefault }
$body = if ($BodyText) { $BodyText } else { $bodyDefault }

$boundedPercent = [math]::Max(0, [math]::Min(100, $PercentComplete))
$value = if ($PercentComplete -ge 0) {
    [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.##}", ($boundedPercent / 100))
} else {
    "indeterminate"
}
$valueString = if ($PercentComplete -ge 0) { ("{0}%" -f [math]::Round($boundedPercent, 0)) } else { "Working..." }

$tag = if ($Phase -eq 'Install') { "Win11InstallProgress" } else { "Win11DownloadProgress" }
$group = "Win11UpgradeProgress"

[xml]$ToastXml = @"
    <toast launch="win11upgrade-progress">
        <visual>
            <binding template="ToastGeneric">
                <image placement="hero" src="$heroPath"/>
                <text placement="attribution">$AttributionText</text>
                <text>$HeaderText</text>
                <text hint-style="body" hint-wrap="true">$title</text>
                <text hint-style="body" hint-wrap="true">$body</text>
                <progress title="Progress" value="$value" valueStringOverride="$valueString" status="$statusText"/>
            </binding>
        </visual>
        <audio src="ms-winsoundevent:Notification.Looping.Alarm" silent="true"/>
        <actions>
            <action activationType="protocol" arguments="Dismiss" content="OK"/>
            <action activationType="protocol" arguments="mailto:support@koltiv.com?subject=Windows%2011%20Update%20Notification" content="Contact Koltiv Support"/>
            <action activationType="protocol" arguments="{=DocLink=}" content="View Upgrade Guide"/>
        </actions>
    </toast>
"@ -f (Get-Date).ToString("o")

$action3Link = if (-not [string]::IsNullOrWhiteSpace($DocLink)) { $DocLink } else { "https://contoso.com/windows11-upgrade-guide" }
$ToastXml.OuterXml = $ToastXml.OuterXml.Replace("{=DocLink=}", $action3Link)

$XmlDocument = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
$XmlDocument.LoadXml($ToastXml.OuterXml)

$toast = [Windows.UI.Notifications.ToastNotification]::new($XmlDocument)
$toast.Tag = $tag
$toast.Group = $group

try {
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($toast)
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message ("Windows 11 {0} progress toast displayed at {1}." -f $Phase.ToLower(), $valueString) -Level "INFO"
    }
} catch {
    Write-Warning ("Failed to display the notification. Error: {0}" -f $_)
}
