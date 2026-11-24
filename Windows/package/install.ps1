# Installs the Postern preview for Windows for the current user, then connects your AI apps and sets up Windows Hello.
# Run it from the unzipped folder:  powershell -ExecutionPolicy Bypass -File .\install.ps1
$ErrorActionPreference = "Stop"
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $env:LOCALAPPDATA "Programs\Postern"
New-Item -ItemType Directory -Force -Path $target | Out-Null
Get-Process postern-core -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item -Path (Join-Path $source "bin\*") -Destination $target -Recurse -Force

# The core starts with your session, without a window.
$startup = [Environment]::GetFolderPath("Startup")
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $startup "Postern.lnk"))
$link.TargetPath = Join-Path $target "postern-core.exe"
$link.WorkingDirectory = $target
$link.Save()
Start-Process -FilePath (Join-Path $target "postern-core.exe") -WorkingDirectory $target

# The command line, from any terminal.
$path = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not ($path -split ";" | Where-Object { $_ -eq $target })) {
    [Environment]::SetEnvironmentVariable("Path", ($path.TrimEnd(";") + ";" + $target), "User")
}

Write-Host "Postern is installed in $target."
Write-Host "Next: open a new terminal and run   postern setup   (Proton Mail Bridge must be running and signed in)."
Write-Host "Then connect an app, for example:   postern apps connect claudeCode"
