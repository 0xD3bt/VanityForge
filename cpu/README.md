# CPU Engine

This folder contains the Rust-based CPU engine and helper scripts.

Run commands from the repository root unless noted otherwise.

## Main files

- `build.ps1`: builds the CPU binary with `cargo build --release`
- `run.ps1`: runs the CPU engine using the shared repo config

## How it is configured

The CPU engine uses the shared repo config and pattern files:

- `vanity.config.json`
- `patterns/prefixes/*.txt`
- `patterns/suffixes/*.txt`

For local-only configs that should stay out of git, prefer `.local/configs/`.

## Recommended usage

Check your machine and set up the config:

```powershell
vanity doctor
vanity init
```

Build and run the CPU engine explicitly:

```powershell
vanity build -Engine cpu
vanity run -Engine cpu
```

Or run whatever engine is currently selected in the config:

```powershell
vanity run
```

## Direct scripts

Build only:

```powershell
powershell -ExecutionPolicy Bypass -File .\cpu\build.ps1
```

Run with a specific config:

```powershell
powershell -ExecutionPolicy Bypass -File .\cpu\run.ps1 -ConfigPath .local\configs\my-vanity.config.json
```

## Behavior notes

- `cpu.threads: 0` means auto-detect and use available CPU threads
- `cpu.max_attempts: 0` means unlimited attempts
- `cpu.keep_running: true` appends all matches to `output.results_file`
- `cpu.keep_running: false` stops on the first hit and writes companion output files based on `output.single_keypair_file`
- `output.write_match_files: true` also writes one set of files per match in `output.matches_dir`
- `output.private_key_formats` currently defaults to `["base58"]`, so result files should be treated as secret-bearing unless you switch to `["none"]`
