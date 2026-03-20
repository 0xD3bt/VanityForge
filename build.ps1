param(
    [string]$ConfigPath = "vanity.config.json",
    [string]$Engine = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSCommandPath
$configFile = Join-Path $root $ConfigPath

if (-not (Test-Path $configFile)) {
    throw "Config file not found: $configFile"
}

$config = Get-Content $configFile -Raw | ConvertFrom-Json
if (-not $Engine) {
    $Engine = $config.engine
}

switch ($Engine) {
    "cpu" {
        & (Join-Path $root "cpu\build.ps1")
    }
    "gpu" {
        & (Join-Path $root "gpu\build.ps1") `
            -ConfigPath $ConfigPath
    }
    "all" {
        & (Join-Path $root "cpu\build.ps1")
        & (Join-Path $root "gpu\build.ps1") `
            -ConfigPath $ConfigPath
    }
    default {
        throw "Unknown engine: $Engine. Use 'cpu', 'gpu', or 'all'."
    }
}
