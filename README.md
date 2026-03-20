![VanityForge logo](assets/vanityforge-logo.png)

# VanityForge

`VanityForge` is a config-driven Solana vanity address generator with both CPU and GPU engines. It supports Rust-based multithreaded CPU search and CUDA-accelerated NVIDIA GPU search, with shared pattern files, shared config, and JSONL output for collecting matches locally.

Users can switch between CPU and GPU in `vanity.config.json`, edit `patterns/prefixes/*.txt` and `patterns/suffixes/*.txt`, and run the same top-level PowerShell entrypoint. The public project name is `VanityForge`; the internal package and binary names currently remain `solana-vanity` and `solana-vanity-gpu` for compatibility.

## Features

- Solana vanity address generation with CPU or NVIDIA GPU
- shared config and shared prefix/suffix pattern files
- interactive `doctor`, `init`, and `smoke` commands for setup and safe first runs
- helper script for generating Base58-valid word variants and updating config
- one-command build, run, and stop PowerShell helpers for Windows
- append-only JSONL match output plus optional key export formats
- safer smoke-test run mode that refuses unbounded helper-triggered searches

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

<details>
<summary>Windows setup guide for required tools</summary>

If you already have the tools installed, skip this section.

CPU-only setup:

1. Install Rust from [rustup.rs](https://rustup.rs/).
2. Open a new PowerShell window after install.
3. Verify it works:

```powershell
cargo --version
```

GPU setup on Windows:

1. Make sure you have an NVIDIA GPU.
2. Install the [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads).
3. Install [Build Tools for Visual Studio](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022).
4. In the Visual Studio installer, install the C++ build tools workload.
5. In the installer details, make sure these components are selected:
   - `MSVC v143 - VS 2022 C++ x64/x86 build tools`
   - `Windows 11 SDK`
6. Open a new PowerShell window after installation.
7. Verify the toolchain:

```powershell
nvcc --version
```

Project verification:

```powershell
.\install.ps1
vanity doctor
```

If `vanity doctor` recommends CPU mode, you can still use the project without CUDA by staying on the CPU engine.
</details>

## Install

Install the global `vanity` and `v` commands:

```powershell
.\install.ps1
```

Remove them later if needed:

```powershell
.\uninstall.ps1
```

## Important warning

Result files can contain private keys.

- Do not share result files
- Do not commit result files
- Do not send private keys to anyone
- Keep `private/` and any exported key files private
- `runs/` stays non-secret by default only when `output.private_key_formats` is `["none"]`

## Quick start

Simplest setup path:

1. Install the commands once:

```powershell
.\install.ps1
```

2. Check your machine and get an engine recommendation:

```powershell
vanity doctor
```

3. Run the setup wizard:

```powershell
vanity init
```

4. Run a bounded smoke test:

```powershell
vanity smoke
```

5. Run the search:

```powershell
vanity run
```

6. Stop a running search if needed:

```powershell
vanity stop
```

Repo-local fallback without installing:

1. Check your machine and get an engine recommendation:

```powershell
.\vanity.ps1 doctor
```

2. Run the setup wizard:

```powershell
.\vanity.ps1 init
```

3. Run a bounded smoke test:

```powershell
.\vanity.ps1 smoke
```

4. Run the search:

```powershell
.\vanity.ps1 run
```

5. Stop a running search if needed:

```powershell
.\vanity.ps1 stop
```

If you want to work manually instead, you can still edit `vanity.config.json` and the pattern files yourself.

## Commands

After `.\install.ps1`, you can use:

Check GPU/CUDA/build tools and get an engine recommendation:

```powershell
vanity doctor
```

Show the current config, pattern files, and example entries:

```powershell
vanity show
```

Run the interactive setup wizard:

```powershell
vanity init
```

Run a bounded smoke test:

```powershell
vanity smoke
```

Generate prefix and suffix variants and update config:

```powershell
vanity setup Star forge
```

Use `setup` when you want two separate pattern pools:

- `Star` becomes the prefix word
- `forge` becomes the suffix word
- this is best for searches like "starts with Star, ends with forge"

Generate one full-word pattern file and update config:

```powershell
vanity word Starforge
```

Use `word` when you want one full target word:

- `Starforge` is treated as a single whole word
- this is best for searches that should match one complete word pattern instead of split prefix/suffix parts

Run the currently configured search:

```powershell
vanity run
```

Build the currently configured engine:

```powershell
vanity build
```

Stop any running project search process:

```powershell
vanity stop
```

Short alias:

```powershell
v run
```

Repo-local fallback without installing:

Check GPU/CUDA/build tools and get an engine recommendation:

```powershell
.\vanity.ps1 doctor
```

Show the current config, pattern files, and example entries:

```powershell
.\vanity.ps1 show
```

Run the interactive setup wizard:

```powershell
.\vanity.ps1 init
```

Run a bounded smoke test:

```powershell
.\vanity.ps1 smoke
```

Generate prefix and suffix variants and update config:

```powershell
.\vanity.ps1 setup Star forge
```

Use `setup` for split prefix/suffix words.

Generate one full-word pattern file and update config:

```powershell
.\vanity.ps1 word Starforge
```

Use `word` for one full target word.

Run the currently configured search:

```powershell
.\vanity.ps1 run
```

Build the currently configured engine:

```powershell
.\vanity.ps1 build
```

Stop any running project search process:

```powershell
.\vanity.ps1 stop
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
    "single_keypair_file": "private/vanity-keypair.json",
    "private_key_formats": ["none"],
    "write_match_files": false,
    "matches_dir": "private/matches"
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

Default output layout:

- `runs/`: JSONL run output and non-secret run artifacts
- `private/`: secret-bearing keypair files and per-match secret exports

### Private key formats

Supported values in `output.private_key_formats`:

- `none`
- `base58`
- `solana-json`
- `seed-base58`
- `seed-hex`
- `all`

Recommended default:

```json
"private_key_formats": ["none"]
```

Save every supported format:

```json
"private_key_formats": ["all"]
```

What each format means:

- `none`: do not include private-key material in JSONL output
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

### Generate variants from a word

The helper generates Base58-valid case variants for a target word and can optionally write pattern files or update `vanity.config.json`. Most users should start with `vanity init`; use the commands below when you want direct control over pattern generation.

Default example:

```powershell
vanity generate
```

Common helper workflows:

```powershell
vanity setup Star forge
```

`setup` means `prefix word` then `suffix word`.

- `vanity setup Star forge` means prefixes based on `Star` and suffixes based on `forge`
- use this when you want split matching, not one single combined word

```powershell
vanity word Starforge
```

`word` means one full combined word.

- `vanity word Starforge` means generate variants for the whole word `Starforge`
- use this when you want one target word instead of separate prefix and suffix pools

```powershell
vanity stop
```

More examples:

```powershell
vanity generate -Word "Moonwalker" -OutputPath "patterns/prefixes/moonwalker.txt"
```

```powershell
vanity generate -PrefixWord "Nova" -SuffixWord "core" -UpdateConfig -ConfigPath "my-vanity.config.json" -Quiet
```

Notes:

- only Base58-valid characters are emitted
- invalid vanity characters such as `0`, `O`, `I`, and lowercase `l` are rejected
- letters that only have one valid Base58 case stay fixed
- use `-PrefixWord` and `-SuffixWord` when you want smaller, more practical pattern sets
- use `-Quiet` when you only want the summary, warnings, and output paths
- `-UpdateConfig` writes generated files and updates `patterns.prefix_file` and `patterns.suffix_file`
- `-Run` starts a bounded smoke test only and refuses unbounded configs
- use `.\run.ps1` for full searches
- in single-word mode, `-UpdateConfig` sets the prefix file and creates an intentionally empty suffix file
- very large expansions are blocked unless you raise `-MaxVariants`

GPU-specific pattern limits:

- maximum `128` prefixes
- maximum `32` suffixes
- maximum pattern length `15` characters per entry

If you need larger pattern sets or longer entries, use the CPU engine.

## Running

Use the engine selected in `vanity.config.json`:

```powershell
vanity run
```

Quick CPU example:

```json
"engine": "cpu"
```

```powershell
vanity run
```

Quick GPU example:

```json
"engine": "gpu"
```

```powershell
vanity run
```

For GPU users, also set `gpu.cuda_arch` for your card before running.

What the top-level scripts do:

- `run.ps1`: reads `vanity.config.json` and runs either the CPU or GPU engine
- `build.ps1`: reads `vanity.config.json` and builds either the CPU or GPU engine

Choose CPU in the config when you want broad compatibility and easy setup.

Choose GPU in the config when you have an NVIDIA card and want much higher search throughput.

Build the engine selected in `vanity.config.json`:

```powershell
vanity build
```

Run CPU explicitly:

```powershell
vanity build -Engine cpu
vanity run -Engine cpu
```

Run GPU explicitly:

```powershell
vanity build -Engine gpu
vanity run -Engine gpu
```

Build both:

```powershell
vanity build -Engine all
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
- only emits private-key fields when `output.private_key_formats` is not `["none"]`
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

With the default `["none"]` setting, those private-key fields are omitted from JSONL output.

## Base58 rules

Solana addresses use Base58 and cannot contain:

- `0`
- `O`
- `I`
- lowercase `l`

## Troubleshooting

`vanity` command not found:

- Run `.\install.ps1`
- Open a new PowerShell window
- Or use `.\vanity.ps1 ...` directly from the repo root

`cargo` not found:

- Install Rust from [rustup.rs](https://rustup.rs/)
- Open a new PowerShell window
- Verify with `cargo --version`

`nvcc` not found:

- Install the [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads)
- Open a new PowerShell window
- Verify with `nvcc --version`

GPU build fails with compiler or SDK errors:

- Make sure Visual Studio Build Tools with C++ are installed
- Make sure `MSVC v143 - VS 2022 C++ x64/x86 build tools` is installed
- Make sure `Windows 11 SDK` is installed
- Run `vanity doctor` again after installation

`vanity doctor` recommends CPU even though you have an NVIDIA GPU:

- CPU mode still works and is the simplest fallback
- Check that CUDA Toolkit is installed
- Check that `nvcc --version` works in a new PowerShell window
- Re-run `vanity doctor`

`vanity smoke` finds nothing:

- This is normal
- `vanity smoke` is intentionally bounded and may complete without a match

GPU search is running too hard or you want to stop immediately:

- Run `vanity stop`
- If needed, stop leftover processes in Task Manager
- Prefer `vanity smoke` before `vanity run` when testing a new setup

Antivirus flags the GPU binary:

- Locally built unsigned CUDA binaries can trigger Windows antivirus heuristics
- Review the repo first
- If you trust it, allow or exclude only this project folder

Private keys are missing from results:

- This is the secure default
- `output.private_key_formats` defaults to `["none"]`
- Secret-bearing outputs are only written when you explicitly enable them

## Notes

- The GPU engine is much faster for broad vanity pools, but exact long targets are still expensive.
- The CPU engine is easier to set up and works without CUDA.
- The CUDA engine currently targets Windows + NVIDIA + CUDA Toolkit + Visual Studio Build Tools.
- The GPU scanner is derived from Apache-licensed CUDA Solana `ed25519` code in `vendor-solanity`.

## License

This project is licensed under `Apache-2.0`. See `LICENSE`.
