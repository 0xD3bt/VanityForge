param(
    [string]$CudaPath = $env:CUDA_PATH,
    [string]$PrefixFile = "patterns\prefixes\example.txt",
    [string]$SuffixFile = "patterns\suffixes\example.txt",
    [string]$CudaArch = "sm_89",
    [string]$Output = "gpu\bin\solana-vanity-gpu.exe"
)

$ErrorActionPreference = "Stop"

if (-not $CudaPath) {
    $CudaPath = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2"
}

$nvcc = Join-Path $CudaPath "bin\nvcc.exe"
if (-not (Test-Path $nvcc)) {
    throw "nvcc.exe not found at $nvcc"
}

$vsDevShellCandidates = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2026\BuildTools\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2026\Community\Common7\Tools\Launch-VsDevShell.ps1"
)

$vsDevShell = $vsDevShellCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vsDevShell) {
    throw "Visual Studio developer shell not found. Install Visual Studio Build Tools with C++ or set up a supported Launch-VsDevShell.ps1 path."
}

Set-ExecutionPolicy -Scope Process Bypass | Out-Null
& $vsDevShell -Arch amd64 -HostArch amd64 | Out-Null

$root = Split-Path -Parent $PSScriptRoot
$prefixPath = Join-Path $root $PrefixFile
$suffixPath = Join-Path $root $SuffixFile
$outputPath = Join-Path $root $Output
$outputDir = Split-Path -Parent $outputPath
$generatedHeader = Join-Path $PSScriptRoot "generated_config.h"
$computeArch = $CudaArch -replace "^sm_", "compute_"

if (-not (Test-Path $prefixPath)) {
    throw "Prefix file not found: $prefixPath"
}

if (-not (Test-Path $suffixPath)) {
    throw "Suffix file not found: $suffixPath"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

function Get-PatternList([string]$path) {
    Get-Content $path | Where-Object {
        $trimmed = $_.Trim()
        $trimmed.Length -gt 0 -and -not $trimmed.StartsWith("#")
    } | ForEach-Object { $_.Trim() }
}

$prefixes = Get-PatternList $prefixPath
$suffixes = Get-PatternList $suffixPath

if ($prefixes.Count -eq 0 -and $suffixes.Count -eq 0) {
    throw "At least one prefix or suffix pattern is required"
}

if ($prefixes.Count -gt 128) {
    throw "Too many prefixes for generated CUDA config"
}

if ($suffixes.Count -gt 32) {
    throw "Too many suffixes for generated CUDA config"
}

if (($prefixes | Where-Object { $_.Length -gt 15 } | Select-Object -First 1) -or ($suffixes | Where-Object { $_.Length -gt 15 } | Select-Object -First 1)) {
    throw "GPU pattern entries must be 15 characters or fewer."
}

function Quote-CString([string]$s) {
    '"' + ($s.Replace('\', '\\').Replace('"', '\"')) + '"'
}

$prefixCount = [Math]::Max(1, $prefixes.Count)
$suffixCount = [Math]::Max(1, $suffixes.Count)
$prefixLengths = if ($prefixes.Count -gt 0) { ($prefixes | ForEach-Object { $_.Length }) -join ", " } else { "0" }
$suffixLengths = if ($suffixes.Count -gt 0) { ($suffixes | ForEach-Object { $_.Length }) -join ", " } else { "0" }
$prefixRows = ($prefixes | ForEach-Object { "    " + (Quote-CString $_) }) -join ",`r`n"
$suffixRows = ($suffixes | ForEach-Object { "    " + (Quote-CString $_) }) -join ",`r`n"

if (-not $prefixRows) {
    $prefixRows = '    ""'
}

if (-not $suffixRows) {
    $suffixRows = '    ""'
}

$header = @"
#ifndef GPU_GENERATED_CONFIG_H
#define GPU_GENERATED_CONFIG_H

constexpr int GPU_PREFIX_COUNT = $($prefixes.Count);
constexpr int GPU_SUFFIX_COUNT = $($suffixes.Count);

__device__ __constant__ int GPU_PREFIX_LENGTHS[$prefixCount] = { $prefixLengths };
__device__ __constant__ int GPU_SUFFIX_LENGTHS[$suffixCount] = { $suffixLengths };

__device__ __constant__ char GPU_PREFIXES[$prefixCount][16] = {
$prefixRows
};

__device__ __constant__ char GPU_SUFFIXES[$suffixCount][16] = {
$suffixRows
};

#endif
"@

Set-Content -Path $generatedHeader -Value $header -Encoding ascii

& $nvcc `
    "-std=c++14" `
    "-O3" `
    "--gpu-architecture=$computeArch" `
    "--gpu-code=$CudaArch" `
    "-Xcompiler=/EHsc" `
    "-Xcompiler=/MD" `
    (Join-Path $PSScriptRoot "vanity_cuda.cu") `
    "-o" `
    $outputPath

if ($LASTEXITCODE -ne 0) {
    throw "nvcc build failed with exit code $LASTEXITCODE"
}

Write-Host "Built $outputPath"
