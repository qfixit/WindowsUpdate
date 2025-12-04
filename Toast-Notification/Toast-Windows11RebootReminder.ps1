# Windows 11 Reboot Reminder Toast Notification
# Version 2.5.9
# Date 11/29/2025
# Author Remark: Quintin Sheppard

[CmdletBinding()]
param(
    [switch]$Scheduled
)

$scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } elseif ($PSCommandPath) { $PSCommandPath } else { $null }
$system32Path = Join-Path -Path $env:SystemRoot -ChildPath "System32"
$powershellExe = [System.IO.Path]::Combine($system32Path, "WindowsPowerShell", "v1.0", "powershell.exe")
$wscriptExe = [System.IO.Path]::Combine($system32Path, "wscript.exe")
$tempRoot = "C:\Temp\WindowsUpdate"
$vbsPath = Join-Path -Path $tempRoot -ChildPath "RunHidden_RebootToast.vbs"
$taskName = "Win11_RebootToast_Local"

if (-not $Scheduled) {
    if (-not $scriptPath) {
        Write-Warning "Unable to resolve script path for scheduling; skipping toast."
        return
    }

    if (-not (Test-Path -Path $tempRoot)) {
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    }

    @'
Dim objShell
Set objShell = CreateObject("WScript.Shell")
objShell.Run "POWERSHELLEXE -ExecutionPolicy Bypass -NoProfile -File """ & WScript.Arguments(0) & """ -Scheduled", 0, False
Set objShell = Nothing
'@.Replace("POWERSHELLEXE", $powershellExe) | Set-Content -Path $vbsPath -Encoding ASCII

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
$logoPath = Join-Path -Path $toastAssetsDirectory -ChildPath "logo.jpg"

if (-not (Test-Path -Path $heroPath)) {
    $heroPath = "C:\Windows\Web\Wallpaper\Windows\img0.jpg"
}

if (-not (Test-Path -Path $logoPath)) {
    $logoPath = ""
}

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

$App = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
$AttributionText = "Koltiv"
$HeaderText = "Windows 11 Upgrade"
$TitleText = "Please Reboot to Complete the Windows 11 Upgrade"
$BodyText1 = "Windows 11 is installed and waiting to finish.`n`nACTION NEEDED: Reboot as soon as it's convenient. The first restart can take longer than normal; do not power off during the upgrade.`n`nNeed help? Use the button below or call`n(515) 223-0078."
$BodyText2 = ""
$SilentAlarm = "true"
$Action = "Dismiss"
$ActionButtonContent = "OK"
$Action2 = "mailto:support@koltiv.com?subject=Windows%2011%20Update%20Notification"
$Action2ButtonContent = "Contact Koltiv Support"

[xml]$ToastXml = @"
    <toast scenario="reminder">
        <visual>
            <binding template="ToastGeneric">
                <image placement="hero" src="$heroPath"/>
                <image id="1" placement="appLogoOverride" hint-crop="circle" src="$logoPath"/>
                <text placement="attribution">$AttributionText</text>
                <text>$HeaderText</text>
                <group>
                    <subgroup>
                        <text hint-style="title" hint-wrap="true">$TitleText</text>
                    </subgroup>
                </group>
                <group>
                    <subgroup>
                        <text hint-style="body" hint-wrap="true">$BodyText1</text>
                        <text hint-style="body" hint-wrap="true">$BodyText2</text>
                    </subgroup>
                </group>
            </binding>
        </visual>
        <audio src="ms-winsoundevent:Notification.Looping.Alarm" silent="$SilentAlarm"/>
        <actions>
            <action activationType="protocol" arguments="$Action" content="$ActionButtonContent"/>
            <action activationType="protocol" arguments="$Action2" content="$Action2ButtonContent"/>
        </actions>
    </toast>
"@

$XmlDocument = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
$XmlDocument.LoadXml($ToastXml.OuterXml)

try {
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($XmlDocument)
    Write-Log "Reboot reminder toast notification displayed." -severity Info
} catch {
    Write-Warning ("Failed to display the notification. Error: {0}" -f $_)
}
