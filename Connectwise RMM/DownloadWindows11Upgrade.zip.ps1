# Ensure target directories exist
$TempDir = "C:\Temp"
$ZipPath = "$TempDir\Windows11Upgrade.zip"
$ExtractPath = "C:\Temp\WindowsUpdate"
$logFile = "C:\Windows11UpgradeLog.txt"

if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
}

# Write-Log Function
function Write-Log {
    param (
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

    switch ($Level) {
        "ERROR"   { Write-Error $logMessage }
        "WARN"    { Write-Warning $logMessage }
        "VERBOSE" { Write-Verbose $logMessage }
        default   { Write-Host $logMessage }
    }

    if ($Level -ne "VERBOSE") {
        Write-Verbose $logMessage
    }
}

# Download ZIP from GitHub
$DownloadUrl = "https://github.com/qfixit/Windows11Upgrade/releases/latest/download/Windows11Upgrade.zip"

Write-Log "Downloading Windows 11 Upgrade package..."
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing

# Prepare extraction directory
if (-not (Test-Path $ExtractPath)) {
    New-Item -ItemType Directory -Path $ExtractPath | Out-Null
}

# Clear existing contents
Get-ChildItem -Path $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "Extracting package..."
Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

if (Test-Path -Path $ZipPath) {
    Write-Log "Cleaning up downloaded archive $ZipPath..."
    Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue
}

Write-Log "Completed. Files extracted to $ExtractPath"