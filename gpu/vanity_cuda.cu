#include <cuda_runtime.h>
#include <curand_kernel.h>

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <random>
#include <string>
#include <vector>

#include "../vendor-solanity/src/cuda-headers/gpu_common.h"
#include "../vendor-solanity/src/cuda-ecc-ed25519/ed25519.h"

bool g_verbose = false;

void ed25519_set_verbose(bool val) {
    g_verbose = val;
}

#include "../vendor-solanity/src/cuda-ecc-ed25519/keypair.cu"
#include "../vendor-solanity/src/cuda-ecc-ed25519/sc.cu"
#include "../vendor-solanity/src/cuda-ecc-ed25519/fe.cu"
#include "../vendor-solanity/src/cuda-ecc-ed25519/ge.cu"
#include "../vendor-solanity/src/cuda-ecc-ed25519/sha512.cu"
#include "generated_config.h"

namespace {

constexpr int MAX_ADDRESS_LEN = 64;
constexpr int MAX_KEYPAIR_B58_LEN = 128;
constexpr int MAX_SEED_B58_LEN = 64;
constexpr int MAX_JSON_LINE_LEN = 2048;

struct Options {
    unsigned long long attempts_per_execution = 100000;
    unsigned long long max_iterations = 0;
    unsigned long long max_matches = 0;
    bool emit_base58 = false;
    bool emit_solana_json = false;
    bool emit_seed_base58 = false;
    bool emit_seed_hex = false;
    bool private_key_formats_explicit = false;
    bool verbose = false;
};

struct PatternStats {
    int effective_prefixes = 0;
    int effective_suffixes = 0;
    double prefix_probability = 1.0;
    double suffix_probability = 1.0;
    double combined_probability = 1.0;
    double average_attempts = 1.0;
};

void print_usage() {
    std::printf(
        "Usage: gpu\\\\bin\\\\solana-vanity-gpu.exe [options]\n\n"
        "Options:\n"
        "  --attempts-per-execution <n>  Keys tested per GPU thread per launch\n"
        "  --max-iterations <n>          Stop after this many kernel launches\n"
        "  --max-matches <n>             Stop after this many matches\n"
        "  --private-key-format <name>   none, base58, solana-json, seed-base58, seed-hex, or all\n"
        "  --verbose                     Enable debug logging\n"
        "  --help                        Show this message\n"
    );
}

void apply_private_key_format(Options& options, const char* format) {
    if (!options.private_key_formats_explicit) {
        options.emit_base58 = false;
        options.emit_solana_json = false;
        options.emit_seed_base58 = false;
        options.emit_seed_hex = false;
        options.private_key_formats_explicit = true;
    }

    if (std::strcmp(format, "none") == 0) {
        return;
    } else if (std::strcmp(format, "base58") == 0) {
        options.emit_base58 = true;
    } else if (std::strcmp(format, "solana-json") == 0) {
        options.emit_solana_json = true;
    } else if (std::strcmp(format, "seed-base58") == 0) {
        options.emit_seed_base58 = true;
    } else if (std::strcmp(format, "seed-hex") == 0) {
        options.emit_seed_hex = true;
    } else if (std::strcmp(format, "all") == 0) {
        options.emit_base58 = true;
        options.emit_solana_json = true;
        options.emit_seed_base58 = true;
        options.emit_seed_hex = true;
    } else {
        std::fprintf(
            stderr,
            "Unknown private key format: %s. Use none, base58, solana-json, seed-base58, seed-hex, or all.\n",
            format
        );
        std::exit(1);
    }
}

Options parse_args(int argc, char** argv) {
    Options options;

    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];
        auto require_value = [&](const char* flag) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "Missing value for %s\n", flag);
                std::exit(1);
            }
            return argv[++i];
        };

        if (std::strcmp(arg, "--attempts-per-execution") == 0) {
            options.attempts_per_execution = _strtoui64(require_value(arg), nullptr, 10);
        } else if (std::strcmp(arg, "--max-iterations") == 0) {
            options.max_iterations = _strtoui64(require_value(arg), nullptr, 10);
        } else if (std::strcmp(arg, "--max-matches") == 0) {
            options.max_matches = _strtoui64(require_value(arg), nullptr, 10);
        } else if (std::strcmp(arg, "--private-key-format") == 0) {
            apply_private_key_format(options, require_value(arg));
        } else if (std::strcmp(arg, "--verbose") == 0) {
            options.verbose = true;
        } else if (std::strcmp(arg, "--help") == 0 || std::strcmp(arg, "-h") == 0) {
            print_usage();
            std::exit(0);
        } else {
            std::fprintf(stderr, "Unknown argument: %s\n", arg);
            std::exit(1);
        }
    }

    return options;
}

unsigned long long make_seed() {
    unsigned long long seed = 0;
    unsigned char* out = reinterpret_cast<unsigned char*>(&seed);
    std::random_device rd;

    for (unsigned int i = 0; i < sizeof(seed); ++i) {
        const unsigned int value = rd();
        out[i] = reinterpret_cast<const unsigned char*>(&value)[0];
    }

    return seed;
}

const char* timestamp() {
    static char buffer[32];
    std::time_t now = std::time(nullptr);
    std::tm local{};
    localtime_s(&local, &now);
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", &local);
    return buffer;
}

bool starts_with(const std::string& value, const std::string& prefix) {
    return value.size() >= prefix.size() && value.compare(0, prefix.size(), prefix) == 0;
}

bool ends_with(const std::string& value, const std::string& suffix) {
    return value.size() >= suffix.size()
        && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::vector<std::string> minimize_prefix_patterns(const std::vector<std::string>& patterns) {
    auto sorted = patterns;
    std::stable_sort(sorted.begin(), sorted.end(), [](const std::string& left, const std::string& right) {
        return left.size() < right.size();
    });

    std::vector<std::string> minimized;
    minimized.reserve(sorted.size());

    for (const auto& pattern : sorted) {
        bool covered = false;
        for (const auto& existing : minimized) {
            if (starts_with(pattern, existing)) {
                covered = true;
                break;
            }
        }
        if (!covered) {
            minimized.push_back(pattern);
        }
    }

    return minimized;
}

std::vector<std::string> minimize_suffix_patterns(const std::vector<std::string>& patterns) {
    auto sorted = patterns;
    std::stable_sort(sorted.begin(), sorted.end(), [](const std::string& left, const std::string& right) {
        return left.size() < right.size();
    });

    std::vector<std::string> minimized;
    minimized.reserve(sorted.size());

    for (const auto& pattern : sorted) {
        bool covered = false;
        for (const auto& existing : minimized) {
            if (ends_with(pattern, existing)) {
                covered = true;
                break;
            }
        }
        if (!covered) {
            minimized.push_back(pattern);
        }
    }

    return minimized;
}

std::vector<std::string> load_prefix_patterns() {
    if (GPU_PREFIX_COUNT == 0) {
        return {};
    }

    int host_lengths[GPU_PREFIX_COUNT] = {};
    char host_patterns[GPU_PREFIX_COUNT][16] = {};
    CUDA_CHK(cudaMemcpyFromSymbol(host_lengths, GPU_PREFIX_LENGTHS, sizeof(host_lengths)));
    CUDA_CHK(cudaMemcpyFromSymbol(host_patterns, GPU_PREFIXES, sizeof(host_patterns)));

    std::vector<std::string> patterns;
    patterns.reserve(GPU_PREFIX_COUNT);
    for (int i = 0; i < GPU_PREFIX_COUNT; ++i) {
        patterns.emplace_back(host_patterns[i], host_lengths[i]);
    }

    return patterns;
}

std::vector<std::string> load_suffix_patterns() {
    if (GPU_SUFFIX_COUNT == 0) {
        return {};
    }

    int host_lengths[GPU_SUFFIX_COUNT] = {};
    char host_patterns[GPU_SUFFIX_COUNT][16] = {};
    CUDA_CHK(cudaMemcpyFromSymbol(host_lengths, GPU_SUFFIX_LENGTHS, sizeof(host_lengths)));
    CUDA_CHK(cudaMemcpyFromSymbol(host_patterns, GPU_SUFFIXES, sizeof(host_patterns)));

    std::vector<std::string> patterns;
    patterns.reserve(GPU_SUFFIX_COUNT);
    for (int i = 0; i < GPU_SUFFIX_COUNT; ++i) {
        patterns.emplace_back(host_patterns[i], host_lengths[i]);
    }

    return patterns;
}

double pattern_probability(const std::vector<std::string>& patterns) {
    if (patterns.empty()) {
        return 1.0;
    }

    double probability = 0.0;
    for (const auto& pattern : patterns) {
        probability += std::pow(58.0, -static_cast<int>(pattern.size()));
    }
    return probability;
}

PatternStats estimate_pattern_stats() {
    PatternStats stats;

    auto prefix_patterns = load_prefix_patterns();
    auto suffix_patterns = load_suffix_patterns();
    auto effective_prefixes = minimize_prefix_patterns(prefix_patterns);
    auto effective_suffixes = minimize_suffix_patterns(suffix_patterns);

    stats.effective_prefixes = static_cast<int>(effective_prefixes.size());
    stats.effective_suffixes = static_cast<int>(effective_suffixes.size());
    stats.prefix_probability = pattern_probability(effective_prefixes);
    stats.suffix_probability = pattern_probability(effective_suffixes);
    stats.combined_probability = stats.prefix_probability * stats.suffix_probability;
    if (stats.combined_probability > 0.0) {
        stats.average_attempts = 1.0 / stats.combined_probability;
    } else {
        stats.average_attempts = std::numeric_limits<double>::infinity();
    }

    return stats;
}

std::string format_rate(double cps) {
    char buffer[64];
    if (cps >= 1'000'000'000.0) {
        std::snprintf(buffer, sizeof(buffer), "%.2f G addr/s", cps / 1'000'000'000.0);
    } else if (cps >= 1'000'000.0) {
        std::snprintf(buffer, sizeof(buffer), "%.2f M addr/s", cps / 1'000'000.0);
    } else if (cps >= 1'000.0) {
        std::snprintf(buffer, sizeof(buffer), "%.2f K addr/s", cps / 1'000.0);
    } else {
        std::snprintf(buffer, sizeof(buffer), "%.0f addr/s", cps);
    }
    return buffer;
}

std::string format_duration_brief(double seconds) {
    if (!std::isfinite(seconds)) {
        return "unknown";
    }
    if (seconds < 1.0) {
        return "<1s";
    }
    if (seconds < 60.0) {
        char buffer[32];
        std::snprintf(buffer, sizeof(buffer), "%.0fs", seconds);
        return buffer;
    }
    if (seconds < 3600.0) {
        char buffer[32];
        std::snprintf(buffer, sizeof(buffer), "%.1fm", seconds / 60.0);
        return buffer;
    }
    if (seconds < 86400.0) {
        char buffer[32];
        std::snprintf(buffer, sizeof(buffer), "%.1fh", seconds / 3600.0);
        return buffer;
    }
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.1fd", seconds / 86400.0);
    return buffer;
}

__device__ bool prefix_matches(const char* key, int key_len, int* matched_index) {
    if (GPU_PREFIX_COUNT == 0) {
        *matched_index = -1;
        return true;
    }

    for (int i = 0; i < GPU_PREFIX_COUNT; ++i) {
        const int len = GPU_PREFIX_LENGTHS[i];
        if (len > key_len) {
            continue;
        }

        bool matched = true;
        for (int j = 0; j < len; ++j) {
            if (GPU_PREFIXES[i][j] != key[j]) {
                matched = false;
                break;
            }
        }

        if (matched) {
            *matched_index = i;
            return true;
        }
    }

    return false;
}

__device__ bool suffix_matches(const char* key, int key_len, int* matched_index) {
    if (GPU_SUFFIX_COUNT == 0) {
        *matched_index = -1;
        return true;
    }

    for (int i = 0; i < GPU_SUFFIX_COUNT; ++i) {
        const int len = GPU_SUFFIX_LENGTHS[i];
        if (len > key_len) {
            continue;
        }

        const int start = key_len - len;
        bool matched = true;
        for (int j = 0; j < len; ++j) {
            if (GPU_SUFFIXES[i][j] != key[start + j]) {
                matched = false;
                break;
            }
        }

        if (matched) {
            *matched_index = i;
            return true;
        }
    }

    return false;
}

__device__ void append_char(char*& out, char* end, char ch) {
    if (out + 1 < end) {
        *out++ = ch;
    }
}

__device__ void append_cstr(char*& out, char* end, const char* text) {
    while (*text != '\0' && out + 1 < end) {
        *out++ = *text++;
    }
}

__device__ void append_u64(char*& out, char* end, unsigned long long value) {
    char digits[32];
    int len = 0;

    do {
        digits[len++] = static_cast<char>('0' + (value % 10ULL));
        value /= 10ULL;
    } while (value != 0 && len < static_cast<int>(sizeof(digits)));

    while (len > 0 && out + 1 < end) {
        *out++ = digits[--len];
    }
}

__device__ void append_hex_bytes(char*& out, char* end, const unsigned char* bytes, int len) {
    constexpr char HEX[] = "0123456789abcdef";
    for (int i = 0; i < len && out + 2 < end; ++i) {
        const unsigned char byte = bytes[i];
        *out++ = HEX[(byte >> 4) & 0x0F];
        *out++ = HEX[byte & 0x0F];
    }
}

__device__ void append_u8_list(char*& out, char* end, const unsigned char* bytes, int len) {
    for (int i = 0; i < len; ++i) {
        if (i > 0) {
            append_char(out, end, ',');
        }
        append_u64(out, end, static_cast<unsigned long long>(bytes[i]));
    }
}

__device__ bool b58enc_device(char* b58, size_t* b58sz, const unsigned char* data, size_t binsz) {
    const char alphabet[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    size_t zcount = 0;
    while (zcount < binsz && data[zcount] == 0) {
        ++zcount;
    }

    const size_t size = (binsz - zcount) * 138 / 100 + 1;
    unsigned char buf[256];
    memset(buf, 0, size);

    size_t high = size - 1;
    for (size_t i = zcount; i < binsz; ++i) {
        int carry = data[i];
        size_t j = size - 1;
        for (; (j > high) || carry; --j) {
            carry += 256 * buf[j];
            buf[j] = static_cast<unsigned char>(carry % 58);
            carry /= 58;
            if (j == 0) {
                break;
            }
        }
        high = j;
    }

    size_t j = 0;
    while (j < size && buf[j] == 0) {
        ++j;
    }

    if (*b58sz <= zcount + size - j) {
        *b58sz = zcount + size - j + 1;
        return false;
    }

    if (zcount > 0) {
        memset(b58, '1', zcount);
    }

    size_t i = zcount;
    while (j < size) {
        b58[i++] = alphabet[buf[j++]];
    }

    b58[i] = '\0';
    *b58sz = i + 1;
    return true;
}

__global__ void vanity_init(unsigned long long seed, curandState* states) {
    const int id = threadIdx.x + (blockIdx.x * blockDim.x);
    curand_init(seed + id, id, 0, &states[id]);
}

__global__ void vanity_scan(
    curandState* states,
    int* keys_found,
    unsigned long long base_attempts,
    unsigned long long attempts_per_execution,
    bool emit_base58,
    bool emit_solana_json,
    bool emit_seed_base58,
    bool emit_seed_hex
) {
    const int id = threadIdx.x + (blockIdx.x * blockDim.x);
    curandState local_state = states[id];

    unsigned char seed[32] = {};
    unsigned char public_key[32] = {};
    unsigned char private_key[64] = {};
    unsigned char keypair_bytes[64] = {};
    char address[MAX_ADDRESS_LEN] = {};
    char keypair_base58[MAX_KEYPAIR_B58_LEN] = {};
    char seed_base58[MAX_SEED_B58_LEN] = {};

    for (int i = 0; i < 32; ++i) {
        const float random = curand_uniform(&local_state);
        seed[i] = static_cast<unsigned char>(random * 255.0f);
    }

    for (unsigned long long attempt = 0; attempt < attempts_per_execution; ++attempt) {
        ed25519_create_keypair(public_key, private_key, seed);

        size_t address_size = MAX_ADDRESS_LEN;
        if (!b58enc_device(address, &address_size, public_key, 32)) {
            continue;
        }

        const int key_len = static_cast<int>(address_size) - 1;
        int prefix_index = -1;
        int suffix_index = -1;

        if (prefix_matches(address, key_len, &prefix_index)
            && suffix_matches(address, key_len, &suffix_index)) {
            atomicAdd(keys_found, 1);

            const bool need_keypair_bytes = emit_base58 || emit_solana_json;
            if (need_keypair_bytes) {
                memcpy(keypair_bytes, seed, 32);
                memcpy(keypair_bytes + 32, public_key, 32);
            }

            if (emit_base58) {
                size_t keypair_size = MAX_KEYPAIR_B58_LEN;
                b58enc_device(keypair_base58, &keypair_size, keypair_bytes, 64);
            }
            if (emit_seed_base58) {
                size_t seed_size = MAX_SEED_B58_LEN;
                b58enc_device(seed_base58, &seed_size, seed, 32);
            }

            const unsigned long long attempt_number =
                base_attempts + (static_cast<unsigned long long>(id) * attempts_per_execution) + attempt + 1ULL;
            char json_line[MAX_JSON_LINE_LEN];
            char* out = json_line;
            char* end = json_line + sizeof(json_line);

            append_cstr(out, end, "JSONMATCH {\"address\":\"");
            append_cstr(out, end, address);
            append_cstr(out, end, "\",\"matched_prefix\":\"");
            append_cstr(out, end, prefix_index >= 0 ? GPU_PREFIXES[prefix_index] : "");
            append_cstr(out, end, "\",\"matched_suffix\":\"");
            append_cstr(out, end, suffix_index >= 0 ? GPU_SUFFIXES[suffix_index] : "");
            append_cstr(out, end, "\",\"attempts\":");
            append_u64(out, end, attempt_number);

            if (emit_base58) {
                append_cstr(out, end, ",\"private_key_base58\":\"");
                append_cstr(out, end, keypair_base58);
                append_char(out, end, '"');
            }
            if (emit_solana_json) {
                append_cstr(out, end, ",\"solana_keypair_bytes\":[");
                append_u8_list(out, end, keypair_bytes, 64);
                append_char(out, end, ']');
            }
            if (emit_seed_base58) {
                append_cstr(out, end, ",\"secret_seed_base58\":\"");
                append_cstr(out, end, seed_base58);
                append_char(out, end, '"');
            }
            if (emit_seed_hex) {
                append_cstr(out, end, ",\"seed_hex\":\"");
                append_hex_bytes(out, end, seed, 32);
                append_char(out, end, '"');
            }
            append_char(out, end, '}');
            *out = '\0';

            printf("%s\n", json_line);
        }

        for (int i = 0; i < 32; ++i) {
            if (seed[i] == 255) {
                seed[i] = 0;
            } else {
                seed[i] += 1;
                break;
            }
        }
    }

    states[id] = local_state;
}

}  // namespace

int main(int argc, char** argv) {
    Options options = parse_args(argc, argv);
    ed25519_set_verbose(options.verbose);

    int gpu_count = 0;
    CUDA_CHK(cudaGetDeviceCount(&gpu_count));
    if (gpu_count <= 0) {
        std::fprintf(stderr, "No CUDA GPUs found\n");
        return 1;
    }

    CUDA_CHK(cudaSetDevice(0));

    cudaDeviceProp device{};
    CUDA_CHK(cudaGetDeviceProperties(&device, 0));

    int block_size = 0;
    int min_grid_size = 0;
    int max_active_blocks = 0;
    CUDA_CHK(cudaOccupancyMaxPotentialBlockSize(&min_grid_size, &block_size, vanity_scan, 0, 0));
    CUDA_CHK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&max_active_blocks, vanity_scan, block_size, 0));
    const int grid_size = max_active_blocks * device.multiProcessorCount;
    const unsigned long long threads_total = static_cast<unsigned long long>(grid_size) * block_size;

    std::printf("GPU           : %s\n", device.name);
    std::printf("Block size    : %d\n", block_size);
    std::printf("Grid size     : %d\n", grid_size);
    std::printf("Threads total : %llu\n", threads_total);
    std::printf("Prefixes      : %d\n", GPU_PREFIX_COUNT);
    std::printf("Suffixes      : %d\n", GPU_SUFFIX_COUNT);
    std::printf("Press Ctrl+C to stop.\n\n");

    curandState* states = nullptr;
    int* keys_found_device = nullptr;

    CUDA_CHK(cudaMalloc(&states, threads_total * sizeof(curandState)));
    CUDA_CHK(cudaMalloc(&keys_found_device, sizeof(int)));

    const unsigned long long rng_seed = make_seed();
    vanity_init<<<grid_size, block_size>>>(rng_seed, states);
    CUDA_CHK(cudaPeekAtLastError());
    CUDA_CHK(cudaDeviceSynchronize());

    const PatternStats pattern_stats = estimate_pattern_stats();

    unsigned long long total_attempts = 0;
    unsigned long long total_matches = 0;
    unsigned long long iteration = 0;
    const auto run_started = std::chrono::high_resolution_clock::now();

    while (true) {
        ++iteration;
        int matches_this_iteration = 0;
        CUDA_CHK(cudaMemset(keys_found_device, 0, sizeof(int)));

        const auto started = std::chrono::high_resolution_clock::now();
        vanity_scan<<<grid_size, block_size>>>(
            states,
            keys_found_device,
            total_attempts,
            options.attempts_per_execution,
            options.emit_base58,
            options.emit_solana_json,
            options.emit_seed_base58,
            options.emit_seed_hex
        );
        CUDA_CHK(cudaPeekAtLastError());
        CUDA_CHK(cudaDeviceSynchronize());
        const auto finished = std::chrono::high_resolution_clock::now();

        CUDA_CHK(cudaMemcpy(&matches_this_iteration, keys_found_device, sizeof(int), cudaMemcpyDeviceToHost));

        const unsigned long long attempts_this_iteration = threads_total * options.attempts_per_execution;
        total_attempts += attempts_this_iteration;
        total_matches += static_cast<unsigned long long>(matches_this_iteration);

        const std::chrono::duration<double> elapsed = finished - started;
        const std::chrono::duration<double> total_elapsed = finished - run_started;
        const double cps = attempts_this_iteration / elapsed.count();
        const double total_cps = total_attempts / total_elapsed.count();
        const double eta_seconds = pattern_stats.average_attempts / total_cps;

        std::printf(
            "%s Iteration %llu Attempts: %llu in %.3f sec at %s (%.3f MH/s) - Total Attempts %llu - Matches %llu - ETA ~ %s/match\n",
            timestamp(),
            iteration,
            attempts_this_iteration,
            elapsed.count(),
            format_rate(cps).c_str(),
            cps / 1000000.0,
            total_attempts,
            total_matches,
            format_duration_brief(eta_seconds).c_str()
        );
        std::fflush(stdout);

        if (options.max_iterations > 0 && iteration >= options.max_iterations) {
            break;
        }
        if (options.max_matches > 0 && total_matches >= options.max_matches) {
            break;
        }
    }

    CUDA_CHK(cudaFree(keys_found_device));
    CUDA_CHK(cudaFree(states));
    return 0;
}
