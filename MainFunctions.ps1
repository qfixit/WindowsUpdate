# Core Utilities & Progress Helpers
# Version 2.7.1
# Date 12/04/2025
# Author: Quintin Sheppard
# Summary: Common logging, directory creation, and progress/summary helpers used across the upgrade workflow.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Windows11Upgrade\\MainFunctions.ps1'; Write-Log 'hello world'"

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "VERBOSE")]
        [string]$Level = "INFO"
    )

    if ([string]::IsNullOrWhiteSpace($logFile)) {
        $logFile = "C:\Windows11UpgradeLog.txt"
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"

    if (-not [string]::IsNullOrWhiteSpace($logFile)) {
        $directory = Split-Path -Path $logFile -Parent
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $fileStream = [System.IO.File]::Open($logFile,
                                                 [System.IO.FileMode]::OpenOrCreate,
                                                 [System.IO.FileAccess]::Write,
                                                 [System.IO.FileShare]::ReadWrite)
            $fileStream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            $writer = New-Object System.IO.StreamWriter($fileStream, [System.Text.Encoding]::UTF8)
            $writer.WriteLine($logMessage)
            $writer.Dispose()
            $fileStream.Dispose()
            break
        } catch {
            if ($attempt -eq $maxAttempts) {
                Write-Warning "Unable to append to $logFile after $maxAttempts attempts. Error: $_"
            } else {
                Start-Sleep -Milliseconds 250
            }
        }
    }

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        switch ($Level) {
            "ERROR"   { Write-Error -Message $logMessage -ErrorAction Continue }
            "WARN"    { Write-Warning $logMessage }
            "VERBOSE" { Write-Verbose $logMessage }
            default   { Write-Information -MessageData $logMessage -InformationAction Continue }
        }

        if ($Level -ne "VERBOSE") {
            Write-Verbose $logMessage
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

function Ensure-Directory {
    param ([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-Log -Message "Created directory $Path" -Level "VERBOSE"
    }
}

function Clean-BitsTempFiles {
    try {
        if ($stateDirectory -and (Test-Path -Path $stateDirectory)) {
            Get-ChildItem -Path $stateDirectory -Filter "BIT*.tmp" -File -ErrorAction Stop | ForEach-Object {
                try { Remove-Item -Path $_.FullName -Force -ErrorAction Stop } catch {}
            }
        }
    } catch {
        Write-Log -Message ("Unable to clean BITS temp files. Error: {0}" -f $_) -Level "WARN"
    }
}

function Get-ToastAppId {
    $appId = "Koltiv.Windows11Upgrade"
    $shortcutName = "Koltiv Windows 11 Upgrade.lnk"

    $candidateRoots = @()
    if ($env:APPDATA) { $candidateRoots += $env:APPDATA }
    if ($env:ProgramData) { $candidateRoots += $env:ProgramData }
    $shortcutPath = $null

    foreach ($root in $candidateRoots) {
        $targetDir = Join-Path -Path $root -ChildPath "Microsoft\Windows\Start Menu\Programs"
        $candidatePath = Join-Path -Path $targetDir -ChildPath $shortcutName
        try {
            if (-not (Test-Path -Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $shortcutPath = $candidatePath
            break
        } catch {
            Write-Log -Message ("Unable to prepare toast shortcut directory {0}. Error: {1}" -f $targetDir, $_) -Level "VERBOSE"
            continue
        }
    }

    if ($shortcutPath -and -not (Test-Path -Path $shortcutPath -PathType Leaf)) {
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $shortcut = $wsh.CreateShortcut($shortcutPath)
            $powershellExe = [System.IO.Path]::Combine($env:SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
            $shortcut.TargetPath = $powershellExe
            $shortcut.Arguments = "-NoProfile"
            $shortcut.WorkingDirectory = Split-Path -Path $shortcutPath -Parent
            if ($ToastAssetsRoot) {
                $iconPath = Join-Path -Path $ToastAssetsRoot -ChildPath "logo.png"
                if (Test-Path -Path $iconPath -PathType Leaf) {
                    $shortcut.IconLocation = $iconPath
                }
            }
            $shortcut.Save() | Out-Null
        } catch {
            Write-Log -Message ("Failed to create toast shortcut for app identity. Error: {0}" -f $_) -Level "VERBOSE"
        }
    }

    return $appId
}

function Should-ShowToastPhase {
    param([string]$Phase)

    if ([string]::IsNullOrWhiteSpace($Phase)) { return $false }
    $markerDir = if ($stateDirectory) { $stateDirectory } else { $env:TEMP }
    $markerPath = Join-Path -Path $markerDir -ChildPath ("Toast-{0}-Shown.txt" -f $Phase)

    if (Test-Path -Path $markerPath -PathType Leaf) {
        return $false
    }

    try {
        "shown" | Set-Content -Path $markerPath -Encoding ASCII -ErrorAction SilentlyContinue
    } catch {}

    return $true
}

function Show-UpgradeProgressToast {
    param(
        [ValidateSet('Download', 'Install')]
        [string]$Phase,
        [double]$PercentComplete = -1,
        [string]$Status,
        [string]$TitleText,
        [string]$BodyText,
        [string]$DocLink
    )

    if (-not $ToastAssetsRoot) { return }

    $toastScript = Join-Path -Path $ToastAssetsRoot -ChildPath "Toast-Windows11Download.ps1"
    if (-not (Test-Path -Path $toastScript -PathType Leaf)) { return }

    $phaseChanged = $false
    if ($script:LastToastPhase) {
        if ($script:LastToastPhase -ne $Phase) { $phaseChanged = $true }
    }
    $script:LastToastPhase = $Phase

    $renderPercent = $PercentComplete
    if ($phaseChanged -and $PercentComplete -ge 0) {
        $renderPercent = 0
    }

    $powershellExe = [System.IO.Path]::Combine($env:SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    $argumentList = @(
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", "`"$toastScript`"",
        "-Phase", $Phase,
        "-PercentComplete", ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0}", $renderPercent))
    )

    if ($Status) { $argumentList += @("-Status", "`"$Status`"") }
    if ($TitleText) { $argumentList += @("-TitleText", "`"$TitleText`"") }
    if ($BodyText) { $argumentList += @("-BodyText", "`"$BodyText`"") }
    $docToUse = if ($DocLink) { $DocLink } elseif ($script:DocLink) { $script:DocLink } elseif ($global:DocLink) { $global:DocLink } else { $null }
    if ($docToUse) { $argumentList += @("-DocLink", "`"$docToUse`"") }

    try {
        Start-Process -FilePath $powershellExe -ArgumentList ($argumentList -join ' ') -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        Write-Log -Message ("Failed to launch progress toast. Error: {0}" -f $_) -Level "WARN"
    }
}

function Write-ErrorCode {
    param(
        [Parameter(Mandatory)][object]$Code,
        [string]$Detail = ""
    )

    $info = $null
    if (Get-Command -Name Get-ErrorCodeInfo -ErrorAction SilentlyContinue) {
        $info = Get-ErrorCodeInfo -Code $Code
    }

    $codeDisplay = if ($info -and $info.Code) { $info.Code } else { $Code }
    $title = if ($info) { $info.Title } else { "Unknown error" }
    $description = if ($info) { $info.Description } else { "" }
    $remediation = if ($info) { $info.Remediation } else { "" }

    $message = ("Error {0}: {1}" -f $codeDisplay, $title)
    if ($description) { $message = "$message. $description" }
    if ($Detail) { $message = "$message. $Detail" }
    if ($remediation) { $message = "$message. Remediation: $remediation" }

    Write-Log -Message $message -Level "ERROR"
    if (Get-Command -Name Write-FailureMarker -ErrorAction SilentlyContinue) {
        Write-FailureMarker $message
    }

    $exitValue = 1
    $parsed = $null
    if ([int]::TryParse($Code.ToString(), [ref]$parsed)) {
        $exitValue = $parsed
    }
    $global:LASTEXITCODE = $exitValue
    exit $exitValue
}

function Get-SetupProgressSnapshot {
    try {
        $props = Get-ItemProperty -Path $moSetupVolatileKey -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    } catch {
        Write-Log -Message ("Unable to query MoSetup progress registry path. Error: {0}" -f $_) -Level "VERBOSE"
        return $null
    }

    if ($props.PSObject.Properties.Match("SetupProgress").Count -eq 0) {
        return $null
    }

    return [pscustomobject]@{
        SetupProgress = [int]$props.SetupProgress
    }
}

function Write-SetupProgressUpdate {
    param(
        [hashtable]$Tracker,
        [switch]$Force
    )

    if (-not $Tracker) {
        $Tracker = @{
            LastProgress   = $null
            SourceDetected = $false
            MissingLogged  = $false
        }
    }

    $snapshot = Get-SetupProgressSnapshot
    if (-not $snapshot) {
        if ($Tracker.SourceDetected -and -not $Tracker.MissingLogged) {
            Write-Log -Message "MoSetup progress registry key not available yet. Waiting for setup.exe to publish progress." -Level "VERBOSE"
            $Tracker.MissingLogged = $true
        }
        return
    }

    $Tracker.MissingLogged = $false
    if (-not $Tracker.SourceDetected) {
        Write-Log -Message "Tracking Windows setup progress." -Level "INFO"
        $Tracker.SourceDetected = $true
    }

    $shouldLog = $false
    if (-not $Tracker.ContainsKey("LastToastProgress")) {
        $Tracker["LastToastProgress"] = $null
    }

    if ($null -ne $snapshot.SetupProgress -and ($Force -or $snapshot.SetupProgress -ne $Tracker.LastProgress)) {
        Write-Log -Message ("Install progress {0}%" -f $snapshot.SetupProgress) -Level "INFO"
        $Tracker.LastProgress = $snapshot.SetupProgress
        $shouldLog = $true

        $lastToast = $Tracker.LastToastProgress
        $toastDelta = if ($lastToast -eq $null) { 100 } else { [math]::Abs($snapshot.SetupProgress - $lastToast) }
        if (Get-Command -Name Show-UpgradeProgressToast -ErrorAction SilentlyContinue) {
            if ($Force -or $toastDelta -ge 5) {
                Show-UpgradeProgressToast -Phase Install -PercentComplete $snapshot.SetupProgress -Status "Installing"
                $Tracker.LastToastProgress = $snapshot.SetupProgress
            }
        }
    }

    if (-not $shouldLog -and $Force -and $Tracker.SourceDetected -and ($Tracker.LastProgress -ne 100)) {
        $finalProgress = if ($null -ne $Tracker.LastProgress) { "{0}%" -f $Tracker.LastProgress } else { "unknown" }
        Write-Log -Message ("Install progress final state: {0}" -f $finalProgress) -Level "INFO"
    }
}

function Write-ExecutionSummary {
    if ($script:SummaryLogged) {
        return
    }

    $totalElapsed = $null
    if ($script:ScriptStopwatch) {
        if ($script:ScriptStopwatch.IsRunning) {
            $script:ScriptStopwatch.Stop()
        }
        $totalElapsed = $script:ScriptStopwatch.Elapsed
    }

    $formatDuration = {
        param($Duration)
        if ($null -eq $Duration) {
            return "N/A"
        }

        return ("{0:hh\:mm\:ss\.fff} ({1:N2} seconds)" -f $Duration, $Duration.TotalSeconds)
    }

    Write-Log -Message "Execution timing summary:" -Level "INFO"
    Write-Log -Message (" - Total runtime: {0}" -f (& $formatDuration $totalElapsed)) -Level "INFO"
    Write-Log -Message (" - ISO download: {0}" -f (& $formatDuration $script:IsoDownloadDuration)) -Level "INFO"
    Write-Log -Message (" - setup.exe execution: {0}" -f (& $formatDuration $script:SetupExecutionDuration)) -Level "INFO"

    $script:SummaryLogged = $true
}

function Complete-Execution {
    param([string]$Message = "Windows 11 upgrade script finished.")

    Write-ExecutionSummary
    Write-Log $Message
}
