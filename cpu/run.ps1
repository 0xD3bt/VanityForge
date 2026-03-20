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

function Get-PatternList([string]$relativePath) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path $path)) {
        throw "Pattern file not found: $path"
    }

    Get-Content $path | Where-Object {
        $trimmed = $_.Trim()
        $trimmed.Length -gt 0 -and -not $trimmed.StartsWith("#")
    } | ForEach-Object { $_.Trim() }
}

$hasGroupedRules = $null -ne $config.rules -and @($config.rules).Count -gt 0

if ($hasGroupedRules) {
    $prefixes = @()
    $suffixes = @()
} else {
    $prefixes = Get-PatternList $config.patterns.prefix_file
    $suffixes = Get-PatternList $config.patterns.suffix_file

    if ($prefixes.Count -eq 0 -and $suffixes.Count -eq 0) {
        throw "At least one prefix or suffix pattern is required"
    }
}

$resultsPath = Join-Path $root $config.output.results_file
$singleKeypairPath = Join-Path $root $config.output.single_keypair_file
$matchesDir = Join-Path $root $config.output.matches_dir
$privateKeyFormats = Get-PrivateKeyFormats $config.output
$saveFilterEnabled = $null -ne $config.output.enable_save_filter -and [bool]$config.output.enable_save_filter
$minMatchedPrefixLength = if ($null -ne $config.output.min_matched_prefix_length) { [int]$config.output.min_matched_prefix_length } else { 0 }
$minMatchedSuffixLength = if ($null -ne $config.output.min_matched_suffix_length) { [int]$config.output.min_matched_suffix_length } else { 0 }
$saveMatchMode = if ($null -ne $config.output.save_match_mode -and -not [string]::IsNullOrWhiteSpace([string]$config.output.save_match_mode)) { [string]$config.output.save_match_mode } else { "both" }

$resultsDir = Split-Path -Parent $resultsPath
if ($resultsDir) {
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
}

$singleKeypairDir = Split-Path -Parent $singleKeypairPath
if ($singleKeypairDir) {
    New-Item -ItemType Directory -Force -Path $singleKeypairDir | Out-Null
}

if ($config.output.write_match_files) {
    New-Item -ItemType Directory -Force -Path $matchesDir | Out-Null
}

& (Join-Path $PSScriptRoot "build.ps1")

$binary = Join-Path $root "target\release\solana-vanity.exe"
if (-not (Test-Path $binary)) {
    throw "CPU binary not found: $binary"
}

$args = @()
if ($hasGroupedRules) {
    $args += @("--grouped-rules-config", $configFile)
} else {
    foreach ($prefix in $prefixes) {
        $args += @("--prefix", $prefix)
    }
    foreach ($suffix in $suffixes) {
        $args += @("--suffix", $suffix)
    }
}

if ($config.cpu.threads -gt 0) {
    $args += @("--threads", [string]$config.cpu.threads)
}

if ($config.cpu.report_every -gt 0) {
    $args += @("--report-every", [string]$config.cpu.report_every)
}

if ($config.cpu.max_attempts -gt 0) {
    $args += @("--max-attempts", [string]$config.cpu.max_attempts)
}

if ($config.cpu.keep_running) {
    $args += @("--keep-running", "--results-file", $resultsPath)
    if ($saveFilterEnabled) {
        if ($minMatchedPrefixLength -gt 0) {
            $args += @("--min-matched-prefix-length", [string]$minMatchedPrefixLength)
        }
        if ($minMatchedSuffixLength -gt 0) {
            $args += @("--min-matched-suffix-length", [string]$minMatchedSuffixLength)
        }
        $args += @("--save-match-mode", $saveMatchMode)
    }
    if ($config.output.write_match_files) {
        $args += @("--write-match-files", "--matches-dir", $matchesDir)
    }
} else {
    $args += @("--out", $singleKeypairPath)
}

foreach ($format in $privateKeyFormats) {
    $args += @("--private-key-format", $format)
}

& $binary @args

if ($LASTEXITCODE -ne 0) {
    throw "CPU run failed with exit code $LASTEXITCODE"
}
