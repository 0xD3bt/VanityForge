param(
    [string]$ConfigPath = "vanity.config.json"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSCommandPath
$configFile = Join-Path $root $ConfigPath

if (-not (Test-Path $configFile)) {
    throw "Config file not found: $configFile"
}

$config = Get-Content $configFile -Raw | ConvertFrom-Json

switch ($config.engine) {
    "cpu" { & (Join-Path $root "cpu\run.ps1") -ConfigPath $ConfigPath }
    "gpu" { & (Join-Path $root "gpu\run.ps1") -ConfigPath $ConfigPath }
    default { throw "Unknown engine in config: $($config.engine). Use 'cpu' or 'gpu'." }
}
