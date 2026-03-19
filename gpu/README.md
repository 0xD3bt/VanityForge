# GPU Engine

This folder contains the CUDA-based engine and helper scripts for NVIDIA GPUs.

## Main files

- `build.ps1`: builds the GPU binary using the shared repo config
- `run.ps1`: runs the GPU engine using the shared repo config
- `vanity_cuda.cu`: CUDA scanner source

## How it is configured

The GPU engine no longer uses hardcoded local pattern files in this folder.
Instead, it reads shared repo config from:

- `vanity.config.json`
- `patterns/prefixes/*.txt`
- `patterns/suffixes/*.txt`

## Typical usage

Build only:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Engine gpu
```

Run using the config-selected pattern files:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

Direct GPU run:

```powershell
powershell -ExecutionPolicy Bypass -File .\gpu\run.ps1
```

## Notes

- The build script forces the Visual Studio x64 toolchain for CUDA on Windows.
- `cuda_arch` comes from `vanity.config.json`, so users can change GPU targets without editing the CUDA source.
- The scanner is derived from Apache-licensed CUDA Solana `ed25519` code from `vendor-solanity`.
