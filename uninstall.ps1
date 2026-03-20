param(
    [string]$InstallDir = ""
)

$ErrorActionPreference = "Stop"

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "solana-vanity\bin"
}

$installDirFull = [System.IO.Path]::GetFullPath($InstallDir)
$vanityCmdPath = Join-Path $installDirFull "vanity.cmd"
$vCmdPath = Join-Path $installDirFull "v.cmd"

if (Test-Path $vanityCmdPath) {
    Remove-Item $vanityCmdPath -Force
}

if (Test-Path $vCmdPath) {
    Remove-Item $vCmdPath -Force
}

$currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentUserPath) {
    $entries = $currentUserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.TrimEnd('\') -ine $installDirFull.TrimEnd('\') }
    [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "User")
}

$sessionEntries = $env:Path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) |
    Where-Object { $_.TrimEnd('\') -ine $installDirFull.TrimEnd('\') }
$env:Path = $sessionEntries -join ';'

Write-Host "Removed command shims from $installDirFull"
Write-Host "Open a new terminal if 'vanity' is still cached in your current shell."
