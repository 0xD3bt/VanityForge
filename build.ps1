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
            -PrefixFile $config.patterns.prefix_file `
            -SuffixFile $config.patterns.suffix_file `
            -CudaArch $config.gpu.cuda_arch
    }
    "all" {
        & (Join-Path $root "cpu\build.ps1")
        & (Join-Path $root "gpu\build.ps1") `
            -PrefixFile $config.patterns.prefix_file `
            -SuffixFile $config.patterns.suffix_file `
            -CudaArch $config.gpu.cuda_arch
    }
    default {
        throw "Unknown engine: $Engine. Use 'cpu', 'gpu', or 'all'."
    }
}
