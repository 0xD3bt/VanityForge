param(
    [string]$ConfigPath = "",
    [string]$CudaPath = $env:CUDA_PATH,
    [string]$PrefixFile = "patterns\prefixes\example.txt",
    [string]$SuffixFile = "patterns\suffixes\example.txt",
    [string]$CudaArch = "sm_89",
    [string]$Output = "gpu\bin\solana-vanity-gpu.exe"
)

$ErrorActionPreference = "Stop"
$maxGpuPrefixes = 256
$maxGpuSuffixes = 128
$maxGpuPatternChars = 31
$gpuPatternSlotWidth = $maxGpuPatternChars + 1

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
$outputPath = Join-Path $root $Output
$outputDir = Split-Path -Parent $outputPath
$generatedHeader = Join-Path $PSScriptRoot "generated_config.h"

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

function Resolve-RepoPath([string]$PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ""
    }
    if ([System.IO.Path]::IsPathRooted($PathText)) {
        return [System.IO.Path]::GetFullPath($PathText)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $root $PathText))
}

function Get-PatternList([string]$PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return @()
    }

    $path = Resolve-RepoPath $PathText
    if (-not (Test-Path $path)) {
        throw "Pattern file not found: $path"
    }

    Get-Content $path | Where-Object {
        $trimmed = $_.Trim()
        $trimmed.Length -gt 0 -and -not $trimmed.StartsWith("#")
    } | ForEach-Object { $_.Trim() }
}

function Quote-CString([string]$s) {
    '"' + ($s.Replace('\', '\\').Replace('"', '\"')) + '"'
}

$prefixes = [System.Collections.Generic.List[string]]::new()
$suffixes = [System.Collections.Generic.List[string]]::new()
$prefixGroups = [System.Collections.Generic.List[int]]::new()
$suffixGroups = [System.Collections.Generic.List[int]]::new()

function Add-RuleEntries([int]$RuleGroup, [string]$RulePrefixFile, [string]$RuleSuffixFile) {
    $rulePrefixes = @((Get-PatternList $RulePrefixFile))
    $ruleSuffixes = @((Get-PatternList $RuleSuffixFile))

    if ($rulePrefixes.Count -eq 0 -and $ruleSuffixes.Count -eq 0) {
        throw "Each grouped GPU rule must provide at least one non-empty prefix or suffix file."
    }

    if ($rulePrefixes.Count -eq 0) {
        $rulePrefixes = @("")
    }
    if ($ruleSuffixes.Count -eq 0) {
        $ruleSuffixes = @("")
    }

    foreach ($prefix in $rulePrefixes) {
        [void]$script:prefixes.Add($prefix)
        [void]$script:prefixGroups.Add($RuleGroup)
    }
    foreach ($suffix in $ruleSuffixes) {
        [void]$script:suffixes.Add($suffix)
        [void]$script:suffixGroups.Add($RuleGroup)
    }
}

if ($ConfigPath) {
    $configFile = Resolve-RepoPath $ConfigPath
    if (-not (Test-Path $configFile)) {
        throw "Config file not found: $configFile"
    }

    $config = Get-Content $configFile -Raw | ConvertFrom-Json
    if ($config.gpu.cuda_arch) {
        $CudaArch = [string]$config.gpu.cuda_arch
    }

    if ($null -ne $config.rules -and @($config.rules).Count -gt 0) {
        $groupIndex = 0
        foreach ($rule in @($config.rules)) {
            Add-RuleEntries $groupIndex $rule.prefix_file $rule.suffix_file
            $groupIndex += 1
        }
    } else {
        Add-RuleEntries 0 $config.patterns.prefix_file $config.patterns.suffix_file
    }
} else {
    Add-RuleEntries 0 $PrefixFile $SuffixFile
}

if ($prefixes.Count -gt $maxGpuPrefixes) {
    throw "Too many prefixes for generated CUDA config (max $maxGpuPrefixes)"
}

if ($suffixes.Count -gt $maxGpuSuffixes) {
    throw "Too many suffixes for generated CUDA config (max $maxGpuSuffixes)"
}

if (($prefixes | Where-Object { $_.Length -gt $maxGpuPatternChars } | Select-Object -First 1) -or ($suffixes | Where-Object { $_.Length -gt $maxGpuPatternChars } | Select-Object -First 1)) {
    throw "GPU pattern entries must be $maxGpuPatternChars characters or fewer."
}

$computeArch = $CudaArch -replace "^sm_", "compute_"
$prefixCount = [Math]::Max(1, $prefixes.Count)
$suffixCount = [Math]::Max(1, $suffixes.Count)
$prefixLengths = if ($prefixes.Count -gt 0) { ($prefixes | ForEach-Object { $_.Length }) -join ", " } else { "0" }
$suffixLengths = if ($suffixes.Count -gt 0) { ($suffixes | ForEach-Object { $_.Length }) -join ", " } else { "0" }
$prefixGroupValues = if ($prefixGroups.Count -gt 0) { ($prefixGroups | ForEach-Object { [string]$_ }) -join ", " } else { "0" }
$suffixGroupValues = if ($suffixGroups.Count -gt 0) { ($suffixGroups | ForEach-Object { [string]$_ }) -join ", " } else { "0" }
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
__device__ __constant__ int GPU_PREFIX_GROUPS[$prefixCount] = { $prefixGroupValues };
__device__ __constant__ int GPU_SUFFIX_GROUPS[$suffixCount] = { $suffixGroupValues };

__device__ __constant__ char GPU_PREFIXES[$prefixCount][$gpuPatternSlotWidth] = {
$prefixRows
};

__device__ __constant__ char GPU_SUFFIXES[$suffixCount][$gpuPatternSlotWidth] = {
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
