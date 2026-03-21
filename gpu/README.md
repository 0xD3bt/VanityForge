# GPU Engine

This folder contains the CUDA-based engine and helper scripts for NVIDIA GPUs.

Run commands from the repository root unless noted otherwise.

## Main files

- `build.ps1`: builds the GPU binary using shared repo config inputs
- `run.ps1`: builds and runs the GPU engine using the shared repo config
- `vanity_cuda.cu`: CUDA scanner source

## How it is configured

The GPU engine uses the shared repo config and pattern files:

- `vanity.config.json`
- `patterns/prefixes/*.txt`
- `patterns/suffixes/*.txt`

For local-only configs that should stay out of git, prefer `.local/configs/`.

Before running, confirm `gpu.cuda_arch` for your NVIDIA card. The easiest path is:

```powershell
vanity doctor
vanity init
```

## Recommended usage

Build and run the GPU engine explicitly:

```powershell
vanity build -Engine gpu
vanity run -Engine gpu
```

Or run whatever engine is currently selected in the config:

```powershell
vanity run
```

## Direct scripts

Build only with explicit inputs:

```powershell
powershell -ExecutionPolicy Bypass -File .\gpu\build.ps1 -PrefixFile patterns\prefixes\example.txt -SuffixFile patterns\suffixes\example.txt -CudaArch sm_89
```

Run with a specific config:

```powershell
powershell -ExecutionPolicy Bypass -File .\gpu\run.ps1 -ConfigPath .local\configs\my-vanity.config.json
```

## Behavior notes

- the build script forces the Visual Studio x64 toolchain for CUDA on Windows
- `gpu.max_iterations: 0` means unlimited kernel launches
- `gpu.max_matches: 0` means unlimited matches
- GPU pattern limits are `256` prefixes, `128` suffixes, and `31` characters per entry
- `output.private_key_formats` currently defaults to `["base58"]`, so GPU JSONL output should be treated as secret-bearing unless you switch to `["none"]`
- listed configured targets always save in keep-running mode
- `output.enable_save_filter` prints the active save policy at startup
- `output.min_total_matched_chars` acts as an extra aesthetic save threshold and does not block listed targets below it
- listed/config matches append to `output.results_file`, while aesthetic matches append to `output.aesthetic_results_file`
- when the save filter is enabled, `gpu/run.ps1` prints `Save policy   : listed targets always saved` plus `Aesthetic     : on|off ...` before the iteration updates begin
- when the aesthetic path is enabled, the live `avg ...` timing remains an estimate for listed/config targets only
- the scanner is derived from Apache-licensed CUDA Solana `ed25519` code from `vendor-solanity`
