param(
    [string]$Word = "",
    [string]$PrefixWord = "",
    [string]$SuffixWord = "",
    [string]$GroupedSpecPath = "",
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
$gpuPrefixLimit = 256
$gpuSuffixLimit = 128
$gpuPatternCharLimit = 31
$explicitGenerationRequest = (-not [string]::IsNullOrWhiteSpace($Word)) -or (-not [string]::IsNullOrWhiteSpace($PrefixWord)) -or (-not [string]::IsNullOrWhiteSpace($SuffixWord)) -or (-not [string]::IsNullOrWhiteSpace($GroupedSpecPath))

if ($MaxVariants -lt 1) {
    throw "MaxVariants must be at least 1."
}

if ([string]::IsNullOrWhiteSpace($GroupedSpecPath) -and [string]::IsNullOrWhiteSpace($Word) -and [string]::IsNullOrWhiteSpace($PrefixWord) -and [string]::IsNullOrWhiteSpace($SuffixWord) -and (-not $Run -or $UpdateConfig)) {
    $Word = "Starforge"
}

if (-not [string]::IsNullOrWhiteSpace($Word) -and (-not [string]::IsNullOrWhiteSpace($PrefixWord) -or -not [string]::IsNullOrWhiteSpace($SuffixWord))) {
    throw "Use either -Word or the split mode flags -PrefixWord / -SuffixWord, not both."
}

if (-not [string]::IsNullOrWhiteSpace($GroupedSpecPath) -and (-not [string]::IsNullOrWhiteSpace($Word) -or -not [string]::IsNullOrWhiteSpace($PrefixWord) -or -not [string]::IsNullOrWhiteSpace($SuffixWord))) {
    throw "Use either -GroupedSpecPath or the single-word flags -Word / -PrefixWord / -SuffixWord, not both."
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and (-not [string]::IsNullOrWhiteSpace($PrefixOutputPath) -or -not [string]::IsNullOrWhiteSpace($SuffixOutputPath))) {
    throw "Use either -OutputPath for single-word mode or -PrefixOutputPath / -SuffixOutputPath for split mode."
}

if (-not [string]::IsNullOrWhiteSpace($GroupedSpecPath) -and (-not [string]::IsNullOrWhiteSpace($OutputPath) -or -not [string]::IsNullOrWhiteSpace($PrefixOutputPath) -or -not [string]::IsNullOrWhiteSpace($SuffixOutputPath))) {
    throw "Grouped generation uses per-rule output paths from the spec or generated defaults. Do not combine -GroupedSpecPath with -OutputPath, -PrefixOutputPath, or -SuffixOutputPath."
}

if ((-not [string]::IsNullOrWhiteSpace($PrefixOutputPath) -or -not [string]::IsNullOrWhiteSpace($SuffixOutputPath)) -and [string]::IsNullOrWhiteSpace($PrefixWord) -and [string]::IsNullOrWhiteSpace($SuffixWord)) {
    throw "Prefix/suffix output paths require -PrefixWord and/or -SuffixWord."
}

if ($Append -and $UpdateConfig) {
    throw "Do not combine -Append with -UpdateConfig. Config updates should point at a fresh, deterministic file."
}

if ($Append -and -not [string]::IsNullOrWhiteSpace($GroupedSpecPath)) {
    throw "Do not combine -Append with -GroupedSpecPath. Grouped generation should write deterministic per-rule files."
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

function Get-PatternFileStats([string]$Path) {
    $fullPath = Resolve-RepoPath $Path
    if (-not (Test-Path $fullPath)) {
        throw "Pattern file not found: $fullPath"
    }

    $entries = @(
        Get-Content $fullPath | Where-Object {
            $trimmed = $_.Trim()
            $trimmed.Length -gt 0 -and -not $trimmed.StartsWith("#")
        } | ForEach-Object { $_.Trim() }
    )

    $maxLength = 0
    foreach ($entry in $entries) {
        if ($entry.Length -gt $maxLength) {
            $maxLength = $entry.Length
        }
    }

    return [PSCustomObject]@{
        FullPath = $fullPath
        RelativePath = Convert-ToRepoRelativePath $fullPath
        Count = $entries.Count
        MaxLength = $maxLength
    }
}

function Write-JsonFile([string]$Path, $Object) {
    $fullPath = Resolve-RepoPath $Path
    $parent = Split-Path -Parent $fullPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($fullPath, $json + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
    return $fullPath
}

function Ensure-ObjectProperty($Object, [string]$Name, $DefaultValue) {
    if ($Object.PSObject.Properties.Match($Name).Count -eq 0) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue
    }
}

function Get-ConfigTemplateObject([string]$ConfigFile) {
    $fullConfigPath = Resolve-RepoPath $ConfigFile
    if (Test-Path $fullConfigPath) {
        return Get-Content $fullConfigPath -Raw | ConvertFrom-Json
    }

    $templatePath = Resolve-RepoPath "vanity.config.json"
    if (-not (Test-Path $templatePath)) {
        throw "Default config template not found: $templatePath"
    }

    return Get-Content $templatePath -Raw | ConvertFrom-Json
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

function Get-LocalEmptyPatternFilePath([string]$Kind) {
    if ($Kind -eq "prefix") {
        return ".local/patterns/prefixes/generated-empty.txt"
    }

    return ".local/patterns/suffixes/generated-empty.txt"
}

function Get-DefaultGroupedVariantFilePath([string]$Kind, [string]$RuleName, [int]$RuleIndex) {
    $slugSource = if ([string]::IsNullOrWhiteSpace($RuleName)) { "rule-$RuleIndex" } else { $RuleName }
    $slug = Get-Slug $slugSource
    $indexText = "{0:d2}" -f $RuleIndex
    if ($Kind -eq "prefix") {
        return ".local/patterns/prefixes/grouped-$indexText-$slug-prefix.txt"
    }

    return ".local/patterns/suffixes/grouped-$indexText-$slug-suffix.txt"
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
    $config = Get-ConfigTemplateObject $ConfigFile
    Ensure-ObjectProperty $config "patterns" ([PSCustomObject]@{})

    $config.patterns.prefix_file = Convert-ToRepoRelativePath $PrefixFile
    $config.patterns.suffix_file = Convert-ToRepoRelativePath $SuffixFile

    Write-JsonFile $ConfigFile $config | Out-Null

    return [PSCustomObject]@{
        ConfigPath = $fullConfigPath
        PrefixFile = $config.patterns.prefix_file
        SuffixFile = $config.patterns.suffix_file
    }
}

function Update-GroupedConfig([string]$ConfigFile, $RuleOutputs, [string]$EngineOverride) {
    $fullConfigPath = Resolve-RepoPath $ConfigFile
    $config = Get-ConfigTemplateObject $ConfigFile

    Ensure-ObjectProperty $config "patterns" ([PSCustomObject]@{})
    Ensure-ObjectProperty $config "output" ([PSCustomObject]@{})
    Ensure-ObjectProperty $config "cpu" ([PSCustomObject]@{})
    Ensure-ObjectProperty $config "gpu" ([PSCustomObject]@{})

    if (-not [string]::IsNullOrWhiteSpace($EngineOverride)) {
        if ($config.PSObject.Properties.Match("engine").Count -eq 0) {
            $config | Add-Member -NotePropertyName "engine" -NotePropertyValue $EngineOverride
        } else {
            $config.engine = $EngineOverride
        }
    }

    $emptyPrefixPath = Ensure-EmptyPatternFile (Get-LocalEmptyPatternFilePath "prefix")
    $emptySuffixPath = Ensure-EmptyPatternFile (Get-LocalEmptyPatternFilePath "suffix")

    $config.patterns.prefix_file = Convert-ToRepoRelativePath $emptyPrefixPath
    $config.patterns.suffix_file = Convert-ToRepoRelativePath $emptySuffixPath

    $ruleEntries = @(
        foreach ($rule in $RuleOutputs) {
            [PSCustomObject]@{
                prefix_file = Convert-ToRepoRelativePath $rule.PrefixFile
                suffix_file = Convert-ToRepoRelativePath $rule.SuffixFile
            }
        }
    )

    if ($config.PSObject.Properties.Match("rules").Count -eq 0) {
        $config | Add-Member -NotePropertyName "rules" -NotePropertyValue $ruleEntries
    } else {
        $config.rules = $ruleEntries
    }

    Write-JsonFile $ConfigFile $config | Out-Null

    return [PSCustomObject]@{
        ConfigPath = $fullConfigPath
        Engine = $config.engine
        RuleCount = $ruleEntries.Count
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

    if ($Result.Length -gt $gpuPatternCharLimit) {
        Write-Host "GPU length    : exceeds the GPU pattern length limit of $gpuPatternCharLimit characters"
    }

    if ($CheckPrefixLimit -and $Result.VariantCount -gt $gpuPrefixLimit) {
        Write-Host "GPU prefixes  : exceeds the GPU prefix limit of $gpuPrefixLimit entries"
    }

    if ($CheckSuffixLimit -and $Result.VariantCount -gt $gpuSuffixLimit) {
        Write-Host "GPU suffixes  : exceeds the GPU suffix limit of $gpuSuffixLimit entries"
    }

    if (-not $Quiet) {
        Write-Host ""
        foreach ($variant in $Result.Variants) {
            Write-Host $variant
        }
    }
}

function Show-GroupedVariantSet($RuleOutputs, $ConfigUpdate) {
    $totalCombinations = 0L
    $flattenedPrefixCount = 0
    $flattenedSuffixCount = 0
    $maxPrefixLength = 0
    $maxSuffixLength = 0

    Write-Host "Grouped rules : $($RuleOutputs.Count)"

    foreach ($rule in $RuleOutputs) {
        $totalCombinations += $rule.CombinationCount
        $flattenedPrefixCount += $rule.FlattenedPrefixCount
        $flattenedSuffixCount += $rule.FlattenedSuffixCount
        if ($rule.MaxPrefixLength -gt $maxPrefixLength) {
            $maxPrefixLength = $rule.MaxPrefixLength
        }
        if ($rule.MaxSuffixLength -gt $maxSuffixLength) {
            $maxSuffixLength = $rule.MaxSuffixLength
        }

        Write-Host ""
        Write-Host "[$($rule.Name)]"
        Write-Host "Prefix source : $($rule.PrefixSourceType)"
        Write-Host "Prefix value  : $($rule.PrefixSourceLabel)"
        Write-Host "Suffix source : $($rule.SuffixSourceType)"
        Write-Host "Suffix value  : $($rule.SuffixSourceLabel)"
        Write-Host "Prefix count  : $($rule.PrefixCount)"
        Write-Host "Suffix count  : $($rule.SuffixCount)"
        Write-Host "Combinations  : $($rule.CombinationCount)"
        Write-Host "Prefix file   : $($rule.PrefixFile)"
        Write-Host "Suffix file   : $($rule.SuffixFile)"
    }

    Write-Host ""
    Write-Host "Total combos  : $totalCombinations"
    Write-Host "Flat prefixes : $flattenedPrefixCount"
    Write-Host "Flat suffixes : $flattenedSuffixCount"

    if ($maxPrefixLength -gt $gpuPatternCharLimit -or $maxSuffixLength -gt $gpuPatternCharLimit) {
        Write-Host "GPU length    : exceeds the GPU pattern length limit of $gpuPatternCharLimit characters"
    }

    if ($flattenedPrefixCount -gt $gpuPrefixLimit) {
        Write-Host "GPU prefixes  : exceeds the GPU prefix limit of $gpuPrefixLimit entries"
    }

    if ($flattenedSuffixCount -gt $gpuSuffixLimit) {
        Write-Host "GPU suffixes  : exceeds the GPU suffix limit of $gpuSuffixLimit entries"
    }

    if ($ConfigUpdate) {
        Write-Host ""
        Write-Host "Config file   : $($ConfigUpdate.ConfigPath)"
        Write-Host "Engine        : $($ConfigUpdate.Engine)"
        Write-Host "Rule count    : $($ConfigUpdate.RuleCount)"
    }
}

function Get-GroupedSpecRuleName($Rule, [int]$RuleIndex) {
    if ($Rule.PSObject.Properties.Match("name").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Rule.name)) {
        return [string]$Rule.name
    }

    $parts = @()
    if ($Rule.PSObject.Properties.Match("prefix_word").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Rule.prefix_word)) {
        $parts += [string]$Rule.prefix_word
    }
    if ($Rule.PSObject.Properties.Match("suffix_word").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Rule.suffix_word)) {
        $parts += [string]$Rule.suffix_word
    }
    if ($Rule.PSObject.Properties.Match("prefix_file").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Rule.prefix_file)) {
        $parts += [System.IO.Path]::GetFileNameWithoutExtension([string]$Rule.prefix_file)
    }
    if ($Rule.PSObject.Properties.Match("suffix_file").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Rule.suffix_file)) {
        $parts += [System.IO.Path]::GetFileNameWithoutExtension([string]$Rule.suffix_file)
    }
    if ($parts.Count -gt 0) {
        return ($parts -join "-")
    }

    return "rule-$RuleIndex"
}

if (-not [string]::IsNullOrWhiteSpace($GroupedSpecPath)) {
    $fullGroupedSpecPath = Resolve-RepoPath $GroupedSpecPath
    if (-not (Test-Path $fullGroupedSpecPath)) {
        throw "Grouped spec file not found: $fullGroupedSpecPath"
    }

    $groupedSpec = Get-Content $fullGroupedSpecPath -Raw | ConvertFrom-Json
    $rules = @($groupedSpec.rules)
    if ($rules.Count -eq 0) {
        throw "Grouped spec must contain a non-empty rules array."
    }

    $ruleOutputs = New-Object System.Collections.Generic.List[object]
    $ruleIndex = 0

    foreach ($rule in $rules) {
        $ruleIndex += 1
        $ruleName = Get-GroupedSpecRuleName $rule $ruleIndex
        $prefixWordValue = ""
        $suffixWordValue = ""
        $prefixFileValue = ""
        $suffixFileValue = ""
        if ($rule.PSObject.Properties.Match("prefix_word").Count -gt 0) {
            $prefixWordValue = [string]$rule.prefix_word
        }
        if ($rule.PSObject.Properties.Match("suffix_word").Count -gt 0) {
            $suffixWordValue = [string]$rule.suffix_word
        }
        if ($rule.PSObject.Properties.Match("prefix_file").Count -gt 0) {
            $prefixFileValue = [string]$rule.prefix_file
        }
        if ($rule.PSObject.Properties.Match("suffix_file").Count -gt 0) {
            $suffixFileValue = [string]$rule.suffix_file
        }

        if (-not [string]::IsNullOrWhiteSpace($prefixWordValue) -and -not [string]::IsNullOrWhiteSpace($prefixFileValue)) {
            throw "Grouped spec rule $ruleIndex cannot provide both prefix_word and prefix_file."
        }
        if (-not [string]::IsNullOrWhiteSpace($suffixWordValue) -and -not [string]::IsNullOrWhiteSpace($suffixFileValue)) {
            throw "Grouped spec rule $ruleIndex cannot provide both suffix_word and suffix_file."
        }
        if ([string]::IsNullOrWhiteSpace($prefixWordValue) -and [string]::IsNullOrWhiteSpace($prefixFileValue) -and [string]::IsNullOrWhiteSpace($suffixWordValue) -and [string]::IsNullOrWhiteSpace($suffixFileValue)) {
            throw "Grouped spec rule $ruleIndex must provide at least one of prefix_word, prefix_file, suffix_word, or suffix_file."
        }

        $prefixResult = $null
        $suffixResult = $null
        $prefixFileStats = $null
        $suffixFileStats = $null
        if (-not [string]::IsNullOrWhiteSpace($prefixWordValue)) {
            $prefixResult = Get-VariantsForWord $prefixWordValue
        } elseif (-not [string]::IsNullOrWhiteSpace($prefixFileValue)) {
            $prefixFileStats = Get-PatternFileStats $prefixFileValue
        }
        if (-not [string]::IsNullOrWhiteSpace($suffixWordValue)) {
            $suffixResult = Get-VariantsForWord $suffixWordValue
        } elseif (-not [string]::IsNullOrWhiteSpace($suffixFileValue)) {
            $suffixFileStats = Get-PatternFileStats $suffixFileValue
        }

        $prefixOutputTarget = ""
        $suffixOutputTarget = ""
        if ($prefixResult -and $rule.PSObject.Properties.Match("prefix_output_path").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$rule.prefix_output_path)) {
            $prefixOutputTarget = [string]$rule.prefix_output_path
        } elseif ($prefixResult) {
            $prefixOutputTarget = Get-DefaultGroupedVariantFilePath "prefix" $ruleName $ruleIndex
        } else {
            $prefixOutputTarget = Get-LocalEmptyPatternFilePath "prefix"
        }

        if ($suffixResult -and $rule.PSObject.Properties.Match("suffix_output_path").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$rule.suffix_output_path)) {
            $suffixOutputTarget = [string]$rule.suffix_output_path
        } elseif ($suffixResult) {
            $suffixOutputTarget = Get-DefaultGroupedVariantFilePath "suffix" $ruleName $ruleIndex
        } else {
            $suffixOutputTarget = Get-LocalEmptyPatternFilePath "suffix"
        }

        $resolvedPrefixPath = if ($prefixResult) { Write-VariantFile $prefixOutputTarget $prefixResult.Variants } elseif ($prefixFileStats) { $prefixFileStats.FullPath } else { Ensure-EmptyPatternFile $prefixOutputTarget }
        $resolvedSuffixPath = if ($suffixResult) { Write-VariantFile $suffixOutputTarget $suffixResult.Variants } elseif ($suffixFileStats) { $suffixFileStats.FullPath } else { Ensure-EmptyPatternFile $suffixOutputTarget }

        $prefixCount = if ($prefixResult) { $prefixResult.VariantCount } elseif ($prefixFileStats) { $prefixFileStats.Count } else { 0 }
        $suffixCount = if ($suffixResult) { $suffixResult.VariantCount } elseif ($suffixFileStats) { $suffixFileStats.Count } else { 0 }
        $combinationCount = [Math]::Max(1, $prefixCount) * [Math]::Max(1, $suffixCount)
        $flattenedPrefixCount = if ($prefixCount -gt 0) { $prefixCount } else { 1 }
        $flattenedSuffixCount = if ($suffixCount -gt 0) { $suffixCount } else { 1 }
        $maxPrefixLength = if ($prefixResult) { $prefixResult.Length } elseif ($prefixFileStats) { $prefixFileStats.MaxLength } else { 0 }
        $maxSuffixLength = if ($suffixResult) { $suffixResult.Length } elseif ($suffixFileStats) { $suffixFileStats.MaxLength } else { 0 }
        $prefixSourceLabel = if ($prefixWordValue) { $prefixWordValue } elseif ($prefixFileValue) { Convert-ToRepoRelativePath $prefixFileValue } else { "<wildcard>" }
        $suffixSourceLabel = if ($suffixWordValue) { $suffixWordValue } elseif ($suffixFileValue) { Convert-ToRepoRelativePath $suffixFileValue } else { "<wildcard>" }
        $prefixSourceType = if ($prefixWordValue) { "word" } elseif ($prefixFileValue) { "file" } else { "wildcard" }
        $suffixSourceType = if ($suffixWordValue) { "word" } elseif ($suffixFileValue) { "file" } else { "wildcard" }

        [void]$ruleOutputs.Add([PSCustomObject]@{
            Name = $ruleName
            PrefixWord = $prefixWordValue
            SuffixWord = $suffixWordValue
            PrefixFile = $resolvedPrefixPath
            SuffixFile = $resolvedSuffixPath
            PrefixCount = $prefixCount
            SuffixCount = $suffixCount
            CombinationCount = $combinationCount
            FlattenedPrefixCount = $flattenedPrefixCount
            FlattenedSuffixCount = $flattenedSuffixCount
            MaxPrefixLength = $maxPrefixLength
            MaxSuffixLength = $maxSuffixLength
            PrefixSourceType = $prefixSourceType
            SuffixSourceType = $suffixSourceType
            PrefixSourceLabel = $prefixSourceLabel
            SuffixSourceLabel = $suffixSourceLabel
        })
    }

    $configUpdate = $null
    $engineOverride = ""
    if ($groupedSpec.PSObject.Properties.Match("engine").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$groupedSpec.engine)) {
        $engineOverride = [string]$groupedSpec.engine
    }

    if ($UpdateConfig) {
        $configUpdate = Update-GroupedConfig $ConfigPath $ruleOutputs $engineOverride
    }

    Show-GroupedVariantSet $ruleOutputs $configUpdate

    if ($Run) {
        Invoke-ConfiguredRun $ConfigPath
    }

    return
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
