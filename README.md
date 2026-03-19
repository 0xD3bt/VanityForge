# Solana Vanity CPU/GPU

`Solana Vanity CPU/GPU` is a config-driven Solana vanity address generator with both CPU and GPU engines. It supports Rust-based multithreaded CPU search and CUDA-accelerated NVIDIA GPU search, with shared pattern files, shared config, and JSONL output for collecting matches locally.

Users can switch between CPU and GPU in `vanity.config.json`, edit `patterns/prefixes/*.txt` and `patterns/suffixes/*.txt`, and run the same top-level PowerShell entrypoint. The internal package and binary name remain `solana-vanity`.

## Features

- Solana vanity address generation with CPU or GPU
- shared config for both engines
- prefix and suffix pattern files
- continuous multi-match collection to JSONL
- Base58 private key export for found matches
- Windows-friendly PowerShell build and run scripts

## Requirements

Run all commands from the repository root.

CPU requirements:

- Rust
- Cargo

GPU requirements:

- NVIDIA GPU
- CUDA Toolkit
- Visual Studio Build Tools with C++
- PowerShell on Windows

## Important warning

Result files can contain private keys.

- Do not share result files
- Do not commit result files
- Do not send private keys to anyone
- Keep `runs/` and any exported key files private

## Quick start

1. Edit `vanity.config.json`
2. Start with the default `engine: "cpu"` or switch to `engine: "gpu"` if you have an NVIDIA CUDA setup
3. Edit your prefix and suffix pattern files
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

## Config

Main config file:

- `vanity.config.json`

Example:

```json
{
  "engine": "cpu",
  "patterns": {
    "prefix_file": "patterns/prefixes/example.txt",
    "suffix_file": "patterns/suffixes/example.txt"
  },
  "output": {
    "results_file": "runs/matches.jsonl",
    "single_keypair_file": "runs/vanity-keypair.json",
    "private_key_formats": ["base58"],
    "write_match_files": false,
    "matches_dir": "runs/matches"
  },
  "cpu": {
    "threads": 0,
    "report_every": 2,
    "max_attempts": 0,
    "keep_running": true
  },
  "gpu": {
    "cuda_arch": "sm_89",
    "attempts_per_execution": 100000,
    "max_iterations": 0,
    "max_matches": 0
  }
}
```

Key settings:

- `engine`: `cpu` or `gpu`
- `cpu`: settings for the Rust multithreaded engine
- `gpu`: settings for the CUDA engine
- `patterns.prefix_file`: text file with one allowed prefix per line
- `patterns.suffix_file`: text file with one allowed suffix per line
- `output.results_file`: append-only JSONL results file
- `output.single_keypair_file`: base output path used by CPU one-hit mode
- `output.private_key_formats`: which private-key representations to save
- `gpu.cuda_arch`: CUDA arch like `sm_89` for an RTX 4090

### Private key formats

Supported values in `output.private_key_formats`:

- `base58`
- `solana-json`
- `seed-base58`
- `seed-hex`
- `all`

Recommended default:

```json
"private_key_formats": ["base58"]
```

Save every supported format:

```json
"private_key_formats": ["all"]
```

What each format means:

- `base58`: Base58-encoded 64-byte Solana keypair
- `solana-json`: Solana CLI-friendly 64-byte decimal array
- `seed-base58`: Base58-encoded first 32-byte seed only
- `seed-hex`: hex-encoded first 32-byte seed only

## Pattern files

Shared pattern files live in:

- `patterns/prefixes/`
- `patterns/suffixes/`

The default example setup uses:

- `patterns/prefixes/example.txt`
- `patterns/suffixes/example.txt`

Each file uses one pattern per line. Blank lines, surrounding whitespace, and `#` comments are ignored.

GPU-specific pattern limits:

- maximum `128` prefixes
- maximum `32` suffixes
- maximum pattern length `15` characters per entry

If you need larger pattern sets or longer entries, use the CPU engine.

## Running

Use the engine selected in `vanity.config.json`:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

Quick CPU example:

```json
"engine": "cpu"
```

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

Quick GPU example:

```json
"engine": "gpu"
```

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

For GPU users, also set `gpu.cuda_arch` for your card before running.

What the top-level scripts do:

- `run.ps1`: reads `vanity.config.json` and runs either the CPU or GPU engine
- `build.ps1`: reads `vanity.config.json` and builds either the CPU or GPU engine

Choose CPU in the config when you want broad compatibility and easy setup.

Choose GPU in the config when you have an NVIDIA card and want much higher search throughput.

Build the engine selected in `vanity.config.json`:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Run CPU explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Engine cpu
powershell -ExecutionPolicy Bypass -File .\cpu\run.ps1
```

Run GPU explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Engine gpu
powershell -ExecutionPolicy Bypass -File .\gpu\run.ps1
```

Build both:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Engine all
```

## CPU engine

The CPU engine uses the Rust binary in `src/main.rs`.

Use CPU when:

- you want the simplest setup
- you do not have a supported NVIDIA CUDA environment
- you want maximum portability

Behavior:

- loads prefixes and suffixes from the shared pattern files
- supports one-hit mode or keep-running mode
- can write one JSONL file for all matches
- can optionally write one file per match

When `cpu.keep_running` is `true`, matches are appended to `output.results_file`.

When `cpu.keep_running` is `false`, the single winning keypair is written to:

- `output.single_keypair_file` if `solana-json` is selected
- `<same-stem>.pubkey.txt`
- `<same-stem>.base58.txt` if `base58` is selected
- `<same-stem>.seed.base58.txt` if `seed-base58` is selected
- `<same-stem>.seed.hex.txt` if `seed-hex` is selected

If `output.write_match_files` is `true`, keep-running CPU mode also writes one set of files per match in `output.matches_dir`.

## GPU engine

The GPU engine lives in `gpu/` and is built with `nvcc`.

Use GPU when:

- you have an NVIDIA GPU
- you have CUDA Toolkit and Visual Studio Build Tools installed
- you want much higher throughput than CPU

Behavior:

- rebuilds a small generated CUDA config from the shared pattern files
- uses the configured `gpu.cuda_arch`
- appends match rows to `output.results_file`
- only emits the private-key fields selected in `output.private_key_formats`
- supports JSONL match output, not CPU-style one-hit companion files

Current default target:

- `sm_89`, which matches an RTX 4090

### How to find `cuda_arch`

The GPU config expects a CUDA architecture string like:

- `sm_89`
- `sm_86`
- `sm_75`

Users usually find it in 3 steps:

1. Find the GPU model name:

```powershell
nvidia-smi -L
```

2. Look up that GPU on NVIDIA's CUDA GPU / compute capability list
3. Convert compute capability to the `sm_XX` format used by `vanity.config.json`

Examples:

- compute capability `8.9` -> `sm_89`
- compute capability `8.6` -> `sm_86`
- compute capability `7.5` -> `sm_75`

Common NVIDIA examples:

- `RTX 4090` -> `sm_89`
- `RTX 3090` -> `sm_86`
- `RTX 3080` -> `sm_86`
- `RTX 2080 Ti` -> `sm_75`

If users are unsure, they should:

- run `nvidia-smi -L`
- search their GPU model plus `CUDA compute capability`
- put the resulting `sm_XX` value into `gpu.cuda_arch` in `vanity.config.json`

### GPU notes

- The shipped config defaults to `cpu` so the repo works on more machines out of the box.
- Switch `engine` to `gpu` when you want CUDA acceleration.
- Locally built unsigned GPU binaries can trigger antivirus heuristics on Windows. If that happens, review the repo, then allow or exclude only this project folder if you trust it.

## Output format

The JSONL output file contains one JSON object per line. Typical fields:

- `address`
- `matched_prefix`
- `matched_suffix`
- `attempts`
- `private_key_base58` if `base58` is enabled
- `solana_keypair_bytes` if `solana-json` is enabled
- `secret_seed_base58` if `seed-base58` is enabled
- `seed_hex` if `seed-hex` is enabled
- file path fields for CPU file outputs when applicable

## Base58 rules

Solana addresses use Base58 and cannot contain:

- `0`
- `O`
- `I`
- lowercase `l`

## Notes

- The GPU engine is much faster for broad vanity pools, but exact long targets are still expensive.
- The CPU engine is easier to set up and works without CUDA.
- The CUDA engine currently targets Windows + NVIDIA + CUDA Toolkit + Visual Studio Build Tools.
- The GPU scanner is derived from Apache-licensed CUDA Solana `ed25519` code in `vendor-solanity`.

## License

This project is licensed under `Apache-2.0`. See `LICENSE`.
