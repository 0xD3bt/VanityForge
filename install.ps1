param(
    [string]$InstallDir = "",
    [switch]$CurrentSessionOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSCommandPath

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "solana-vanity\bin"
}

$installDirFull = [System.IO.Path]::GetFullPath($InstallDir)
New-Item -ItemType Directory -Force -Path $installDirFull | Out-Null

$vanityScript = Join-Path $repoRoot "vanity.ps1"
if (-not (Test-Path $vanityScript)) {
    throw "vanity.ps1 not found at $vanityScript"
}

$wrapperTemplate = @'
@echo off
powershell -ExecutionPolicy Bypass -File "__SCRIPT__" %*
'@

$vanityCmdPath = Join-Path $installDirFull "vanity.cmd"
$vCmdPath = Join-Path $installDirFull "v.cmd"
$wrapperContents = $wrapperTemplate.Replace("__SCRIPT__", $vanityScript.Replace('\', '\\'))

[System.IO.File]::WriteAllText($vanityCmdPath, $wrapperContents, [System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText($vCmdPath, $wrapperContents, [System.Text.Encoding]::ASCII)

$currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathEntries = @()
if ($currentUserPath) {
    $pathEntries = $currentUserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
}

$alreadyOnUserPath = $pathEntries | Where-Object { $_.TrimEnd('\') -ieq $installDirFull.TrimEnd('\') } | Select-Object -First 1
if (-not $alreadyOnUserPath -and -not $CurrentSessionOnly) {
    $newPath = if ($currentUserPath) {
        "$currentUserPath;$installDirFull"
    } else {
        $installDirFull
    }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

$sessionPathEntries = $env:Path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
$alreadyOnSessionPath = $sessionPathEntries | Where-Object { $_.TrimEnd('\') -ieq $installDirFull.TrimEnd('\') } | Select-Object -First 1
if (-not $alreadyOnSessionPath) {
    $env:Path = if ($env:Path) { "$env:Path;$installDirFull" } else { $installDirFull }
}

Write-Host "Installed command shims:"
Write-Host "  $vanityCmdPath"
Write-Host "  $vCmdPath"
Write-Host ""
Write-Host "Commands:"
Write-Host "  vanity help"
Write-Host "  vanity doctor"
Write-Host "  vanity show"
Write-Host "  vanity init"
Write-Host "  vanity smoke"
Write-Host "  vanity run"
Write-Host "  vanity stop"
Write-Host "  v run"

if ($CurrentSessionOnly) {
    Write-Host ""
    Write-Host "PATH updated for this PowerShell session only."
} elseif (-not $alreadyOnUserPath) {
    Write-Host ""
    Write-Host "PATH updated for your user account. Open a new terminal if 'vanity' is not found immediately."
} else {
    Write-Host ""
    Write-Host "Install directory was already on your user PATH."
}

Write-Host ""
Write-Host "If you move this repo later, rerun .\install.ps1 from the new location."
