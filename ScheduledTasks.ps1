# Scheduled Task Helpers
# Version 2.5.9
# Date 11/29/2025
# Author: Quintin Sheppard
# Summary: Registers/cleans reboot reminder tasks and post-reboot validation tasks.
# Example: powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ". '\\Windows11Upgrade\\ScheduledTasks.ps1'; Register-RebootReminderTasks"

function Register-RebootReminderTasks {
    Write-Log -Message "Configuring reboot reminder notifications." -Level "INFO"

    try {
        if ([string]::IsNullOrWhiteSpace($privateRoot)) {
            try {
                if ($PSScriptRoot) {
                    $privateRoot = $PSScriptRoot
                } elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
                    $privateRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
                } else {
                    $privateRoot = (Get-Location).ProviderPath
                }
            } catch {
                $privateRoot = (Get-Location).ProviderPath
            }
            Write-Log -Message ("Resolved privateRoot to {0} for reminder task registration." -f $privateRoot) -Level "VERBOSE"
        }
        $user = $null
        try {
            $user = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty UserName
        } catch {
            Write-Log -Message "Unable to query logged-on user for reminders. Error: $_" -Level "WARN"
        }

    $toastReminderScript = Join-Path -Path $privateRoot -ChildPath "Toast-Notification\Toast-Windows11RebootReminder.ps1"
    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\WindowsPowerShell\v1.0\powershell.exe"
    $schtasksExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\schtasks.exe"

    if ([string]::IsNullOrWhiteSpace($toastReminderScript) -or -not (Test-Path -Path $toastReminderScript -PathType Leaf)) {
        Write-Log -Message ("Reboot reminder toast script missing at {0}; reminder tasks will not be registered. privateRoot={1}" -f $toastReminderScript, $privateRoot) -Level "WARN"
        return
    }

    if (-not (Test-Path -Path $powershellExe -PathType Leaf)) {
        Write-Log -Message ("PowerShell executable not found at expected path {0}; reminder tasks will not be registered." -f $powershellExe) -Level "WARN"
        return
    }

    $command = "`"$powershellExe`" -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$toastReminderScript`""
    Write-Log -Message ("Reminder task command: {0}" -f $command) -Level "VERBOSE"

    foreach ($taskName in $reminderTaskNames) {
        try {
            & $schtasksExe /Delete /TN $taskName /F 2>$null | Out-Null
        } catch {
            # Ignore missing tasks or delete failures so registration can continue.
        }
    }

    if ($user) {
        $taskCommand = ('"{0}"' -f $command)
        $createArgs1 = "/Create", "/TN", $reminderTaskNames[0], "/TR", $taskCommand, "/SC", "DAILY", "/ST", $RebootReminder1Time, "/RL", "HIGHEST", "/F", "/IT", "/RU", $user
        $output1 = & $schtasksExe $createArgs1 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message ("Failed to register {0}. Exit code: {1}. Command: schtasks {2}" -f $reminderTaskNames[0], $LASTEXITCODE, ($createArgs1 -join " ")) -Level "ERROR"
            if ($output1) { Write-Log -Message ("schtasks output: {0}" -f (($output1 | Out-String).Trim())) -Level "WARN" }
        } else {
            Write-Log -Message ("{0} registered for {1} daily." -f $reminderTaskNames[0], $RebootReminder1Time) -Level "INFO"
        }

        $createArgs2 = "/Create", "/TN", $reminderTaskNames[1], "/TR", $taskCommand, "/SC", "DAILY", "/ST", $RebootReminder2Time, "/RL", "HIGHEST", "/F", "/IT", "/RU", $user
        $output2 = & $schtasksExe $createArgs2 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message ("Failed to register {0}. Exit code: {1}. Command: schtasks {2}" -f $reminderTaskNames[1], $LASTEXITCODE, ($createArgs2 -join " ")) -Level "ERROR"
            if ($output2) { Write-Log -Message ("schtasks output: {0}" -f (($output2 | Out-String).Trim())) -Level "WARN" }
        } else {
            Write-Log -Message ("{0} registered for {1} daily." -f $reminderTaskNames[1], $RebootReminder2Time) -Level "INFO"
        }
        $script:ReminderRegistrationMode = "ImmediateUser"
    } else {
        Write-Log -Message "No interactive user detected; scheduling reboot reminders to display at next user logon." -Level "WARN"
        try {
            Import-Module ScheduledTasks -ErrorAction Stop
        } catch {
            Write-Log -Message "Unable to import ScheduledTasks module. Reminder tasks will not be queued. Error: $_" -Level "ERROR"
            return
        }

        $trigger = New-ScheduledTaskTrigger -AtLogOn
        if ([string]::IsNullOrWhiteSpace($powershellExe) -or [string]::IsNullOrWhiteSpace($toastReminderScript)) {
            Write-Log -Message ("Cannot create reminder action because PowerShell or toast script path is empty. PowerShell={0}; Toast={1}" -f $powershellExe, $toastReminderScript) -Level "WARN"
            return
        }
        $actionObj = New-ScheduledTaskAction -Execute $powershellExe -Argument ("-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"{0}`"" -f $toastReminderScript)
        $principal = New-ScheduledTaskPrincipal -UserId "INTERACTIVE" -LogonType Interactive -RunLevel Highest

        foreach ($taskName in $reminderTaskNames) {
            try {
                Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $actionObj -Principal $principal -Force | Out-Null
                Write-Log -Message "$taskName registered with Interactive logon trigger." -Level "INFO"
            } catch {
                Write-Log -Message "Failed to register $taskName for logon reminder. Error: $_" -Level "ERROR"
            }
        }
        $script:ReminderRegistrationMode = "LogonFallback"
    }
    } catch {
        Write-Log -Message ("Failed to register reboot reminder tasks. Error: {0}" -f $_) -Level "WARN"
    }
}

function Remove-RebootReminderTasks {
    $schtasksExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\schtasks.exe"
    foreach ($taskName in $reminderTaskNames) {
        try {
            & $schtasksExe /Delete /TN $taskName /F 2>$null | Out-Null
        } catch {
            # Ignore deletion errors during cleanup.
        }
        Write-Log -Message "Removed scheduled task $taskName (if it existed)." -Level "VERBOSE"
    }

    if (Test-Path -Path $rebootReminderScript) {
        Remove-Item -Path $rebootReminderScript -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -Path $rebootReminderVbs) {
        Remove-Item -Path $rebootReminderVbs -Force -ErrorAction SilentlyContinue
    }
}

function Register-PostRebootValidationTask {
    $targetScript = Join-Path -Path $privateRoot -ChildPath "PostUpgradeCleanup.ps1"

    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\WindowsPowerShell\v1.0\powershell.exe"
    $schtasksExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\schtasks.exe"
    try {
        & $schtasksExe /Delete /TN $postRebootValidationTaskName /F 2>$null | Out-Null
    } catch {
        # Missing task is fine; continue to registration.
    }
    if (-not (Test-Path -Path $powershellExe -PathType Leaf)) {
        Write-Log -Message ("PowerShell executable not found at expected path {0}; post-reboot validation task will not be registered." -f $powershellExe) -Level "WARN"
        return
    }

    if (-not (Test-Path -Path $targetScript -PathType Leaf)) {
        Write-Log -Message ("Post-reboot validation script missing at {0}; task will not be registered." -f $targetScript) -Level "WARN"
        return
    }

    $command = "`"$powershellExe`" -ExecutionPolicy Bypass -NoProfile -File `"$targetScript`""
    $schtasksExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\schtasks.exe"
    $schtasksArgs = @(
        "/Create",
        "/TN", $postRebootValidationTaskName,
        "/TR", $command,
        "/SC", "ONLOGON",
        "/RL", "HIGHEST",
        "/F",
        "/RU", "SYSTEM"
    )

    try {
        $schtasksOutput = & $schtasksExe @schtasksArgs 2>&1
    } catch {
        Write-Log -Message ("Register-PostRebootValidationTask execution failed. Command: {0} {1}. Error: {2}" -f $schtasksExe, ($schtasksArgs -join " "), $_) -Level "WARN"
        return
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log -Message ("Failed to register post-reboot validation task. Exit code: {0}. Command: {1}" -f $LASTEXITCODE, $command) -Level "WARN"
        if ($schtasksOutput) {
            $formatted = ($schtasksOutput | Where-Object { $_ } | Out-String).Trim()
            if ($formatted) {
                Write-Log -Message ("schtasks output: {0}" -f $formatted) -Level "WARN"
            }
        }
    } else {
        Write-Log -Message "Post-reboot validation task registered to rerun the script after the next restart." -Level "INFO"
    }

    # RunOnce fallback in case Task Scheduler deletes/blocks the task before reboot.
    if ($postRebootValidationRunOnce) {
        try {
            $runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            New-Item -Path $runOnceKey -Force | Out-Null
            Set-ItemProperty -Path $runOnceKey -Name $postRebootValidationRunOnce -Value $command -Force
            Write-Log -Message ("Registered RunOnce fallback {0} to execute post-reboot validation." -f $postRebootValidationRunOnce) -Level "VERBOSE"
        } catch {
            Write-Log -Message ("Failed to register RunOnce fallback for post-reboot validation. Error: {0}" -f $_) -Level "WARN"
        }
    }
}

function Register-PostRebootValidationTask {
    $targetScript = Join-Path -Path $privateRoot -ChildPath "Windows11Upgrade.ps1"

    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\WindowsPowerShell\v1.0\powershell.exe"

    if (-not (Test-Path -Path $powershellExe -PathType Leaf)) {
        Write-Log -Message ("PowerShell executable not found at expected path {0}; post-reboot validation runonce will not be registered." -f $powershellExe) -Level "WARN"
        return
    }

    if (-not (Test-Path -Path $targetScript -PathType Leaf)) {
        Write-Log -Message ("Post-reboot validation script missing at {0}; runonce will not be registered." -f $targetScript) -Level "WARN"
        return
    }

    if ($postRebootValidationRunOnce) {
        try {
            $runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            New-Item -Path $runOnceKey -Force | Out-Null
            $command = ('"{0}" -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "{1}"' -f $powershellExe, $targetScript)
            Set-ItemProperty -Path $runOnceKey -Name $postRebootValidationRunOnce -Value $command -Force
            Write-Log -Message ("Registered RunOnce {0} to execute post-reboot validation." -f $postRebootValidationRunOnce) -Level "VERBOSE"
        } catch {
            Write-Log -Message ("Failed to register RunOnce for post-reboot validation. Error: {0}" -f $_) -Level "WARN"
        }
    }
}

function Remove-PostRebootValidationTask {
    if ($postRebootValidationRunOnce) {
        try {
            $runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            if (Test-Path -Path $runOnceKey) {
                Remove-ItemProperty -Path $runOnceKey -Name $postRebootValidationRunOnce -ErrorAction Stop
                Write-Log -Message ("Removed RunOnce fallback {0}." -f $postRebootValidationRunOnce) -Level "VERBOSE"
            }
        } catch {
            Write-Log -Message ("Failed to remove RunOnce fallback {0}. Error: {1}" -f $postRebootValidationRunOnce, $_) -Level "WARN"
        }
    }

    if (Test-Path -Path $postRebootScriptPath) {
        $shouldRemoveScript = $true
        if ($script:CurrentScriptPath -and ([System.IO.Path]::GetFullPath($postRebootScriptPath) -eq [System.IO.Path]::GetFullPath($script:CurrentScriptPath))) {
            $shouldRemoveScript = $false
        }
        if ($shouldRemoveScript) {
            try {
                Remove-Item -Path $postRebootScriptPath -Force -ErrorAction Stop
                Write-Log -Message "Removed persisted post-reboot script at $postRebootScriptPath." -Level "VERBOSE"
            } catch {
                Write-Log -Message "Failed to remove persisted post-reboot script. Error: $_" -Level "WARN"
            }
        }
    }
}
