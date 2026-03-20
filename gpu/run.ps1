param(
    [string]$ConfigPath = "vanity.config.json"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$configFile = Join-Path $root $ConfigPath

if (-not (Test-Path $configFile)) {
    throw "Config file not found: $configFile"
}

$config = Get-Content $configFile -Raw | ConvertFrom-Json
$resultsPath = Join-Path $root $config.output.results_file
$resultsDir = Split-Path -Parent $resultsPath

function Get-PrivateKeyFormats($outputConfig) {
    $defaults = @("base58")
    $formats = @()

    if ($null -ne $outputConfig.private_key_formats) {
        $formats = @($outputConfig.private_key_formats)
    }

    if ($formats.Count -eq 0) {
        $formats = $defaults
    }

    if ($formats -contains "all") {
        return @("base58", "solana-json", "seed-base58", "seed-hex")
    }

    return $formats
}

if ($resultsDir) {
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
}

$privateKeyFormats = Get-PrivateKeyFormats $config.output

& (Join-Path $PSScriptRoot "build.ps1") `
    -ConfigPath $ConfigPath

$binary = Join-Path $root "gpu\bin\solana-vanity-gpu.exe"
$args = @("--attempts-per-execution", [string]$config.gpu.attempts_per_execution)

if ($config.gpu.max_iterations -gt 0) {
    $args += @("--max-iterations", [string]$config.gpu.max_iterations)
}

if ($config.gpu.max_matches -gt 0) {
    $args += @("--max-matches", [string]$config.gpu.max_matches)
}

foreach ($format in $privateKeyFormats) {
    $args += @("--private-key-format", $format)
}

& $binary @args 2>&1 | ForEach-Object {
    $line = "$_"
    if ($line.StartsWith("JSONMATCH ")) {
        $json = $line.Substring(10)
        Add-Content -Path $resultsPath -Value $json -Encoding ascii
    } else {
        Write-Host $line
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "GPU run failed with exit code $LASTEXITCODE"
}
