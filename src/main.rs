use std::{
    collections::HashSet,
    fs,
    fs::OpenOptions,
    io::Write,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use clap::{ArgAction, Parser};
use ed25519_dalek::SigningKey;
use rand::{RngCore, SeedableRng, rngs::SmallRng};

const BASE58_ALPHABET: &str = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

#[derive(Parser, Debug)]
#[command(author, version, about = "Multithreaded Solana vanity address generator")]
struct Cli {
    /// One or more exact case-sensitive prefixes. Supports repeats and comma-separated values.
    #[arg(long, value_delimiter = ',', action = ArgAction::Append)]
    prefix: Vec<String>,

    /// One or more exact case-sensitive suffixes. Supports repeats and comma-separated values.
    #[arg(long, value_delimiter = ',', action = ArgAction::Append)]
    suffix: Vec<String>,

    /// Number of worker threads to use.
    #[arg(long)]
    threads: Option<usize>,

    /// Status print interval in seconds.
    #[arg(long, default_value_t = 2)]
    report_every: u64,

    /// Stop after this many attempts instead of running forever.
    #[arg(long)]
    max_attempts: Option<u64>,

    /// Keep searching after a hit and save every match.
    #[arg(long, default_value_t = false)]
    keep_running: bool,

    /// JSONL file used when --keep-running is enabled.
    #[arg(long, default_value = "matches.jsonl")]
    results_file: PathBuf,

    /// Also write one keypair/pubkey file pair per match.
    #[arg(long, default_value_t = false)]
    write_match_files: bool,

    /// Private key output formats: none, base58, solana-json, seed-base58, seed-hex, or all.
    #[arg(long = "private-key-format", value_delimiter = ',', action = ArgAction::Append)]
    private_key_format: Vec<String>,

    /// Directory used to store per-match keypair files when --write-match-files is enabled.
    #[arg(long, default_value = "matches")]
    matches_dir: PathBuf,

    /// Output path for the Solana keypair JSON.
    #[arg(long, default_value = "vanity-keypair.json")]
    out: PathBuf,
}

#[derive(Debug, Clone)]
struct TargetFilters {
    prefixes: Vec<String>,
    suffixes: Vec<String>,
}

#[derive(Debug, Clone)]
struct MatchResult {
    address: String,
    keypair_bytes: Vec<u8>,
    attempts: u64,
    elapsed: Duration,
    matched_prefix: Option<String>,
    matched_suffix: Option<String>,
}

#[derive(Debug, Clone)]
struct KeyFormatSelection {
    base58: bool,
    solana_json: bool,
    seed_base58: bool,
    seed_hex: bool,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let filters = build_filters(&cli)?;
    validate_inputs(&cli, &filters)?;
    let key_formats = parse_key_formats(&cli.private_key_format)?;

    let threads = cli
        .threads
        .unwrap_or_else(|| thread::available_parallelism().map_or(1, usize::from));
    let report_every = Duration::from_secs(cli.report_every.max(1));

    println!("Prefixes      : {}", preview_fragments(&filters.prefixes));
    println!("Suffixes      : {}", preview_fragments(&filters.suffixes));
    println!("Threads       : {threads}");
    println!("Key formats   : {}", describe_key_formats(&key_formats));
    println!("Keep running  : {}", if cli.keep_running { "yes" } else { "no" });
    if cli.keep_running {
        println!("Results file  : {}", cli.results_file.display());
        println!(
            "Match files   : {}",
            if cli.write_match_files { "enabled" } else { "disabled" }
        );
        if cli.write_match_files {
            println!("Matches dir   : {}", cli.matches_dir.display());
        }
    } else {
        println!("Output        : {}", cli.out.display());
    }

    if let Some(chars) = shortest_constraint_len(&filters) {
        let expected_attempts = 58_f64.powi(chars as i32);
        println!("Fastest rule  : {chars} constrained chars");
        println!(
            "One rule avg  : about {} attempts",
            human_large_number(expected_attempts)
        );
        println!(
            "At 1M addr/s  : {} per single rule",
            format_runtime_from_attempts(expected_attempts, 1_000_000_f64)
        );
        println!(
            "At 10M addr/s : {} per single rule",
            format_runtime_from_attempts(expected_attempts, 10_000_000_f64)
        );
    }

    let average_attempts_estimate = estimate_average_attempts(&filters);

    println!();
    println!("Press Ctrl+C to stop.");

    let stop = Arc::new(AtomicBool::new(false));
    let attempts = Arc::new(AtomicU64::new(0));
    let matches_found = Arc::new(AtomicUsize::new(0));
    let start = Instant::now();

    let (sender, receiver) = std::sync::mpsc::channel::<MatchResult>();
    let mut handles = Vec::with_capacity(threads);

    for worker_id in 0..threads {
        let keep_running = cli.keep_running;
        let filters = filters.clone();
        let stop = Arc::clone(&stop);
        let attempts = Arc::clone(&attempts);
        let sender = sender.clone();
        let max_attempts = cli.max_attempts;

        handles.push(thread::spawn(move || {
            let mut seed = rand::thread_rng();
            let mut rng = SmallRng::from_rng(&mut seed).expect("failed to seed RNG");

            while !stop.load(Ordering::Relaxed) {
                let previous_attempts = attempts.fetch_add(1, Ordering::Relaxed);
                if let Some(limit) = max_attempts {
                    if previous_attempts >= limit {
                        attempts.fetch_sub(1, Ordering::Relaxed);
                        stop.store(true, Ordering::Relaxed);
                        break;
                    }
                }
                let current_attempt = previous_attempts + 1;

                let mut secret = [0_u8; 32];
                rng.fill_bytes(&mut secret);

                let signing_key = SigningKey::from_bytes(&secret);
                let verifying_key = signing_key.verifying_key();
                let address = bs58::encode(verifying_key.as_bytes()).into_string();

                if let Some((matched_prefix, matched_suffix)) = match_address(&address, &filters) {
                    let mut keypair_bytes = Vec::with_capacity(64);
                    keypair_bytes.extend_from_slice(&secret);
                    keypair_bytes.extend_from_slice(verifying_key.as_bytes());

                    let _ = sender.send(MatchResult {
                        address,
                        keypair_bytes,
                        attempts: current_attempt,
                        elapsed: start.elapsed(),
                        matched_prefix,
                        matched_suffix,
                    });

                    if !keep_running {
                        stop.store(true, Ordering::Relaxed);
                        break;
                    }
                }

                if worker_id == 0 && current_attempt % 8192 == 0 && stop.load(Ordering::Relaxed) {
                    break;
                }
            }
        }));
    }

    drop(sender);

    if cli.keep_running {
        prepare_keep_running_outputs(&cli)?;
    }

    let mut first_match: Option<MatchResult> = None;

    loop {
        match receiver.recv_timeout(report_every) {
            Ok(result) => {
                let match_index = matches_found.fetch_add(1, Ordering::Relaxed) + 1;
                if cli.keep_running {
                    append_match_artifacts(&cli, &result, match_index, &key_formats)?;
                    println!();
                    println!("Match #{match_index} found!");
                    println!("Address       : {}", result.address);
                    println!(
                        "Matched prefix: {}",
                        result.matched_prefix.as_deref().unwrap_or("<none>")
                    );
                    println!(
                        "Matched suffix: {}",
                        result.matched_suffix.as_deref().unwrap_or("<none>")
                    );
                    println!("Attempts      : {}", human_int(result.attempts));
                    println!(
                        "Elapsed       : {}",
                        format_duration_human(result.elapsed.as_secs_f64())
                    );
                } else {
                    first_match = Some(result);
                    break;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                let total = attempts.load(Ordering::Relaxed);
                let elapsed = start.elapsed();
                let rate = total as f64 / elapsed.as_secs_f64().max(0.001);
                let found = matches_found.load(Ordering::Relaxed);
                let eta_seconds = average_attempts_estimate / rate.max(1.0);

                println!(
                    "Progress      : Tried {} in {} at {} ({} matches) - ETA ~ {}/match",
                    human_int(total),
                    format_duration_human(elapsed.as_secs_f64()),
                    format_rate_human(rate),
                    human_int(found as u64),
                    format_duration_brief(eta_seconds)
                );

                if let Some(limit) = cli.max_attempts {
                    if total >= limit {
                        stop.store(true, Ordering::Relaxed);
                    }
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    stop.store(true, Ordering::Relaxed);

    for handle in handles {
        let _ = handle.join();
    }

    match first_match {
        Some(result) => {
            let written_paths = write_single_match_outputs(&cli.out, &result, &key_formats)?;
            println!();
            println!("Match found!");
            println!("Address       : {}", result.address);
            println!(
                "Matched prefix: {}",
                result.matched_prefix.as_deref().unwrap_or("<none>")
            );
            println!(
                "Matched suffix: {}",
                result.matched_suffix.as_deref().unwrap_or("<none>")
            );
            println!("Attempts      : {}", human_int(result.attempts));
            println!(
                "Elapsed       : {}",
                format_duration_human(result.elapsed.as_secs_f64())
            );
            print_written_paths(&written_paths);
        }
        None => {
            let total = attempts.load(Ordering::Relaxed);
            let elapsed = start.elapsed();
            let found = matches_found.load(Ordering::Relaxed);
            if cli.keep_running && found > 0 {
                println!();
                println!("Finished with {} matches.", human_int(found as u64));
                println!("Results file  : {}", cli.results_file.display());
                if cli.write_match_files {
                    println!("Matches dir   : {}", cli.matches_dir.display());
                }
            } else {
                bail!(
                    "No match found after {} attempts in {}",
                    human_int(total),
                    format_duration_human(elapsed.as_secs_f64())
                );
            }
        }
    }

    Ok(())
}

fn build_filters(cli: &Cli) -> Result<TargetFilters> {
    let prefixes = normalize_fragments(cli.prefix.clone());
    let suffixes = normalize_fragments(cli.suffix.clone());

    for prefix in &prefixes {
        validate_fragment("prefix", prefix)?;
    }
    for suffix in &suffixes {
        validate_fragment("suffix", suffix)?;
    }

    Ok(TargetFilters { prefixes, suffixes })
}

fn validate_inputs(cli: &Cli, filters: &TargetFilters) -> Result<()> {
    if filters.prefixes.is_empty() && filters.suffixes.is_empty() {
        bail!("Provide at least one of --prefix or --suffix");
    }

    if cli.report_every == 0 {
        bail!("--report-every must be at least 1 second");
    }

    if let Some(threads) = cli.threads {
        if threads == 0 {
            bail!("--threads must be at least 1");
        }
    }

    if cli.keep_running && cli.results_file.as_os_str().is_empty() {
        bail!("--results-file must not be empty");
    }

    if cli.keep_running && cli.write_match_files && cli.matches_dir.as_os_str().is_empty() {
        bail!("--matches-dir must not be empty");
    }

    parse_key_formats(&cli.private_key_format)?;

    Ok(())
}

fn validate_fragment(label: &str, value: &str) -> Result<()> {
    for ch in value.chars() {
        if !BASE58_ALPHABET.contains(ch) {
            bail!(
                "{label} contains invalid Base58 character '{ch}'. Solana addresses cannot contain 0, O, I, or lowercase l."
            );
        }
    }

    Ok(())
}

fn match_address(address: &str, filters: &TargetFilters) -> Option<(Option<String>, Option<String>)> {
    let matched_prefix = if filters.prefixes.is_empty() {
        None
    } else {
        Some(
            filters
                .prefixes
                .iter()
                .find(|prefix| address.starts_with(prefix.as_str()))?
                .clone(),
        )
    };

    let matched_suffix = if filters.suffixes.is_empty() {
        None
    } else {
        Some(
            filters
                .suffixes
                .iter()
                .find(|suffix| address.ends_with(suffix.as_str()))?
                .clone(),
        )
    };

    Some((matched_prefix, matched_suffix))
}

fn normalize_fragments(fragments: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();

    for fragment in fragments {
        if fragment.is_empty() {
            continue;
        }

        if seen.insert(fragment.clone()) {
            out.push(fragment);
        }
    }

    out.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
    out
}

fn shortest_constraint_len(filters: &TargetFilters) -> Option<usize> {
    if filters.prefixes.is_empty() && filters.suffixes.is_empty() {
        return None;
    }

    let prefix_len = filters.prefixes.iter().map(String::len).min().unwrap_or(0);
    let suffix_len = filters.suffixes.iter().map(String::len).min().unwrap_or(0);
    Some(prefix_len + suffix_len)
}

fn estimate_average_attempts(filters: &TargetFilters) -> f64 {
    let effective_prefixes = minimize_prefix_patterns(&filters.prefixes);
    let effective_suffixes = minimize_suffix_patterns(&filters.suffixes);
    let prefix_probability = pattern_probability(&effective_prefixes);
    let suffix_probability = pattern_probability(&effective_suffixes);
    let combined_probability = prefix_probability * suffix_probability;

    if combined_probability > 0.0 {
        1.0 / combined_probability
    } else {
        f64::INFINITY
    }
}

fn minimize_prefix_patterns(patterns: &[String]) -> Vec<String> {
    let mut sorted = patterns.to_vec();
    sorted.sort_by(|a, b| a.len().cmp(&b.len()).then_with(|| a.cmp(b)));

    let mut minimized = Vec::new();
    'outer: for pattern in sorted {
        for existing in &minimized {
            if pattern.starts_with(existing) {
                continue 'outer;
            }
        }
        minimized.push(pattern);
    }

    minimized
}

fn minimize_suffix_patterns(patterns: &[String]) -> Vec<String> {
    let mut sorted = patterns.to_vec();
    sorted.sort_by(|a, b| a.len().cmp(&b.len()).then_with(|| a.cmp(b)));

    let mut minimized = Vec::new();
    'outer: for pattern in sorted {
        for existing in &minimized {
            if pattern.ends_with(existing) {
                continue 'outer;
            }
        }
        minimized.push(pattern);
    }

    minimized
}

fn pattern_probability(patterns: &[String]) -> f64 {
    if patterns.is_empty() {
        return 1.0;
    }

    patterns
        .iter()
        .map(|pattern| 58_f64.powi(-(pattern.len() as i32)))
        .sum()
}

fn preview_fragments(fragments: &[String]) -> String {
    if fragments.is_empty() {
        return "<none>".to_string();
    }

    if fragments.len() <= 6 {
        return fragments.join(", ");
    }

    let preview = fragments
        .iter()
        .take(4)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join(", ");
    format!("{preview}, ... (+{} more)", fragments.len() - 4)
}

fn prepare_keep_running_outputs(cli: &Cli) -> Result<()> {
    if let Some(parent) = cli.results_file.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
    }

    if cli.write_match_files {
        fs::create_dir_all(&cli.matches_dir)
            .with_context(|| format!("failed to create {}", cli.matches_dir.display()))?;
    }

    Ok(())
}

fn append_match_artifacts(
    cli: &Cli,
    result: &MatchResult,
    match_index: usize,
    key_formats: &KeyFormatSelection,
) -> Result<()> {
    let written_paths = if cli.write_match_files {
        let stem = format!("match-{match_index:06}");
        write_named_match_outputs(&cli.matches_dir, &stem, result, key_formats)?
    } else {
        WrittenPaths::default()
    };

    let line = make_result_json(match_index, result, key_formats, Some(&written_paths));

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&cli.results_file)
        .with_context(|| format!("failed to open {}", cli.results_file.display()))?;
    writeln!(file, "{line}")
        .with_context(|| format!("failed to append {}", cli.results_file.display()))?;
    Ok(())
}

#[derive(Debug, Default, Clone)]
struct WrittenPaths {
    pubkey_path: Option<String>,
    solana_json_path: Option<String>,
    private_key_base58_path: Option<String>,
    secret_seed_base58_path: Option<String>,
    seed_hex_path: Option<String>,
}

fn write_single_match_outputs(
    out_path: &PathBuf,
    result: &MatchResult,
    key_formats: &KeyFormatSelection,
) -> Result<WrittenPaths> {
    let mut paths = WrittenPaths::default();

    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
    }

    let pubkey_path = pubkey_path(out_path);
    fs::write(&pubkey_path, format!("{}\n", result.address))
        .with_context(|| format!("failed to write {}", pubkey_path.display()))?;
    paths.pubkey_path = Some(pubkey_path.display().to_string());

    if key_formats.solana_json {
        let keypair_json =
            serde_json::to_string_pretty(&result.keypair_bytes).context("failed to serialize keypair")?;
        fs::write(out_path, keypair_json)
            .with_context(|| format!("failed to write {}", out_path.display()))?;
        paths.solana_json_path = Some(out_path.display().to_string());
    }

    if key_formats.base58 {
        let path = base58_path(out_path);
        fs::write(&path, format!("{}\n", keypair_base58(&result.keypair_bytes)))
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.private_key_base58_path = Some(path.display().to_string());
    }

    if key_formats.seed_base58 {
        let path = seed_base58_path(out_path);
        fs::write(&path, format!("{}\n", secret_seed_base58(&result.keypair_bytes)))
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.secret_seed_base58_path = Some(path.display().to_string());
    }

    if key_formats.seed_hex {
        let path = seed_hex_path(out_path);
        fs::write(&path, format!("{}\n", seed_hex(&result.keypair_bytes)))
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.seed_hex_path = Some(path.display().to_string());
    }

    Ok(paths)
}

fn write_named_match_outputs(
    matches_dir: &PathBuf,
    stem: &str,
    result: &MatchResult,
    key_formats: &KeyFormatSelection,
) -> Result<WrittenPaths> {
    let mut paths = WrittenPaths::default();

    let pubkey_path = matches_dir.join(format!("{stem}.pubkey.txt"));
    fs::write(&pubkey_path, format!("{}\n", result.address))
        .with_context(|| format!("failed to write {}", pubkey_path.display()))?;
    paths.pubkey_path = Some(pubkey_path.display().to_string());

    if key_formats.solana_json {
        let path = matches_dir.join(format!("{stem}.solana.json"));
        let keypair_json =
            serde_json::to_string_pretty(&result.keypair_bytes).context("failed to serialize keypair")?;
        fs::write(&path, keypair_json)
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.solana_json_path = Some(path.display().to_string());
    }

    if key_formats.base58 {
        let path = matches_dir.join(format!("{stem}.base58.txt"));
        fs::write(&path, format!("{}\n", keypair_base58(&result.keypair_bytes)))
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.private_key_base58_path = Some(path.display().to_string());
    }

    if key_formats.seed_base58 {
        let path = matches_dir.join(format!("{stem}.seed.base58.txt"));
        fs::write(&path, format!("{}\n", secret_seed_base58(&result.keypair_bytes)))
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.secret_seed_base58_path = Some(path.display().to_string());
    }

    if key_formats.seed_hex {
        let path = matches_dir.join(format!("{stem}.seed.hex.txt"));
        fs::write(&path, format!("{}\n", seed_hex(&result.keypair_bytes)))
            .with_context(|| format!("failed to write {}", path.display()))?;
        paths.seed_hex_path = Some(path.display().to_string());
    }

    Ok(paths)
}

fn make_result_json(
    index: usize,
    result: &MatchResult,
    key_formats: &KeyFormatSelection,
    written_paths: Option<&WrittenPaths>,
) -> serde_json::Value {
    let mut obj = serde_json::Map::new();
    obj.insert("index".to_string(), serde_json::json!(index));
    obj.insert("address".to_string(), serde_json::json!(result.address));
    obj.insert("matched_prefix".to_string(), serde_json::json!(result.matched_prefix));
    obj.insert("matched_suffix".to_string(), serde_json::json!(result.matched_suffix));
    obj.insert("attempts".to_string(), serde_json::json!(result.attempts));
    obj.insert(
        "elapsed_seconds".to_string(),
        serde_json::json!(result.elapsed.as_secs_f64()),
    );

    if key_formats.base58 {
        obj.insert(
            "private_key_base58".to_string(),
            serde_json::json!(keypair_base58(&result.keypair_bytes)),
        );
    }
    if key_formats.solana_json {
        obj.insert(
            "solana_keypair_bytes".to_string(),
            serde_json::json!(result.keypair_bytes),
        );
    }
    if key_formats.seed_base58 {
        obj.insert(
            "secret_seed_base58".to_string(),
            serde_json::json!(secret_seed_base58(&result.keypair_bytes)),
        );
    }
    if key_formats.seed_hex {
        obj.insert(
            "seed_hex".to_string(),
            serde_json::json!(seed_hex(&result.keypair_bytes)),
        );
    }

    let paths = written_paths.cloned().unwrap_or_default();
    obj.insert("pubkey_path".to_string(), serde_json::json!(paths.pubkey_path));
    obj.insert(
        "solana_json_path".to_string(),
        serde_json::json!(paths.solana_json_path),
    );
    obj.insert(
        "private_key_base58_path".to_string(),
        serde_json::json!(paths.private_key_base58_path),
    );
    obj.insert(
        "secret_seed_base58_path".to_string(),
        serde_json::json!(paths.secret_seed_base58_path),
    );
    obj.insert("seed_hex_path".to_string(), serde_json::json!(paths.seed_hex_path));

    serde_json::Value::Object(obj)
}

fn pubkey_path(out_path: &PathBuf) -> PathBuf {
    let stem = out_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("vanity-keypair");
    let parent = out_path.parent().map(PathBuf::from).unwrap_or_default();
    parent.join(format!("{stem}.pubkey.txt"))
}

fn base58_path(out_path: &PathBuf) -> PathBuf {
    let stem = out_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("vanity-keypair");
    let parent = out_path.parent().map(PathBuf::from).unwrap_or_default();
    parent.join(format!("{stem}.base58.txt"))
}

fn seed_base58_path(out_path: &PathBuf) -> PathBuf {
    let stem = out_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("vanity-keypair");
    let parent = out_path.parent().map(PathBuf::from).unwrap_or_default();
    parent.join(format!("{stem}.seed.base58.txt"))
}

fn seed_hex_path(out_path: &PathBuf) -> PathBuf {
    let stem = out_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("vanity-keypair");
    let parent = out_path.parent().map(PathBuf::from).unwrap_or_default();
    parent.join(format!("{stem}.seed.hex.txt"))
}

fn keypair_base58(keypair_bytes: &[u8]) -> String {
    bs58::encode(keypair_bytes).into_string()
}

fn secret_seed_base58(keypair_bytes: &[u8]) -> String {
    let secret = keypair_bytes.get(..32).unwrap_or(keypair_bytes);
    bs58::encode(secret).into_string()
}

fn seed_hex(keypair_bytes: &[u8]) -> String {
    let secret = keypair_bytes.get(..32).unwrap_or(keypair_bytes);
    let mut out = String::with_capacity(secret.len() * 2);
    for byte in secret {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn parse_key_formats(values: &[String]) -> Result<KeyFormatSelection> {
    let defaults = vec!["base58".to_string()];
    let values = if values.is_empty() { &defaults } else { values };

    let mut selection = KeyFormatSelection {
        base58: false,
        solana_json: false,
        seed_base58: false,
        seed_hex: false,
    };

    for value in values {
        match value.as_str() {
            "none" => {}
            "base58" => selection.base58 = true,
            "solana-json" => selection.solana_json = true,
            "seed-base58" => selection.seed_base58 = true,
            "seed-hex" => selection.seed_hex = true,
            "all" => {
                selection.base58 = true;
                selection.solana_json = true;
                selection.seed_base58 = true;
                selection.seed_hex = true;
            }
            other => bail!(
                "Unknown private key format '{other}'. Use none, base58, solana-json, seed-base58, seed-hex, or all."
            ),
        }
    }

    Ok(selection)
}

fn describe_key_formats(selection: &KeyFormatSelection) -> String {
    let mut parts = Vec::new();
    if selection.base58 {
        parts.push("base58");
    }
    if selection.solana_json {
        parts.push("solana-json");
    }
    if selection.seed_base58 {
        parts.push("seed-base58");
    }
    if selection.seed_hex {
        parts.push("seed-hex");
    }
    if parts.is_empty() {
        "none".to_string()
    } else {
        parts.join(", ")
    }
}

fn print_written_paths(paths: &WrittenPaths) {
    if let Some(path) = &paths.pubkey_path {
        println!("Pubkey file   : {path}");
    }
    if let Some(path) = &paths.solana_json_path {
        println!("Solana JSON   : {path}");
    }
    if let Some(path) = &paths.private_key_base58_path {
        println!("Base58 file   : {path}");
    }
    if let Some(path) = &paths.secret_seed_base58_path {
        println!("Seed Base58   : {path}");
    }
    if let Some(path) = &paths.seed_hex_path {
        println!("Seed hex file : {path}");
    }
}

fn human_int(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);

    for (idx, ch) in digits.chars().enumerate() {
        if idx > 0 && (digits.len() - idx).is_multiple_of(3) {
            out.push('_');
        }
        out.push(ch);
    }

    out
}

fn human_large_number(value: f64) -> String {
    const SUFFIXES: [&str; 7] = ["", "K", "M", "B", "T", "Q", "QQ"];

    if !value.is_finite() {
        return "effectively infinite".to_string();
    }

    let mut scaled = value;
    let mut idx = 0;
    while scaled >= 1000.0 && idx < SUFFIXES.len() - 1 {
        scaled /= 1000.0;
        idx += 1;
    }

    if idx == 0 {
        format!("{scaled:.0}")
    } else {
        format!("{scaled:.2}{}", SUFFIXES[idx])
    }
}

fn format_runtime_from_attempts(attempts: f64, rate_per_second: f64) -> String {
    let seconds = attempts / rate_per_second;
    if !seconds.is_finite() || seconds > 1.0e20 {
        return "effectively forever".to_string();
    }

    format_duration_human(seconds)
}

fn format_duration_human(seconds: f64) -> String {
    if seconds < 60.0 {
        return format!("{seconds:.1}s");
    }
    if seconds < 3600.0 {
        return format!("{:.1}m", seconds / 60.0);
    }
    if seconds < 86_400.0 {
        return format!("{:.1}h", seconds / 3600.0);
    }
    if seconds < 31_557_600.0 {
        return format!("{:.1}d", seconds / 86_400.0);
    }

    format!("{:.1}y", seconds / 31_557_600.0)
}

fn format_duration_brief(seconds: f64) -> String {
    if !seconds.is_finite() {
        return "unknown".to_string();
    }
    if seconds < 1.0 {
        return "<1s".to_string();
    }
    if seconds < 60.0 {
        return format!("{seconds:.0}s");
    }
    if seconds < 3600.0 {
        return format!("{:.1}m", seconds / 60.0);
    }
    if seconds < 86_400.0 {
        return format!("{:.1}h", seconds / 3600.0);
    }

    format!("{:.1}d", seconds / 86_400.0)
}

fn format_rate_human(rate: f64) -> String {
    if rate >= 1_000_000_000.0 {
        return format!("{:.2} G addr/s", rate / 1_000_000_000.0);
    }
    if rate >= 1_000_000.0 {
        return format!("{:.2} M addr/s", rate / 1_000_000.0);
    }
    if rate >= 1_000.0 {
        return format!("{:.2} K addr/s", rate / 1_000.0);
    }

    format!("{:.0} addr/s", rate)
}
