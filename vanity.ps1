param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Arg1 = "",

    [Parameter(Position = 2)]
    [string]$Arg2 = "",

    [string]$ConfigPath = "vanity.config.json",
    [string]$Word = "",
    [string]$PrefixWord = "",
    [string]$SuffixWord = "",
    [string]$GroupedSpecPath = "",
    [string]$OutputPath = "",
    [string]$PrefixOutputPath = "",
    [string]$SuffixOutputPath = "",
    [string]$Engine = "",
    [switch]$Quiet,
    [switch]$Run,
    [switch]$UpdateConfig,
    [switch]$Append,
    [int]$MaxVariants = 100000,
    [int]$SmokeCpuAttempts = 100000,
    [int]$SmokeGpuIterations = 1
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSCommandPath
$gpuPrefixLimit = 256
$gpuSuffixLimit = 128
$gpuPatternCharLimit = 31
$defaultConfigTemplate = Join-Path $repoRoot "vanity.config.json"
$gpuBuildToolCandidates = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2026\BuildTools\Common7\Tools\Launch-VsDevShell.ps1",
    "C:\Program Files\Microsoft Visual Studio\2026\Community\Common7\Tools\Launch-VsDevShell.ps1"
)
$commonCudaRoots = @(
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.6",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.5",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.4",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.3",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.2",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.1",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.0",
    "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v11.8"
)
$commonNvidiaSmiPaths = @(
    "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
)
$base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  vanity doctor"
    Write-Host "  vanity show [-ConfigPath path]"
    Write-Host "  vanity init [-ConfigPath path]"
    Write-Host "  vanity smoke [-ConfigPath path] [-Engine cpu|gpu]"
    Write-Host "  vanity setup <prefixWord> <suffixWord>"
    Write-Host "  vanity word <fullWord>"
    Write-Host "  vanity generate [options]"
    Write-Host "  vanity generate -GroupedSpecPath <path> -ConfigPath <path> -UpdateConfig"
    Write-Host "  vanity run [-Engine cpu|gpu]"
    Write-Host "  vanity build [-Engine cpu|gpu|all]"
    Write-Host "  vanity stop"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  doctor    Check GPU, CUDA, build tools, and recommend CPU or GPU."
    Write-Host "  show      Show the active config, pattern files, and example entries."
    Write-Host "  init      Interactive setup wizard for config, words, and safe first runs."
    Write-Host "  smoke     Run a bounded smoke test using a temporary config."
    Write-Host "  setup     Quick split-word setup: prefix word + suffix word."
    Write-Host "  word      Quick single-word setup: one full target word."
    Write-Host "  generate  Advanced variant generation and config update helper."
    Write-Host "  run       Start the configured search."
    Write-Host "  build     Build the configured engine."
    Write-Host "  stop      Stop project search processes."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  vanity doctor"
    Write-Host "  vanity show"
    Write-Host "  vanity init"
    Write-Host "  vanity smoke"
    Write-Host "  vanity setup Star forge    # prefix=Star, suffix=forge"
    Write-Host "  vanity word Starforge      # one full word"
    Write-Host "  vanity generate -GroupedSpecPath .local\configs\grouped-variant-smoke-spec.json -ConfigPath .local\configs\grouped-variant-smoke.config.json -UpdateConfig"
    Write-Host "  vanity run"
    Write-Host "  vanity stop"
    Write-Host ""
    Write-Host "Install once for global commands:"
    Write-Host "  .\install.ps1"
    Write-Host ""
    Write-Host "Repo-local fallback:"
    Write-Host "  .\vanity.ps1 help"
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

function Read-ConfigObject([string]$TargetConfigPath) {
    $fullConfigPath = Resolve-RepoPath $TargetConfigPath
    if (-not (Test-Path $fullConfigPath)) {
        throw "Config file not found: $fullConfigPath"
    }

    return Get-Content $fullConfigPath -Raw | ConvertFrom-Json
}

function Write-ConfigObject([string]$TargetConfigPath, $ConfigObject) {
    $fullConfigPath = Resolve-RepoPath $TargetConfigPath
    $parent = Split-Path -Parent $fullConfigPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $json = $ConfigObject | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($fullConfigPath, $json + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
}

function Get-ConfigStringArray($Value) {
    if ($null -eq $Value) {
        return @()
    }

    return @(
        @($Value) |
        ForEach-Object { "$_".Trim() } |
        Where-Object { $_ }
    )
}

function Get-PatternFileReport([string]$PathValue, [int]$PreviewCount = 5) {
    $pathText = if ([string]::IsNullOrWhiteSpace($PathValue)) { "<none>" } else { $PathValue }
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return [pscustomobject]@{
            Path = $pathText
            Exists = $false
            TotalCount = 0
            Preview = @()
        }
    }

    $fullPath = Resolve-RepoPath $PathValue
    if (-not (Test-Path $fullPath)) {
        return [pscustomobject]@{
            Path = $PathValue
            Exists = $false
            TotalCount = 0
            Preview = @()
        }
    }

    $entries = @(
        Get-Content $fullPath |
        ForEach-Object { "$_".Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") }
    )

    return [pscustomobject]@{
        Path = $PathValue
        Exists = $true
        TotalCount = $entries.Count
        Preview = @($entries | Select-Object -First $PreviewCount)
    }
}

function Get-ConfiguredPatternMode($PrefixCount, $SuffixCount) {
    if ($PrefixCount -gt 0 -and $SuffixCount -gt 0) {
        return "split prefix/suffix"
    }

    if ($PrefixCount -gt 0 -and $SuffixCount -eq 0) {
        return "single-word or prefix-only"
    }

    if ($PrefixCount -eq 0 -and $SuffixCount -gt 0) {
        return "suffix-only"
    }

    return "empty"
}

function Format-ValueList($Values) {
    $items = Get-ConfigStringArray $Values
    if ($items.Count -eq 0) {
        return "<none>"
    }

    return ($items -join ", ")
}

function Show-CurrentConfig([string]$TargetConfigPath) {
    $config = Read-ConfigObject $TargetConfigPath
    $prefixReport = Get-PatternFileReport $config.patterns.prefix_file
    $suffixReport = Get-PatternFileReport $config.patterns.suffix_file
    $patternMode = Get-ConfiguredPatternMode $prefixReport.TotalCount $suffixReport.TotalCount

    Write-Host "Current config"
    Write-Host "Config path         : $(Resolve-RepoPath $TargetConfigPath)"
    Write-Host "Engine              : $($config.engine)"
    Write-Host "Pattern mode        : $patternMode"
    Write-Host "Prefix file         : $($prefixReport.Path)"
    Write-Host "Prefix entries      : $($prefixReport.TotalCount)"
    Write-Host "Prefix preview      : $(if ($prefixReport.Preview.Count -gt 0) { $prefixReport.Preview -join ', ' } elseif ($prefixReport.Exists) { '<empty>' } else { '<missing file>' })"
    Write-Host "Suffix file         : $($suffixReport.Path)"
    Write-Host "Suffix entries      : $($suffixReport.TotalCount)"
    Write-Host "Suffix preview      : $(if ($suffixReport.Preview.Count -gt 0) { $suffixReport.Preview -join ', ' } elseif ($suffixReport.Exists) { '<empty>' } else { '<missing file>' })"
    Write-Host "Results file        : $($config.output.results_file)"
    Write-Host "Single keypair file : $($config.output.single_keypair_file)"
    Write-Host "Private key formats : $(Format-ValueList $config.output.private_key_formats)"
    Write-Host "Write match files   : $($config.output.write_match_files)"
    Write-Host "Matches dir         : $($config.output.matches_dir)"

    switch ($config.engine) {
        "cpu" {
            Write-Host "CPU threads         : $($config.cpu.threads)"
            Write-Host "CPU max_attempts    : $($config.cpu.max_attempts)"
            Write-Host "CPU keep_running    : $($config.cpu.keep_running)"
        }
        "gpu" {
            Write-Host "GPU cuda_arch       : $($config.gpu.cuda_arch)"
            Write-Host "GPU max_iterations  : $($config.gpu.max_iterations)"
            Write-Host "GPU max_matches     : $($config.gpu.max_matches)"
        }
    }
}

function Ensure-ConfigTemplate([string]$TargetConfigPath) {
    $fullConfigPath = Resolve-RepoPath $TargetConfigPath
    if (Test-Path $fullConfigPath) {
        return $fullConfigPath
    }

    if (-not (Test-Path $defaultConfigTemplate)) {
        throw "Default config template not found: $defaultConfigTemplate"
    }

    $parent = Split-Path -Parent $fullConfigPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Copy-Item $defaultConfigTemplate $fullConfigPath -Force
    return $fullConfigPath
}

function Get-ExecutablePath([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        if ($command.Path) {
            return $command.Path
        }
        if ($command.Source) {
            return $command.Source
        }
    }

    return $null
}

function Get-NvidiaSmiPath {
    $fromPath = Get-ExecutablePath "nvidia-smi"
    if ($fromPath) {
        return $fromPath
    }

    foreach ($candidate in $commonNvidiaSmiPaths) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-NvidiaGpuNames([string]$NvidiaSmiPath) {
    if (-not $NvidiaSmiPath) {
        return Get-WindowsNvidiaGpuNames
    }

    try {
        $names = & $NvidiaSmiPath "--query-gpu=name" "--format=csv,noheader" 2>$null
        if ($names) {
            return @($names | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        }
    } catch {
    }

    try {
        $fallback = & $NvidiaSmiPath "-L" 2>$null
        if ($fallback) {
            return @(
                $fallback |
                ForEach-Object {
                    if ($_ -match "GPU \d+: (.+?) \(UUID:") {
                        $matches[1].Trim()
                    }
                } |
                Where-Object { $_ }
            )
        }
    } catch {
    }

    return Get-WindowsNvidiaGpuNames
}

function Get-WindowsNvidiaGpuNames {
    try {
        return @(
            Get-CimInstance Win32_VideoController |
            Where-Object {
                "$($_.Name)" -match "NVIDIA" -or
                "$($_.AdapterCompatibility)" -match "NVIDIA"
            } |
            ForEach-Object { "$($_.Name)".Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
        )
    } catch {
        return @()
    }
}

function Get-NvccPath {
    $fromPath = Get-ExecutablePath "nvcc"
    if ($fromPath) {
        return $fromPath
    }

    if ($env:CUDA_PATH) {
        $candidate = Join-Path $env:CUDA_PATH "bin\nvcc.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    foreach ($root in $commonCudaRoots) {
        $candidate = Join-Path $root "bin\nvcc.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-CudaRoot([string]$NvccPath) {
    if (-not $NvccPath) {
        return $null
    }

    $binDir = Split-Path -Parent $NvccPath
    return Split-Path -Parent $binDir
}

function Get-VsDevShellPath {
    foreach ($candidate in $gpuBuildToolCandidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-GpuArchSuggestion([string[]]$GpuNames) {
    foreach ($gpuName in $GpuNames) {
        switch -Regex ($gpuName) {
            "RTX 4\d{3}|L4|ADA" {
                return [PSCustomObject]@{
                    Value = "sm_89"
                    Confidence = "high"
                    Reason = "Detected Ada-generation NVIDIA GPU."
                    GpuName = $gpuName
                }
            }
            "RTX 3\d{3}|A10|A16|A2|A40" {
                return [PSCustomObject]@{
                    Value = "sm_86"
                    Confidence = "high"
                    Reason = "Detected Ampere-generation NVIDIA GPU."
                    GpuName = $gpuName
                }
            }
            "RTX 20\d{2}|TITAN RTX|T4|GTX 16\d{2}" {
                return [PSCustomObject]@{
                    Value = "sm_75"
                    Confidence = "high"
                    Reason = "Detected Turing-generation NVIDIA GPU."
                    GpuName = $gpuName
                }
            }
            "V100" {
                return [PSCustomObject]@{
                    Value = "sm_70"
                    Confidence = "medium"
                    Reason = "Detected Volta-generation NVIDIA GPU."
                    GpuName = $gpuName
                }
            }
            "P100" {
                return [PSCustomObject]@{
                    Value = "sm_60"
                    Confidence = "medium"
                    Reason = "Detected Pascal P100 GPU."
                    GpuName = $gpuName
                }
            }
            "GTX 10\d{2}|P4|P40|P6" {
                return [PSCustomObject]@{
                    Value = "sm_61"
                    Confidence = "medium"
                    Reason = "Detected Pascal-generation NVIDIA GPU."
                    GpuName = $gpuName
                }
            }
        }
    }

    return $null
}

function Get-EnvironmentReport([string]$TargetConfigPath) {
    $configExists = Test-Path (Resolve-RepoPath $TargetConfigPath)
    $config = if ($configExists) { Read-ConfigObject $TargetConfigPath } else { $null }

    $nvidiaSmiPath = Get-NvidiaSmiPath
    $gpuNames = Get-NvidiaGpuNames $nvidiaSmiPath
    $nvccPath = Get-NvccPath
    $cudaRoot = Get-CudaRoot $nvccPath
    $vsDevShellPath = Get-VsDevShellPath
    $gpuArchSuggestion = Get-GpuArchSuggestion $gpuNames
    $hasNvidiaGpu = $gpuNames.Count -gt 0
    $hasCuda = -not [string]::IsNullOrWhiteSpace($nvccPath)
    $hasBuildTools = -not [string]::IsNullOrWhiteSpace($vsDevShellPath)
    $gpuReady = $hasNvidiaGpu -and $hasCuda -and $hasBuildTools

    $recommendedEngine = if ($gpuReady) { "gpu" } else { "cpu" }
    $missing = [System.Collections.Generic.List[string]]::new()

    if ($hasNvidiaGpu -and -not $hasCuda) {
        [void]$missing.Add("CUDA Toolkit (`nvcc.exe`) was not found.")
    }
    if ($hasNvidiaGpu -and -not $hasBuildTools) {
        [void]$missing.Add("Visual Studio Build Tools developer shell was not found.")
    }
    if (-not $hasNvidiaGpu) {
        [void]$missing.Add("No NVIDIA GPU was detected, so CPU is the safest default.")
    }
    if ($hasNvidiaGpu -and $hasCuda -and $hasBuildTools -and -not $gpuArchSuggestion) {
        [void]$missing.Add("CUDA architecture could not be inferred automatically. You may need to set `gpu.cuda_arch` manually.")
    }

    return [PSCustomObject]@{
        ConfigExists = $configExists
        ConfigPath = Resolve-RepoPath $TargetConfigPath
        CurrentEngine = if ($configExists) { $config.engine } else { $null }
        CurrentCudaArch = if ($configExists) { $config.gpu.cuda_arch } else { $null }
        NvidiaSmiPath = $nvidiaSmiPath
        GpuNames = $gpuNames
        HasNvidiaGpu = $hasNvidiaGpu
        NvccPath = $nvccPath
        CudaRoot = $cudaRoot
        HasCuda = $hasCuda
        VsDevShellPath = $vsDevShellPath
        HasBuildTools = $hasBuildTools
        GpuArchSuggestion = $gpuArchSuggestion
        GpuReady = $gpuReady
        RecommendedEngine = $recommendedEngine
        Missing = @($missing)
    }
}

function Show-DoctorReport($Report) {
    Write-Host "Environment check"
    Write-Host "Config path        : $($Report.ConfigPath)"
    Write-Host "Current engine     : $(if ($Report.CurrentEngine) { $Report.CurrentEngine } else { '<none>' })"
    Write-Host "NVIDIA GPU         : $(if ($Report.HasNvidiaGpu) { ($Report.GpuNames -join ', ') } else { 'not detected' })"
    Write-Host "CUDA / nvcc        : $(if ($Report.HasCuda) { $Report.NvccPath } else { 'not found' })"
    Write-Host "Build tools        : $(if ($Report.HasBuildTools) { $Report.VsDevShellPath } else { 'not found' })"
    Write-Host "Suggested cuda_arch: $(if ($Report.GpuArchSuggestion) { $Report.GpuArchSuggestion.Value + ' (' + $Report.GpuArchSuggestion.Reason + ')' } elseif ($Report.CurrentCudaArch) { $Report.CurrentCudaArch + ' (from current config)' } else { 'manual selection needed' })"
    Write-Host "Recommended engine : $($Report.RecommendedEngine)"
    Write-Host ""

    if ($Report.RecommendedEngine -eq "gpu") {
        Write-Host "Compatibility:"
        Write-Host "- GPU mode looks usable on this machine."
        Write-Host "- CPU mode is still available if you want the simplest path."
    } elseif ($Report.HasNvidiaGpu) {
        Write-Host "Compatibility:"
        Write-Host "- NVIDIA hardware was detected, but the GPU toolchain is incomplete."
        Write-Host "- CPU is recommended until the missing GPU requirements are installed."
    } else {
        Write-Host "Compatibility:"
        Write-Host "- CPU mode is recommended."
        Write-Host "- GPU mode requires an NVIDIA GPU, CUDA Toolkit, and Visual Studio Build Tools."
    }

    if ($Report.Missing.Count -gt 0) {
        Write-Host ""
        Write-Host "Next actions:"
        foreach ($item in $Report.Missing) {
            Write-Host "- $item"
        }
    }
}

function Get-CharVariantCount([char]$Char) {
    $variants = [System.Collections.Generic.HashSet[string]]::new()
    if ([char]::IsLetter($Char)) {
        foreach ($candidate in @($Char, [char]::ToUpperInvariant($Char), [char]::ToLowerInvariant($Char))) {
            if ($base58Alphabet.Contains([string]$candidate)) {
                [void]$variants.Add([string]$candidate)
            }
        }
    } elseif ($base58Alphabet.Contains([string]$Char)) {
        [void]$variants.Add([string]$Char)
    }

    if ($variants.Count -eq 0) {
        throw "Character '$Char' cannot appear in a Solana Base58 vanity pattern."
    }

    return $variants.Count
}

function Get-WordVariantInfo([string]$InputWord) {
    if ([string]::IsNullOrWhiteSpace($InputWord)) {
        return $null
    }

    $count = 1L
    $singleCaseLetters = 0
    foreach ($char in $InputWord.ToCharArray()) {
        $variantCount = Get-CharVariantCount $char
        $count *= $variantCount
        if ($variantCount -eq 1) {
            $singleCaseLetters += 1
        }
    }

    return [PSCustomObject]@{
        Word = $InputWord
        VariantCount = $count
        SingleCaseLetters = $singleCaseLetters
        Length = $InputWord.Length
    }
}

function Read-DefaultedText([string]$Prompt, [string]$DefaultValue) {
    $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { "" } else { " [$DefaultValue]" }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultValue
    }
    return $answer.Trim()
}

function Read-Choice([string]$Prompt, [string[]]$Choices, [string]$DefaultValue) {
    while ($true) {
        $answer = Read-DefaultedText "$Prompt ($($Choices -join '/'))" $DefaultValue
        foreach ($choice in $Choices) {
            if ($answer -ieq $choice) {
                return $choice
            }
        }
        Write-Host "Choose one of: $($Choices -join ', ')"
    }
}

function Read-YesNo([string]$Prompt, [bool]$DefaultValue) {
    $defaultText = if ($DefaultValue) { "Y" } else { "N" }
    while ($true) {
        $answer = Read-DefaultedText "$Prompt (y/n)" $defaultText
        switch -Regex ($answer) {
            "^(y|yes)$" { return $true }
            "^(n|no)$" { return $false }
        }
        Write-Host "Enter y or n."
    }
}

function Read-PositiveInt([string]$Prompt, [int]$DefaultValue, [int]$MinimumValue) {
    while ($true) {
        $answer = Read-DefaultedText $Prompt ([string]$DefaultValue)
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge $MinimumValue) {
            return $parsed
        }
        Write-Host "Enter an integer greater than or equal to $MinimumValue."
    }
}

function Read-CudaArch([string]$Prompt, [string]$DefaultValue) {
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            $answer = Read-Host "$Prompt (examples: sm_89, sm_86, sm_75)"
        } else {
            $answer = Read-DefaultedText "$Prompt (examples: sm_89, sm_86, sm_75)" $DefaultValue
        }

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host "Enter a CUDA architecture like sm_89."
            continue
        }

        $trimmed = $answer.Trim()
        if ($trimmed -match "^sm_\d+$") {
            return $trimmed
        }

        Write-Host "Enter a CUDA architecture in the form sm_XX, for example sm_89."
    }
}

function Invoke-Generator {
    param(
        [string]$TargetWord,
        [string]$TargetPrefix,
        [string]$TargetSuffix,
        [string]$TargetConfigPath
    )

    if ($TargetWord) {
        & (Join-Path $repoRoot "generate-word-variants.ps1") `
            -Word $TargetWord `
            -ConfigPath $TargetConfigPath `
            -UpdateConfig `
            -Quiet:$true
        return
    }

    & (Join-Path $repoRoot "generate-word-variants.ps1") `
        -PrefixWord $TargetPrefix `
        -SuffixWord $TargetSuffix `
        -ConfigPath $TargetConfigPath `
        -UpdateConfig `
        -Quiet:$true
}

function Show-InitSummary($Plan) {
    Write-Host ""
    Write-Host "Setup summary"
    Write-Host "Config path        : $($Plan.ConfigPath)"
    Write-Host "Engine             : $($Plan.Engine)"
    if ($Plan.Engine -eq "gpu") {
        Write-Host "cuda_arch          : $($Plan.CudaArch)"
    }
    Write-Host "Mode               : $($Plan.Mode)"
    if ($Plan.Mode -eq "word") {
        Write-Host "Word               : $($Plan.Word)"
        Write-Host "Variants           : $($Plan.WordInfo.VariantCount)"
    } else {
        if ($Plan.PrefixWord) {
            Write-Host "Prefix word        : $($Plan.PrefixWord)"
            Write-Host "Prefix variants    : $($Plan.PrefixInfo.VariantCount)"
        }
        if ($Plan.SuffixWord) {
            Write-Host "Suffix word        : $($Plan.SuffixWord)"
            Write-Host "Suffix variants    : $($Plan.SuffixInfo.VariantCount)"
        }
    }
    Write-Host "Results file       : $($Plan.ResultsFile)"
    Write-Host "Keypair file       : $($Plan.SingleKeypairFile)"
    Write-Host "After setup        : $($Plan.PostAction)"
    if ($Plan.PostAction -eq "smoke") {
        if ($Plan.Engine -eq "cpu") {
            Write-Host "Smoke attempts     : $($Plan.SmokeCpuAttempts)"
        } else {
            Write-Host "Smoke iterations   : $($Plan.SmokeGpuIterations)"
        }
    }

    if ($Plan.GpuWarnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Warnings:"
        foreach ($warning in $Plan.GpuWarnings) {
            Write-Host "- $warning"
        }
    }
}

function New-InitPlan([string]$TargetConfigPath) {
    $report = Get-EnvironmentReport $TargetConfigPath
    Show-DoctorReport $report
    Write-Host ""

    $existingConfig = if ($report.ConfigExists) { Read-ConfigObject $TargetConfigPath } else { Read-ConfigObject $defaultConfigTemplate }
    $defaultEngine = if ($report.RecommendedEngine) { $report.RecommendedEngine } else { $existingConfig.engine }
    $selectedEngine = Read-Choice "Choose engine" @("cpu", "gpu") $defaultEngine

    $selectedCudaArch = $null
    if ($selectedEngine -eq "gpu") {
        $defaultCudaArch = if ($report.GpuArchSuggestion) {
            $report.GpuArchSuggestion.Value
        } elseif ($report.ConfigExists -and $existingConfig.gpu.cuda_arch) {
            $existingConfig.gpu.cuda_arch
        } else {
            ""
        }

        if ([string]::IsNullOrWhiteSpace($defaultCudaArch)) {
            Write-Host "CUDA architecture could not be inferred automatically."
            Write-Host "Enter it manually so GPU setup does not assume the template value."
        }

        $selectedCudaArch = Read-CudaArch "CUDA architecture" $defaultCudaArch
    }

    $defaultMode = if ($selectedEngine -eq "gpu") { "split" } else { "word" }
    $mode = Read-Choice "Generate patterns as a single word or split prefix/suffix" @("word", "split") $defaultMode

    $targetWord = ""
    $targetPrefix = ""
    $targetSuffix = ""
    $wordInfo = $null
    $prefixInfo = $null
    $suffixInfo = $null

    if ($mode -eq "word") {
        $targetWord = Read-DefaultedText "Target word" "Starforge"
        $wordInfo = Get-WordVariantInfo $targetWord
    } else {
        $targetPrefix = Read-DefaultedText "Prefix word" "Star"
        $targetSuffix = Read-DefaultedText "Suffix word" "forge"
        if (-not $targetPrefix -and -not $targetSuffix) {
            throw "Provide at least one of prefix or suffix."
        }
        if ($targetPrefix) {
            $prefixInfo = Get-WordVariantInfo $targetPrefix
        }
        if ($targetSuffix) {
            $suffixInfo = Get-WordVariantInfo $targetSuffix
        }
    }

    $customOutputs = Read-YesNo "Customize output file paths?" $false
    $resultsFile = $existingConfig.output.results_file
    $singleKeypairFile = $existingConfig.output.single_keypair_file
    if ($customOutputs) {
        $resultsFile = Read-DefaultedText "Results JSONL path" $resultsFile
        $singleKeypairFile = Read-DefaultedText "Single keypair output path" $singleKeypairFile
    }

    $postAction = Read-Choice "Action after setup" @("none", "build", "smoke", "run") "smoke"
    $smokeCpuAttempts = $SmokeCpuAttempts
    $smokeGpuIterations = $SmokeGpuIterations
    if ($postAction -eq "smoke") {
        if ($selectedEngine -eq "cpu") {
            $smokeCpuAttempts = Read-PositiveInt "CPU smoke max attempts" $SmokeCpuAttempts 1
        } else {
            $smokeGpuIterations = Read-PositiveInt "GPU smoke max iterations" $SmokeGpuIterations 1
        }
    }

    if ($postAction -eq "run") {
        $confirmed = Read-YesNo "Start a full search after setup? This can run until you stop it." $false
        if (-not $confirmed) {
            $postAction = "none"
        }
    }

    $gpuWarnings = [System.Collections.Generic.List[string]]::new()
    if ($selectedEngine -eq "gpu") {
        if ($mode -eq "word" -and $wordInfo) {
            if ($wordInfo.VariantCount -gt $gpuPrefixLimit) {
                [void]$gpuWarnings.Add("Single-word mode produces more than $gpuPrefixLimit prefix variants.")
            }
            if ($wordInfo.Length -gt $gpuPatternCharLimit) {
                [void]$gpuWarnings.Add("Single-word mode exceeds the GPU pattern length limit of $gpuPatternCharLimit characters.")
            }
        } else {
            if ($prefixInfo -and $prefixInfo.VariantCount -gt $gpuPrefixLimit) {
                [void]$gpuWarnings.Add("Prefix variants exceed the GPU limit of $gpuPrefixLimit entries.")
            }
            if ($suffixInfo -and $suffixInfo.VariantCount -gt $gpuSuffixLimit) {
                [void]$gpuWarnings.Add("Suffix variants exceed the GPU limit of $gpuSuffixLimit entries.")
            }
            if ($prefixInfo -and $prefixInfo.Length -gt $gpuPatternCharLimit) {
                [void]$gpuWarnings.Add("Prefix word exceeds the GPU pattern length limit of $gpuPatternCharLimit characters.")
            }
            if ($suffixInfo -and $suffixInfo.Length -gt $gpuPatternCharLimit) {
                [void]$gpuWarnings.Add("Suffix word exceeds the GPU pattern length limit of $gpuPatternCharLimit characters.")
            }
        }
    }

    return [PSCustomObject]@{
        ConfigPath = $TargetConfigPath
        Engine = $selectedEngine
        CudaArch = $selectedCudaArch
        Mode = $mode
        Word = $targetWord
        PrefixWord = $targetPrefix
        SuffixWord = $targetSuffix
        WordInfo = $wordInfo
        PrefixInfo = $prefixInfo
        SuffixInfo = $suffixInfo
        ResultsFile = $resultsFile
        SingleKeypairFile = $singleKeypairFile
        PostAction = $postAction
        SmokeCpuAttempts = $smokeCpuAttempts
        SmokeGpuIterations = $smokeGpuIterations
        GpuWarnings = @($gpuWarnings)
    }
}

function Invoke-Init([string]$TargetConfigPath) {
    $plan = New-InitPlan $TargetConfigPath
    Show-InitSummary $plan
    Write-Host ""
    if (-not (Read-YesNo "Write config and continue?" $true)) {
        Write-Host "Setup cancelled."
        return
    }

    Ensure-ConfigTemplate $TargetConfigPath | Out-Null

    if ($plan.Mode -eq "word") {
        Invoke-Generator -TargetWord $plan.Word -TargetPrefix "" -TargetSuffix "" -TargetConfigPath $TargetConfigPath
    } else {
        Invoke-Generator -TargetWord "" -TargetPrefix $plan.PrefixWord -TargetSuffix $plan.SuffixWord -TargetConfigPath $TargetConfigPath
    }

    $config = Read-ConfigObject $TargetConfigPath
    $config.engine = $plan.Engine
    $config.output.results_file = $plan.ResultsFile
    $config.output.single_keypair_file = $plan.SingleKeypairFile

    if ($plan.Engine -eq "gpu" -and $plan.CudaArch) {
        $config.gpu.cuda_arch = $plan.CudaArch
    }

    Write-ConfigObject $TargetConfigPath $config

    Write-Host ""
    Write-Host "Config updated: $(Resolve-RepoPath $TargetConfigPath)"

    switch ($plan.PostAction) {
        "build" {
            & (Join-Path $repoRoot "build.ps1") -ConfigPath $TargetConfigPath -Engine $plan.Engine
        }
        "smoke" {
            Invoke-SmokeTest -TargetConfigPath $TargetConfigPath -TargetEngine $plan.Engine -CpuAttempts $plan.SmokeCpuAttempts -GpuIterations $plan.SmokeGpuIterations
        }
        "run" {
            Invoke-Run -TargetConfigPath $TargetConfigPath -TargetEngine $plan.Engine
        }
    }
}

function Invoke-Run([string]$TargetConfigPath, [string]$TargetEngine) {
    switch ($TargetEngine) {
        "" {
            & (Join-Path $repoRoot "run.ps1") -ConfigPath $TargetConfigPath
        }
        "cpu" {
            & (Join-Path $repoRoot "cpu\run.ps1") -ConfigPath $TargetConfigPath
        }
        "gpu" {
            & (Join-Path $repoRoot "gpu\run.ps1") -ConfigPath $TargetConfigPath
        }
        default {
            throw "Unknown engine '$TargetEngine'. Use cpu or gpu."
        }
    }
}

function Invoke-SmokeTest {
    param(
        [string]$TargetConfigPath,
        [string]$TargetEngine,
        [int]$CpuAttempts,
        [int]$GpuIterations
    )

    $config = Read-ConfigObject $TargetConfigPath
    if ($TargetEngine) {
        $config.engine = $TargetEngine
    }

    $smokeConfigPath = "runs/smoke-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$($config.engine).config.json"
    $config.output.results_file = "runs/smoke-matches.jsonl"
    $config.output.single_keypair_file = "runs/smoke-keypair.json"

    switch ($config.engine) {
        "cpu" {
            $config.cpu.max_attempts = [Math]::Max($CpuAttempts, 1)
            $config.cpu.keep_running = $false
            $config.cpu.report_every = [Math]::Max(1, [int]$config.cpu.report_every)
            Write-Host "Running CPU smoke test with max_attempts=$($config.cpu.max_attempts)"
        }
        "gpu" {
            $config.gpu.max_iterations = [Math]::Max($GpuIterations, 1)
            $config.gpu.max_matches = 1
            Write-Host "Running GPU smoke test with max_iterations=$($config.gpu.max_iterations)"
        }
        default {
            throw "Unknown engine in config: $($config.engine)"
        }
    }

    Write-ConfigObject $smokeConfigPath $config
    try {
        Invoke-Run -TargetConfigPath $smokeConfigPath -TargetEngine ""
        Write-Host "Smoke test completed."
    } catch {
        $message = $_.Exception.Message
        if ($message -like "*run failed with exit code 1*" -or $message -like "*No match found*") {
            Write-Host "Smoke test completed without a match. That is normal for a bounded test."
        } else {
            throw
        }
    } finally {
        $fullSmokeConfigPath = Resolve-RepoPath $smokeConfigPath
        if (Test-Path $fullSmokeConfigPath) {
            Remove-Item $fullSmokeConfigPath -Force
        }
    }
}

switch ($Command.ToLowerInvariant()) {
    "doctor" {
        Show-DoctorReport (Get-EnvironmentReport $ConfigPath)
    }

    "show" {
        Show-CurrentConfig $ConfigPath
    }

    "init" {
        Invoke-Init $ConfigPath
    }

    "smoke" {
        $engineToUse = if ($Engine) { $Engine } else { "" }
        Invoke-SmokeTest -TargetConfigPath $ConfigPath -TargetEngine $engineToUse -CpuAttempts $SmokeCpuAttempts -GpuIterations $SmokeGpuIterations
    }

    "setup" {
        if (-not $PrefixWord) {
            $PrefixWord = $Arg1
        }
        if (-not $SuffixWord) {
            $SuffixWord = $Arg2
        }
        if (-not $PrefixWord -and -not $SuffixWord) {
            throw "Provide at least one word: vanity setup <prefix> <suffix>"
        }

        & (Join-Path $repoRoot "generate-word-variants.ps1") `
            -PrefixWord $PrefixWord `
            -SuffixWord $SuffixWord `
            -ConfigPath $ConfigPath `
            -UpdateConfig `
            -Quiet:$true
    }

    "word" {
        if (-not $Word) {
            $Word = $Arg1
        }
        if (-not $Word) {
            throw "Provide a word: vanity word <word>"
        }

        & (Join-Path $repoRoot "generate-word-variants.ps1") `
            -Word $Word `
            -ConfigPath $ConfigPath `
            -UpdateConfig `
            -Quiet:$true
    }

    "generate" {
        & (Join-Path $repoRoot "generate-word-variants.ps1") `
            -Word $Word `
            -PrefixWord $PrefixWord `
            -SuffixWord $SuffixWord `
            -GroupedSpecPath $GroupedSpecPath `
            -OutputPath $OutputPath `
            -PrefixOutputPath $PrefixOutputPath `
            -SuffixOutputPath $SuffixOutputPath `
            -ConfigPath $ConfigPath `
            -UpdateConfig:$UpdateConfig `
            -Quiet:$Quiet `
            -Run:$Run `
            -Append:$Append `
            -MaxVariants $MaxVariants
    }

    "run" {
        Invoke-Run -TargetConfigPath $ConfigPath -TargetEngine $Engine
    }

    "build" {
        & (Join-Path $repoRoot "build.ps1") -ConfigPath $ConfigPath -Engine $Engine
    }

    "stop" {
        & (Join-Path $repoRoot "stop.ps1")
    }

    "help" {
        Show-Usage
    }

    default {
        throw "Unknown command '$Command'. Run 'vanity help' or '.\vanity.ps1 help'"
    }
}
