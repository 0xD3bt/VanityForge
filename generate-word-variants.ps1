param(
    [string]$Word = "",
    [string]$PrefixWord = "",
    [string]$SuffixWord = "",
    [string]$OutputPath = "",
    [string]$PrefixOutputPath = "",
    [string]$SuffixOutputPath = "",
    [string]$ConfigPath = "vanity.config.json",
    [switch]$UpdateConfig,
    [switch]$Quiet,
    [switch]$Run,
    [switch]$Append,
    [int]$MaxVariants = 100000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSCommandPath
$explicitGenerationRequest = (-not [string]::IsNullOrWhiteSpace($Word)) -or (-not [string]::IsNullOrWhiteSpace($PrefixWord)) -or (-not [string]::IsNullOrWhiteSpace($SuffixWord))

if ($MaxVariants -lt 1) {
    throw "MaxVariants must be at least 1."
}

if ([string]::IsNullOrWhiteSpace($Word) -and [string]::IsNullOrWhiteSpace($PrefixWord) -and [string]::IsNullOrWhiteSpace($SuffixWord) -and (-not $Run -or $UpdateConfig)) {
    $Word = "Starforge"
}

if (-not [string]::IsNullOrWhiteSpace($Word) -and (-not [string]::IsNullOrWhiteSpace($PrefixWord) -or -not [string]::IsNullOrWhiteSpace($SuffixWord))) {
    throw "Use either -Word or the split mode flags -PrefixWord / -SuffixWord, not both."
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and (-not [string]::IsNullOrWhiteSpace($PrefixOutputPath) -or -not [string]::IsNullOrWhiteSpace($SuffixOutputPath))) {
    throw "Use either -OutputPath for single-word mode or -PrefixOutputPath / -SuffixOutputPath for split mode."
}

if ((-not [string]::IsNullOrWhiteSpace($PrefixOutputPath) -or -not [string]::IsNullOrWhiteSpace($SuffixOutputPath)) -and [string]::IsNullOrWhiteSpace($PrefixWord) -and [string]::IsNullOrWhiteSpace($SuffixWord)) {
    throw "Prefix/suffix output paths require -PrefixWord and/or -SuffixWord."
}

if ($Append -and $UpdateConfig) {
    throw "Do not combine -Append with -UpdateConfig. Config updates should point at a fresh, deterministic file."
}

if ($Run -and $explicitGenerationRequest -and -not $UpdateConfig) {
    throw "Use -UpdateConfig with -Run when generating new pattern files, otherwise the search would still use the existing config."
}

$base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
$base58Set = [System.Collections.Generic.HashSet[char]]::new()
foreach ($char in $base58Alphabet.ToCharArray()) {
    [void]$base58Set.Add($char)
}

function Test-Base58Char([char]$Char) {
    return $base58Set.Contains($Char)
}

function Get-VariantChars([char]$Char) {
    $options = [System.Collections.Generic.List[string]]::new()

    if ([char]::IsLetter($Char)) {
        foreach ($candidate in @(
            $Char,
            [char]::ToUpperInvariant($Char),
            [char]::ToLowerInvariant($Char)
        )) {
            $asString = [string]$candidate
            if ((Test-Base58Char $candidate) -and -not $options.Contains($asString)) {
                [void]$options.Add($asString)
            }
        }
    } elseif (Test-Base58Char $Char) {
        [void]$options.Add([string]$Char)
    }

    if ($options.Count -eq 0) {
        throw "Character '$Char' cannot appear in a Solana Base58 vanity pattern."
    }

    return $options
}

function Get-VariantsForWord([string]$InputWord) {
    if ([string]::IsNullOrWhiteSpace($InputWord)) {
        throw "Word must not be empty."
    }

    $variantOptions = [System.Collections.Generic.List[object]]::new()
    $variantCount = 1L

    foreach ($char in $InputWord.ToCharArray()) {
        $options = Get-VariantChars $char
        [void]$variantOptions.Add($options)

        if ($variantCount -le $MaxVariants) {
            $variantCount *= $options.Count
        }

        if ($variantCount -gt $MaxVariants) {
            throw "The word '$InputWord' expands to more than $MaxVariants variants. Increase -MaxVariants or use a shorter word."
        }
    }

    $variants = [System.Collections.Generic.List[string]]::new()

    function Add-Variants([int]$Index, [string]$Current) {
        if ($Index -ge $variantOptions.Count) {
            [void]$variants.Add($Current)
            return
        }

        foreach ($choice in $variantOptions[$Index]) {
            Add-Variants ($Index + 1) ($Current + $choice)
        }
    }

    Add-Variants 0 ""

    $singleCaseLetters = 0
    foreach ($options in $variantOptions) {
        if ($options.Count -eq 1) {
            $singleCaseLetters += 1
        }
    }

    return [PSCustomObject]@{
        Word = $InputWord
        Variants = $variants
        VariantCount = $variants.Count
        SingleCaseLetters = $singleCaseLetters
        Length = $InputWord.Length
    }
}

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Convert-ToRepoRelativePath([string]$Path) {
    $fullPath = Resolve-RepoPath $Path
    $repoUri = [System.Uri]((Resolve-RepoPath ".").TrimEnd('\') + '\')
    $fileUri = [System.Uri]$fullPath
    $relativeUri = $repoUri.MakeRelativeUri($fileUri)
    return ([System.Uri]::UnescapeDataString($relativeUri.ToString())).Replace('\', '/')
}

function Get-Slug([string]$InputWord) {
    $slugChars = foreach ($char in $InputWord.ToCharArray()) {
        if ([char]::IsLetterOrDigit($char)) {
            [char]::ToLowerInvariant($char)
        } else {
            '-'
        }
    }

    $slug = (-join $slugChars) -replace '-+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "custom"
    }

    return $slug
}

function Get-DefaultVariantFilePath([string]$Kind, [string]$InputWord) {
    $slug = Get-Slug $InputWord
    if ($Kind -eq "prefix") {
        return "patterns/prefixes/$slug.txt"
    }

    return "patterns/suffixes/$slug.txt"
}

function Get-EmptyPatternFilePath([string]$Kind) {
    if ($Kind -eq "prefix") {
        return "patterns/prefixes/generated-empty.txt"
    }

    return "patterns/suffixes/generated-empty.txt"
}

function Write-TextFile([string]$Path, [string[]]$Lines, [bool]$UseAppend) {
    $fullOutputPath = Resolve-RepoPath $Path
    $parent = Split-Path -Parent $fullOutputPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $mode = if ($UseAppend) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
    $stream = [System.IO.File]::Open($fullOutputPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::ASCII)
        try {
            foreach ($line in $Lines) {
                $writer.WriteLine($line)
            }
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    return $fullOutputPath
}

function Write-VariantFile([string]$Path, [System.Collections.Generic.List[string]]$Variants) {
    return Write-TextFile $Path $Variants $Append
}

function Ensure-EmptyPatternFile([string]$Path) {
    return Write-TextFile $Path @("# Intentionally empty. This side of the vanity search is disabled.") $false
}

function Update-ConfigPatternPaths([string]$ConfigFile, [string]$PrefixFile, [string]$SuffixFile) {
    $fullConfigPath = Resolve-RepoPath $ConfigFile
    if (-not (Test-Path $fullConfigPath)) {
        throw "Config file not found: $fullConfigPath"
    }

    $config = Get-Content $fullConfigPath -Raw | ConvertFrom-Json
    if ($null -eq $config.patterns) {
        throw "Config file does not contain a patterns object."
    }

    $config.patterns.prefix_file = Convert-ToRepoRelativePath $PrefixFile
    $config.patterns.suffix_file = Convert-ToRepoRelativePath $SuffixFile

    $json = $config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($fullConfigPath, $json + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

    return [PSCustomObject]@{
        ConfigPath = $fullConfigPath
        PrefixFile = $config.patterns.prefix_file
        SuffixFile = $config.patterns.suffix_file
    }
}

function Normalize-ConfigPathForRun([string]$ConfigFile) {
    if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
        return Convert-ToRepoRelativePath $ConfigFile
    }

    return $ConfigFile
}

function Assert-SafeRunConfig([string]$ConfigFile) {
    $fullConfigPath = Resolve-RepoPath $ConfigFile
    if (-not (Test-Path $fullConfigPath)) {
        throw "Config file not found: $fullConfigPath"
    }

    $config = Get-Content $fullConfigPath -Raw | ConvertFrom-Json
    switch ($config.engine) {
        "cpu" {
            if ($config.cpu.max_attempts -le 0) {
                throw "Refusing -Run with CPU config because cpu.max_attempts is 0. Set a small nonzero limit for a bounded smoke test, or run .\\run.ps1 manually for a full search."
            }
        }
        "gpu" {
            if ($config.gpu.max_iterations -le 0) {
                throw "Refusing -Run with GPU config because gpu.max_iterations is 0. Set a small nonzero limit for a bounded smoke test, or run .\\run.ps1 manually for a full search."
            }
        }
        default {
            throw "Unknown engine in config: $($config.engine). Use 'cpu' or 'gpu'."
        }
    }
}

function Invoke-ConfiguredRun([string]$ConfigFile) {
    $runConfigPath = Normalize-ConfigPathForRun $ConfigFile
    Assert-SafeRunConfig $runConfigPath
    Write-Host ""
    Write-Host "Starting bounded search with config: $runConfigPath"
    & (Join-Path $repoRoot "run.ps1") -ConfigPath $runConfigPath
}

function Show-VariantSet([string]$Label, $Result, [string]$ResolvedOutputPath, [bool]$CheckPrefixLimit, [bool]$CheckSuffixLimit) {
    if ($Label) {
        Write-Host "[$Label]"
    }

    Write-Host "Input word    : $($Result.Word)"
    Write-Host "Variant count : $($Result.VariantCount)"
    Write-Host "Single-case   : $($Result.SingleCaseLetters) characters"

    if ($ResolvedOutputPath) {
        Write-Host "Output file   : $ResolvedOutputPath"
    }

    if ($Result.Length -gt 15) {
        Write-Host "GPU length    : exceeds the GPU pattern length limit of 15 characters"
    }

    if ($CheckPrefixLimit -and $Result.VariantCount -gt 128) {
        Write-Host "GPU prefixes  : exceeds the GPU prefix limit of 128 entries"
    }

    if ($CheckSuffixLimit -and $Result.VariantCount -gt 32) {
        Write-Host "GPU suffixes  : exceeds the GPU suffix limit of 32 entries"
    }

    if (-not $Quiet) {
        Write-Host ""
        foreach ($variant in $Result.Variants) {
            Write-Host $variant
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Word)) {
    $result = Get-VariantsForWord $Word
    $resolvedOutputPath = ""
    $configUpdate = $null

    if ($OutputPath -or $UpdateConfig) {
        $targetOutputPath = if ($OutputPath) { $OutputPath } else { Get-DefaultVariantFilePath "prefix" $Word }
        $resolvedOutputPath = Write-VariantFile $targetOutputPath $result.Variants
    }

    if ($UpdateConfig) {
        $emptySuffixPath = Get-EmptyPatternFilePath "suffix"
        $resolvedEmptySuffixPath = Ensure-EmptyPatternFile $emptySuffixPath
        $configUpdate = Update-ConfigPatternPaths $ConfigPath $resolvedOutputPath $resolvedEmptySuffixPath
    }

    Show-VariantSet "" $result $resolvedOutputPath $true $true
    if ($configUpdate) {
        Write-Host ""
        Write-Host "Config file   : $($configUpdate.ConfigPath)"
        Write-Host "prefix_file   : $($configUpdate.PrefixFile)"
        Write-Host "suffix_file   : $($configUpdate.SuffixFile)"
    }

    if ($Run) {
        $configToRun = if ($UpdateConfig) { $ConfigPath } else { $ConfigPath }
        Invoke-ConfiguredRun $configToRun
    }

    return
}

$printedSection = $false
$resolvedPrefixOutputPath = ""
$resolvedSuffixOutputPath = ""
$prefixResult = $null
$suffixResult = $null

if (-not [string]::IsNullOrWhiteSpace($PrefixWord)) {
    $prefixResult = Get-VariantsForWord $PrefixWord

    if ($PrefixOutputPath -or $UpdateConfig) {
        $targetPrefixOutputPath = if ($PrefixOutputPath) { $PrefixOutputPath } else { Get-DefaultVariantFilePath "prefix" $PrefixWord }
        $resolvedPrefixOutputPath = Write-VariantFile $targetPrefixOutputPath $prefixResult.Variants
    }

    Show-VariantSet "Prefix variants" $prefixResult $resolvedPrefixOutputPath $true $false
    $printedSection = $true
}

if (-not [string]::IsNullOrWhiteSpace($SuffixWord)) {
    if ($printedSection) {
        Write-Host ""
    }

    $suffixResult = Get-VariantsForWord $SuffixWord

    if ($SuffixOutputPath -or $UpdateConfig) {
        $targetSuffixOutputPath = if ($SuffixOutputPath) { $SuffixOutputPath } else { Get-DefaultVariantFilePath "suffix" $SuffixWord }
        $resolvedSuffixOutputPath = Write-VariantFile $targetSuffixOutputPath $suffixResult.Variants
    }

    Show-VariantSet "Suffix variants" $suffixResult $resolvedSuffixOutputPath $false $true
}

if ($UpdateConfig) {
    if (-not $resolvedPrefixOutputPath) {
        $resolvedPrefixOutputPath = Ensure-EmptyPatternFile (Get-EmptyPatternFilePath "prefix")
    }

    if (-not $resolvedSuffixOutputPath) {
        $resolvedSuffixOutputPath = Ensure-EmptyPatternFile (Get-EmptyPatternFilePath "suffix")
    }

    $configUpdate = Update-ConfigPatternPaths $ConfigPath $resolvedPrefixOutputPath $resolvedSuffixOutputPath
    Write-Host ""
    Write-Host "Config file   : $($configUpdate.ConfigPath)"
    Write-Host "prefix_file   : $($configUpdate.PrefixFile)"
    Write-Host "suffix_file   : $($configUpdate.SuffixFile)"
}

if ($Run) {
    Invoke-ConfiguredRun $ConfigPath
}
