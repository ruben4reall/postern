# Builds the Windows archive, dist\postern-<version>-windows-x86_64.zip, and its SHA-256.
# The release workflow runs it on the release build; the Windows workflow runs it on every pull request, so the
# archive a release attaches has already been made and started once.
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    # SwiftPM's bin folder: swift build [-c release] --show-bin-path
    [Parameter(Mandatory = $true)] [string] $Built,
    [Parameter(Mandatory = $true)] [string] $Hello
)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$name = "postern-$Version-windows-x86_64"
$dist = Join-Path $root "dist"
$stage = Join-Path $dist $name
$bin = Join-Path $stage "bin"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $bin | Out-Null

foreach ($program in "postern-core", "postern-mcp", "postern-parser", "postern") {
    Copy-Item (Join-Path $Built "$program.exe") $bin
}
Copy-Item $Hello $bin

# The Swift runtime and Foundation next to the programs, and the Visual C++ runtime they need, so the archive runs
# on a Windows that has neither.
$runtime = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory | Sort-Object Name | Select-Object -Last 1
if (-not $runtime) { throw "The Swift runtime was not found." }
Copy-Item "$($runtime.FullName)\usr\bin\*.dll" $bin
Copy-Item (Join-Path $Built "*.dll") $bin -ErrorAction SilentlyContinue
if (-not $env:VCToolsRedistDir) { throw "The Visual C++ runtime was not found: run this after ilammy/msvc-dev-cmd." }
$crt = Get-ChildItem -Path (Join-Path $env:VCToolsRedistDir "x64") -Directory -Filter "Microsoft.VC*.CRT" | Select-Object -First 1
if (-not $crt) { throw "The Visual C++ runtime was not found in $env:VCToolsRedistDir." }
Copy-Item "$($crt.FullName)\*.dll" $bin
Copy-Item (Join-Path $root "Windows\package\install.ps1"), (Join-Path $root "Windows\package\README-Windows.txt"), (Join-Path $root "LICENSE") $stage

# The programs start from the archive alone, with nothing but Windows on the path.
$saved = $env:Path
$env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
try {
    & (Join-Path $bin "postern.exe") version
    if ($LASTEXITCODE -ne 0) { throw "postern.exe does not start from the archive." }
} finally {
    $env:Path = $saved
}

$zip = Join-Path $dist "$name.zip"
Compress-Archive -Force -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip" | Out-File -Encoding ascii "$zip.sha256"
Remove-Item -Recurse -Force $stage
Write-Host ("dist\$name.zip, {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))
