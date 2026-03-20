param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSCommandPath
$cpuBinary = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "target\release\solana-vanity.exe"))
$gpuBinary = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "gpu\bin\solana-vanity-gpu.exe"))

$processes = Get-CimInstance Win32_Process | Where-Object {
    $cmd = "$($_.CommandLine)"
    $exe = "$($_.ExecutablePath)"

    $exe -eq $cpuBinary -or
    $exe -eq $gpuBinary -or
    $cmd.Contains((Join-Path $repoRoot "run.ps1")) -or
    $cmd.Contains((Join-Path $repoRoot "cpu\run.ps1")) -or
    $cmd.Contains((Join-Path $repoRoot "gpu\run.ps1")) -or
    $cmd.Contains($cpuBinary) -or
    $cmd.Contains($gpuBinary)
} | Sort-Object ProcessId -Unique

if (-not $processes) {
    Write-Host "No running project search processes found."
    return
}

Write-Host "Stopping project search processes:"
foreach ($process in $processes) {
    $name = if ($process.Name) { $process.Name } else { "<unknown>" }
    Write-Host ("- PID {0} : {1}" -f $process.ProcessId, $name)
    Stop-Process -Id $process.ProcessId -Force
}

Write-Host "Done."
