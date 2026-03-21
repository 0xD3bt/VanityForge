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

use anyhow::{Context, Result, anyhow, bail};
use clap::{ArgAction, Parser};
use ed25519_dalek::SigningKey;
use rand::{RngCore, SeedableRng, rngs::SmallRng};

const BASE58_ALPHABET: &str = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const AESTHETIC_MIN_SIDE_LEN: usize = 5;
const MIRRORED_AESTHETIC_WORDS: [&str; 2] = ["pumpfun", "solana"];

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

    /// JSONL file used for aesthetic keep-running matches.
    #[arg(long, default_value = "private/aesthetic-matches.jsonl")]
    aesthetic_results_file: PathBuf,

    /// Also write one keypair/pubkey file pair per match.
    #[arg(long, default_value_t = false)]
    write_match_files: bool,

    /// Private key output formats: none, base58, solana-json, seed-base58, seed-hex, or all.
    #[arg(long = "private-key-format", value_delimiter = ',', action = ArgAction::Append)]
    private_key_format: Vec<String>,

    /// Directory used to store per-match keypair files when --write-match-files is enabled.
    #[arg(long, default_value = "matches")]
    matches_dir: PathBuf,

    /// Only persist keep-running matches whose matched prefix+suffix length is at least this total.
    #[arg(long, default_value_t = 0)]
    min_total_matched_chars: usize,

    /// Output path for the Solana keypair JSON.
    #[arg(long, default_value = "vanity-keypair.json")]
    out: PathBuf,

    /// Optional config file path used to load grouped prefix/suffix rule pairs.
    #[arg(long)]
    grouped_rules_config: Option<PathBuf>,
}

#[derive(Debug, Clone)]
struct TargetFilters {
    prefixes: Vec<String>,
    suffixes: Vec<String>,
    grouped_rules: Vec<RuleGroup>,
}

#[derive(Debug, Clone)]
struct RuleGroup {
    prefixes: Vec<String>,
    suffixes: Vec<String>,
}

#[derive(Debug, Clone)]
struct MatchResult {
    address: String,
    keypair_bytes: Vec<u8>,
    attempts: u64,
    elapsed: Duration,
    match_type: String,
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
        println!("Listed file   : {}", cli.results_file.display());
        if cli.min_total_matched_chars > 0 {
            println!("Aesthetic file: {}", cli.aesthetic_results_file.display());
        }
        println!(
            "Match files   : {}",
            if cli.write_match_files { "enabled" } else { "disabled" }
        );
        if cli.write_match_files {
            println!("Matches dir   : {}", cli.matches_dir.display());
        }
        println!("Save policy   : listed targets always saved");
        if cli.min_total_matched_chars > 0 {
            println!(
                "Aesthetic     : on  | each side >= {} | total >= {}",
                AESTHETIC_MIN_SIDE_LEN,
                cli.min_total_matched_chars
            );
        } else {
            println!("Aesthetic     : off");
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
    let avg_label = if cli.keep_running && cli.min_total_matched_chars > 0 {
        "avg listed/match"
    } else {
        "avg match"
    };

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
        let extra_min_total = if keep_running {
            cli.min_total_matched_chars
        } else {
            0
        };
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

                if let Some((match_type, matched_prefix, matched_suffix)) =
                    match_address(&address, &filters, extra_min_total)
                {
                    let mut keypair_bytes = Vec::with_capacity(64);
                    keypair_bytes.extend_from_slice(&secret);
                    keypair_bytes.extend_from_slice(verifying_key.as_bytes());

                    let _ = sender.send(MatchResult {
                        address,
                        keypair_bytes,
                        attempts: current_attempt,
                        elapsed: start.elapsed(),
                        match_type,
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
                    if should_persist_match(&cli, &filters, &result) {
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
                    }
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
                let avg_seconds = average_attempts_estimate / rate.max(1.0);

                println!(
                    "Progress      : total {} | elapsed {} | {} | matches {} | {} {}",
                    format_count_human(total),
                    format_duration_brief(elapsed.as_secs_f64()),
                    format_rate_human(rate),
                    human_int(found as u64),
                    avg_label,
                    format_duration_brief(avg_seconds)
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
                println!("Listed file   : {}", cli.results_file.display());
                if cli.min_total_matched_chars > 0 {
                    println!("Aesthetic file: {}", cli.aesthetic_results_file.display());
                }
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
    if let Some(config_path) = &cli.grouped_rules_config {
        if !cli.prefix.is_empty() || !cli.suffix.is_empty() {
            bail!("Do not combine grouped rule config with --prefix or --suffix");
        }
        return load_grouped_rules_from_config(config_path);
    }

    let prefixes = normalize_fragments(cli.prefix.clone());
    let suffixes = normalize_fragments(cli.suffix.clone());

    for prefix in &prefixes {
        validate_fragment("prefix", prefix)?;
    }
    for suffix in &suffixes {
        validate_fragment("suffix", suffix)?;
    }

    Ok(TargetFilters {
        prefixes,
        suffixes,
        grouped_rules: Vec::new(),
    })
}

fn validate_inputs(cli: &Cli, filters: &TargetFilters) -> Result<()> {
    if filters.grouped_rules.is_empty() && filters.prefixes.is_empty() && filters.suffixes.is_empty() {
        bail!("Provide at least one of --prefix or --suffix, or use --grouped-rules-config");
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

    if cli.keep_running && cli.aesthetic_results_file.as_os_str().is_empty() {
        bail!("--aesthetic-results-file must not be empty");
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

fn match_listed_address(address: &str, filters: &TargetFilters) -> Option<(Option<String>, Option<String>)> {
    if !filters.grouped_rules.is_empty() {
        for rule in &filters.grouped_rules {
            let matched_prefix = if rule.prefixes.is_empty() {
                None
            } else {
                match rule
                    .prefixes
                    .iter()
                    .find(|prefix| address.starts_with(prefix.as_str()))
                {
                    Some(prefix) => Some(prefix.clone()),
                    None => continue,
                }
            };

            let matched_suffix = if rule.suffixes.is_empty() {
                None
            } else {
                match rule
                    .suffixes
                    .iter()
                    .find(|suffix| address.ends_with(suffix.as_str()))
                {
                    Some(suffix) => Some(suffix.clone()),
                    None => continue,
                }
            };

            return Some((matched_prefix, matched_suffix));
        }

        return None;
    }

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

fn normalized_aesthetic_byte(byte: u8) -> u8 {
    if byte.is_ascii_alphabetic() {
        byte.to_ascii_lowercase()
    } else {
        byte
    }
}

fn is_ascii_alpha(byte: u8) -> bool {
    normalized_aesthetic_byte(byte).is_ascii_lowercase()
}

fn repeated_run_len(bytes: &[u8]) -> usize {
    if bytes.is_empty() {
        return 0;
    }

    let first = normalized_aesthetic_byte(bytes[0]);
    bytes.iter()
        .take_while(|byte| normalized_aesthetic_byte(**byte) == first)
        .count()
}

fn alternating_digit_run_len(bytes: &[u8]) -> usize {
    if bytes.len() < 2 {
        return 0;
    }

    if !bytes[0].is_ascii_digit() || !bytes[1].is_ascii_digit() {
        return 0;
    }

    let first = bytes[0];
    let second = bytes[1];
    if first == second {
        return 0;
    }

    let mut len = 2;
    while len < bytes.len() {
        let expected = if len % 2 == 0 { first } else { second };
        if normalized_aesthetic_byte(bytes[len]) != expected {
            break;
        }
        len += 1;
    }

    len
}

fn alternating_alpha_run_len(bytes: &[u8]) -> usize {
    if bytes.len() < 2 {
        return 0;
    }

    if !is_ascii_alpha(bytes[0]) || !is_ascii_alpha(bytes[1]) {
        return 0;
    }

    let first = normalized_aesthetic_byte(bytes[0]);
    let second = normalized_aesthetic_byte(bytes[1]);
    if first == second {
        return 0;
    }

    let mut len = 2;
    while len < bytes.len() {
        let expected = if len % 2 == 0 { first } else { second };
        if !is_ascii_alpha(bytes[len]) || normalized_aesthetic_byte(bytes[len]) != expected {
            break;
        }
        len += 1;
    }

    len
}

fn arithmetic_digit_run_len(bytes: &[u8]) -> usize {
    if bytes.is_empty() || !bytes[0].is_ascii_digit() {
        return 0;
    }

    let mut best = 1;
    for step in [1_i16, -1, 2, -2] {
        let mut len = 1;
        while len < bytes.len() {
            if !bytes[len].is_ascii_digit() {
                break;
            }

            let previous = i16::from(bytes[len - 1] - b'0');
            let current = i16::from(bytes[len] - b'0');
            if current != previous + step {
                break;
            }
            len += 1;
        }
        best = best.max(len);
    }

    best
}

fn sequential_alpha_run_len(bytes: &[u8]) -> usize {
    if bytes.is_empty() || !bytes[0].is_ascii_alphabetic() {
        return 0;
    }

    let mut asc = 1;
    while asc < bytes.len()
        && bytes[asc].is_ascii_alphabetic()
        && normalized_aesthetic_byte(bytes[asc])
            == normalized_aesthetic_byte(bytes[asc - 1]).saturating_add(1)
    {
        asc += 1;
    }

    let mut desc = 1;
    while desc < bytes.len()
        && bytes[desc].is_ascii_alphabetic()
        && normalized_aesthetic_byte(bytes[desc])
            == normalized_aesthetic_byte(bytes[desc - 1]).saturating_sub(1)
    {
        desc += 1;
    }

    asc.max(desc)
}

fn repeated_chunk_run_len(bytes: &[u8]) -> usize {
    if bytes.len() < 4 {
        return 0;
    }

    let mut best = 0;
    for chunk_len in 2..=(bytes.len() / 2) {
        let mut len = chunk_len;
        while len < bytes.len() {
            let expected =
                normalized_aesthetic_byte(bytes[len % chunk_len]);
            if normalized_aesthetic_byte(bytes[len]) != expected {
                break;
            }
            len += 1;
        }

        if len >= chunk_len * 2 {
            best = best.max(len);
        }
    }

    best
}

fn edge_slices_match_exact(address: &str, prefix_len: usize, suffix_len: usize) -> bool {
    if prefix_len == 0 || prefix_len != suffix_len || address.len() < prefix_len + suffix_len {
        return false;
    }

    address.as_bytes()[..prefix_len] == address.as_bytes()[address.len() - suffix_len..]
}

fn edge_slices_match_word_case_insensitive(address: &str, word: &str) -> bool {
    let bytes = address.as_bytes();
    let word_bytes = word.as_bytes();
    if bytes.len() < word_bytes.len() * 2 {
        return false;
    }

    bytes[..word_bytes.len()]
        .iter()
        .zip(word_bytes.iter())
        .all(|(left, expected)| normalized_aesthetic_byte(*left) == *expected)
        && bytes[bytes.len() - word_bytes.len()..]
            .iter()
            .zip(word_bytes.iter())
            .all(|(right, expected)| normalized_aesthetic_byte(*right) == *expected)
}

fn mirrored_curated_word_match(
    address: &str,
    min_total_chars: usize,
) -> Option<(Option<String>, Option<String>)> {
    for word in MIRRORED_AESTHETIC_WORDS {
        if word.len() * 2 >= min_total_chars && edge_slices_match_word_case_insensitive(address, word) {
            let prefix = address[..word.len()].to_string();
            let suffix = address[address.len() - word.len()..].to_string();
            return Some((Some(prefix), Some(suffix)));
        }
    }

    None
}

fn keyboard_run_len(bytes: &[u8]) -> usize {
    if bytes.is_empty() || !is_ascii_alpha(bytes[0]) {
        return 0;
    }

    const KEYBOARD_ROWS: [&[u8]; 6] = [
        b"qwertyuiop",
        b"poiuytrewq",
        b"asdfghjkl",
        b"lkjhgfdsa",
        b"zxcvbnm",
        b"mnbvcxz",
    ];

    let mut best = 0;
    for row in KEYBOARD_ROWS {
        if let Some(start) = row
            .iter()
            .position(|ch| *ch == normalized_aesthetic_byte(bytes[0]))
        {
            let mut len = 1;
            while start + len < row.len()
                && len < bytes.len()
                && is_ascii_alpha(bytes[len])
                && normalized_aesthetic_byte(bytes[len]) == row[start + len]
            {
                len += 1;
            }
            best = best.max(len);
        }
    }

    best
}

fn paired_digit_stair_run_len(bytes: &[u8]) -> usize {
    if bytes.len() < 6 || !bytes[0].is_ascii_digit() || bytes[0] != bytes[1] {
        return 0;
    }

    let mut best = 0;
    for step in [1_i16, -1, 2, -2] {
        let mut pairs = 1;
        while pairs * 2 < bytes.len() {
            let idx = pairs * 2;
            if idx + 1 >= bytes.len()
                || !bytes[idx].is_ascii_digit()
                || !bytes[idx + 1].is_ascii_digit()
                || bytes[idx] != bytes[idx + 1]
            {
                break;
            }

            let previous = i16::from(bytes[idx - 2] - b'0');
            let current = i16::from(bytes[idx] - b'0');
            if current != previous + step {
                break;
            }

            pairs += 1;
        }

        if pairs >= 2 {
            best = best.max(pairs * 2);
        }
    }

    best
}

fn best_aesthetic_run_len(bytes: &[u8]) -> usize {
    repeated_run_len(bytes)
        .max(alternating_digit_run_len(bytes))
        .max(arithmetic_digit_run_len(bytes))
        .max(sequential_alpha_run_len(bytes))
        .max(keyboard_run_len(bytes))
        .max(paired_digit_stair_run_len(bytes))
}

fn best_aesthetic_prefix_len(address: &str) -> usize {
    best_aesthetic_run_len(address.as_bytes())
}

fn aesthetic_match(address: &str, min_total_chars: usize) -> Option<(Option<String>, Option<String>)> {
    if min_total_chars == 0 {
        return None;
    }

    let bytes = address.as_bytes();
    let reversed = bytes.iter().rev().copied().collect::<Vec<_>>();

    // Lane 1: mirrored exact-fragment specials that are rarer than the generic fallback.
    let alpha_alt_prefix_len = alternating_alpha_run_len(bytes);
    let alpha_alt_suffix_len = alternating_alpha_run_len(&reversed);
    if alpha_alt_prefix_len >= AESTHETIC_MIN_SIDE_LEN
        && alpha_alt_suffix_len >= AESTHETIC_MIN_SIDE_LEN
        && edge_slices_match_exact(address, alpha_alt_prefix_len, alpha_alt_suffix_len)
        && alpha_alt_prefix_len + alpha_alt_suffix_len >= min_total_chars
    {
        let prefix = address[..alpha_alt_prefix_len].to_string();
        let suffix = address[address.len() - alpha_alt_suffix_len..].to_string();
        return Some((Some(prefix), Some(suffix)));
    }

    let repeated_chunk_prefix_len = repeated_chunk_run_len(bytes);
    let repeated_chunk_suffix_len = repeated_chunk_run_len(&reversed);
    if repeated_chunk_prefix_len >= AESTHETIC_MIN_SIDE_LEN
        && repeated_chunk_suffix_len >= AESTHETIC_MIN_SIDE_LEN
        && edge_slices_match_exact(address, repeated_chunk_prefix_len, repeated_chunk_suffix_len)
        && repeated_chunk_prefix_len + repeated_chunk_suffix_len >= min_total_chars
    {
        let prefix = address[..repeated_chunk_prefix_len].to_string();
        let suffix = address[address.len() - repeated_chunk_suffix_len..].to_string();
        return Some((Some(prefix), Some(suffix)));
    }

    // Lane 2: curated mirrored words, matched case-insensitively on both sides.
    if let Some(result) = mirrored_curated_word_match(address, min_total_chars) {
        return Some(result);
    }

    // Lane 3: generic aesthetic fallback.
    let prefix_len = best_aesthetic_prefix_len(address);
    let suffix_len = best_aesthetic_run_len(&reversed);
    if prefix_len < AESTHETIC_MIN_SIDE_LEN || suffix_len < AESTHETIC_MIN_SIDE_LEN {
        return None;
    }
    if prefix_len + suffix_len < min_total_chars {
        return None;
    }

    let prefix = address[..prefix_len].to_string();
    let suffix = address[address.len() - suffix_len..].to_string();
    Some((Some(prefix), Some(suffix)))
}

fn match_address(
    address: &str,
    filters: &TargetFilters,
    extra_min_total_chars: usize,
) -> Option<(String, Option<String>, Option<String>)> {
    if let Some(listed_match) = match_listed_address(address, filters) {
        return Some(("listed".to_string(), listed_match.0, listed_match.1));
    }

    aesthetic_match(address, extra_min_total_chars)
        .map(|(matched_prefix, matched_suffix)| ("aesthetic".to_string(), matched_prefix, matched_suffix))
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
    if !filters.grouped_rules.is_empty() {
        return filters
            .grouped_rules
            .iter()
            .filter_map(|rule| {
                if rule.prefixes.is_empty() && rule.suffixes.is_empty() {
                    return None;
                }
                let prefix_len = rule.prefixes.iter().map(String::len).min().unwrap_or(0);
                let suffix_len = rule.suffixes.iter().map(String::len).min().unwrap_or(0);
                Some(prefix_len + suffix_len)
            })
            .min();
    }

    if filters.prefixes.is_empty() && filters.suffixes.is_empty() {
        return None;
    }

    let prefix_len = filters.prefixes.iter().map(String::len).min().unwrap_or(0);
    let suffix_len = filters.suffixes.iter().map(String::len).min().unwrap_or(0);
    Some(prefix_len + suffix_len)
}

fn estimate_average_attempts(filters: &TargetFilters) -> f64 {
    if !filters.grouped_rules.is_empty() {
        let combined_probability: f64 = filters
            .grouped_rules
            .iter()
            .map(|rule| {
                let effective_prefixes = minimize_prefix_patterns(&rule.prefixes);
                let effective_suffixes = minimize_suffix_patterns(&rule.suffixes);
                pattern_probability(&effective_prefixes) * pattern_probability(&effective_suffixes)
            })
            .sum();

        if combined_probability > 0.0 {
            return 1.0 / combined_probability;
        }

        return f64::INFINITY;
    }

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

    let mut minimized: Vec<String> = Vec::new();
    'outer: for pattern in sorted {
        for existing in &minimized {
            if pattern.starts_with(existing.as_str()) {
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

    let mut minimized: Vec<String> = Vec::new();
    'outer: for pattern in sorted {
        for existing in &minimized {
            if pattern.ends_with(existing.as_str()) {
                continue 'outer;
            }
        }
        minimized.push(pattern);
    }

    minimized
}

fn load_grouped_rules_from_config(config_path: &PathBuf) -> Result<TargetFilters> {
    let config_text = fs::read_to_string(config_path)
        .with_context(|| format!("failed to read grouped rule config {}", config_path.display()))?;
    let config_json: serde_json::Value = serde_json::from_str(&config_text)
        .with_context(|| format!("failed to parse grouped rule config {}", config_path.display()))?;

    let rules = config_json
        .get("rules")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| anyhow!("grouped rule config is missing a non-empty 'rules' array"))?;

    let mut grouped_rules = Vec::new();
    let mut all_prefixes = Vec::new();
    let mut all_suffixes = Vec::new();

    for (idx, rule) in rules.iter().enumerate() {
        let prefix_path = rule
            .get("prefix_file")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let suffix_path = rule
            .get("suffix_file")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");

        let prefixes = load_pattern_file(prefix_path)?;
        let suffixes = load_pattern_file(suffix_path)?;

        if prefixes.is_empty() && suffixes.is_empty() {
            bail!("rule {} must provide at least one non-empty prefix or suffix file", idx + 1);
        }

        for prefix in &prefixes {
            validate_fragment("grouped prefix", prefix)?;
        }
        for suffix in &suffixes {
            validate_fragment("grouped suffix", suffix)?;
        }

        all_prefixes.extend(prefixes.iter().cloned());
        all_suffixes.extend(suffixes.iter().cloned());
        grouped_rules.push(RuleGroup { prefixes, suffixes });
    }

    Ok(TargetFilters {
        prefixes: normalize_fragments(all_prefixes),
        suffixes: normalize_fragments(all_suffixes),
        grouped_rules,
    })
}

fn load_pattern_file(path_text: &str) -> Result<Vec<String>> {
    if path_text.trim().is_empty() {
        return Ok(Vec::new());
    }

    let path = PathBuf::from(path_text);
    let content = fs::read_to_string(&path)
        .with_context(|| format!("failed to read pattern file {}", path.display()))?;

    Ok(normalize_fragments(
        content
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(ToOwned::to_owned)
            .collect(),
    ))
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

    if let Some(parent) = cli.aesthetic_results_file.parent() {
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
    let target_results_file = if result.match_type == "aesthetic" {
        &cli.aesthetic_results_file
    } else {
        &cli.results_file
    };

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(target_results_file)
        .with_context(|| format!("failed to open {}", target_results_file.display()))?;
    writeln!(file, "{line}")
        .with_context(|| format!("failed to append {}", target_results_file.display()))?;
    Ok(())
}

fn is_listed_match(filters: &TargetFilters, result: &MatchResult) -> bool {
    let prefix = result.matched_prefix.as_deref().unwrap_or("");
    let suffix = result.matched_suffix.as_deref().unwrap_or("");

    if !filters.grouped_rules.is_empty() {
        return filters.grouped_rules.iter().any(|rule| {
            let prefix_matches = rule.prefixes.is_empty() || rule.prefixes.iter().any(|entry| entry == prefix);
            let suffix_matches = rule.suffixes.is_empty() || rule.suffixes.iter().any(|entry| entry == suffix);
            prefix_matches && suffix_matches
        });
    }

    let prefix_matches = filters.prefixes.is_empty() || filters.prefixes.iter().any(|entry| entry == prefix);
    let suffix_matches = filters.suffixes.is_empty() || filters.suffixes.iter().any(|entry| entry == suffix);
    prefix_matches && suffix_matches
}

fn should_persist_match(cli: &Cli, filters: &TargetFilters, result: &MatchResult) -> bool {
    if is_listed_match(filters, result) {
        return true;
    }

    let prefix_len = result.matched_prefix.as_deref().map_or(0, str::len);
    let suffix_len = result.matched_suffix.as_deref().map_or(0, str::len);
    if cli.min_total_matched_chars > 0 {
        prefix_len + suffix_len >= cli.min_total_matched_chars
    } else {
        true
    }
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
    obj.insert("match_type".to_string(), serde_json::json!(result.match_type));
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

fn format_count_human(value: u64) -> String {
    let value = value as f64;
    if value >= 1_000_000_000_000.0 {
        return format!("{:.2}T", value / 1_000_000_000_000.0);
    }
    if value >= 1_000_000_000.0 {
        return format!("{:.2}B", value / 1_000_000_000.0);
    }
    if value >= 1_000_000.0 {
        return format!("{:.2}M", value / 1_000_000.0);
    }
    if value >= 1_000.0 {
        return format!("{:.2}K", value / 1_000.0);
    }
    format!("{}", value as u64)
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
