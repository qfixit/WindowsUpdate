# Get-SetupDiag Helper
# Version 2.7.0
# Date 12/03/2025
# Author: Quintin Sheppard
# Summary: Runs SetupDiag and appends results to C:\Windows11UpgradeLog.txt for post-failure analysis.

param()

$ErrorActionPreference = "Stop"

function Get-LogFilePath {
    if ($script:logFile) { return $script:logFile }
    if ($global:logFile) { return $global:logFile }
    return "C:\Windows11UpgradeLog.txt"
}

function Invoke-SetupDiagCapture {
    $logPath = Get-LogFilePath
    $tempRoot = "C:\Temp\WindowsUpdate"
    if (-not (Test-Path -Path $tempRoot)) {
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    }

    $setupDiagPath = Join-Path -Path $tempRoot -ChildPath "SetupDiag.exe"
    $resultsPath = Join-Path -Path $tempRoot -ChildPath "SetupDiagResults.txt"
    $downloadUrl = "https://go.microsoft.com/fwlink/?linkid=870142"

    try {
        $existing = Get-Command setupdiag.exe -ErrorAction SilentlyContinue
        if ($existing) {
            $setupDiagPath = $existing.Source
        } elseif (-not (Test-Path -Path $setupDiagPath -PathType Leaf)) {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $setupDiagPath -UseBasicParsing
        }
    } catch {
        Add-Content -Path $logPath -Value ("[{0}] [WARN] SetupDiag download failed: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_)
        return
    }

    try {
        if (Test-Path -Path $resultsPath) {
            Remove-Item -Path $resultsPath -Force -ErrorAction SilentlyContinue
        }
        $args = @("/Output:$resultsPath")
        $proc = Start-Process -FilePath $setupDiagPath -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        $exitCode = if ($proc) { $proc.ExitCode } else { $LASTEXITCODE }
        Add-Content -Path $logPath -Value ("[{0}] [INFO] SetupDiag exited with code {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $exitCode)

        if (Test-Path -Path $resultsPath -PathType Leaf) {
            $diagContent = Get-Content -Path $resultsPath -Raw -ErrorAction SilentlyContinue
            if ($diagContent) {
                Add-Content -Path $logPath -Value ("[{0}] [INFO] SetupDiag results:" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
                Add-Content -Path $logPath -Value $diagContent
            } else {
                Add-Content -Path $logPath -Value ("[{0}] [WARN] SetupDiag results file was empty." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
            }
        } else {
            Add-Content -Path $logPath -Value ("[{0}] [WARN] SetupDiag results file not found." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        }
    } catch {
        Add-Content -Path $logPath -Value ("[{0}] [ERROR] SetupDiag execution failed: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_)
    }
}

Invoke-SetupDiagCapture
