#include "MossTtsQnnSession.h"

#include <android/log.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <system_error>
#include <thread>

using Json = nlohmann::json;
namespace fs = std::filesystem;

namespace {

constexpr char kLogTag[] = "MossTtsQnn";
constexpr char kQnnExecutionProviderName[] = "QNNExecutionProvider";
constexpr size_t kMaximumTextTokensPerChunk = 75;
constexpr uint16_t kOutputChannels = 2;
std::mutex g_qnn_plugin_mutex;
std::string g_qnn_plugin_path;

struct Utf8CodePoint {
    size_t begin;
    size_t end;
    uint32_t value;
};

std::vector<Utf8CodePoint> DecodeUtf8Boundaries(const std::string& text) {
    std::vector<Utf8CodePoint> result;
    result.reserve(text.size());
    for (size_t offset = 0; offset < text.size();) {
        const auto first = static_cast<uint8_t>(text[offset]);
        size_t length = 1;
        uint32_t value = first;
        if ((first & 0xE0U) == 0xC0U) {
            length = 2;
            value = first & 0x1FU;
        } else if ((first & 0xF0U) == 0xE0U) {
            length = 3;
            value = first & 0x0FU;
        } else if ((first & 0xF8U) == 0xF0U) {
            length = 4;
            value = first & 0x07U;
        }
        bool valid = offset + length <= text.size();
        for (size_t index = 1; valid && index < length; ++index) {
            const auto byte = static_cast<uint8_t>(text[offset + index]);
            valid = (byte & 0xC0U) == 0x80U;
            if (valid) value = (value << 6U) | (byte & 0x3FU);
        }
        if (!valid || (length == 2 && value < 0x80U) ||
            (length == 3 && value < 0x800U) || (length == 4 && value < 0x10000U) ||
            value > 0x10FFFFU || (value >= 0xD800U && value <= 0xDFFFU)) {
            length = 1;
            value = first;
        }
        result.push_back({offset, offset + length, value});
        offset += length;
    }
    return result;
}

bool IsUnicodeWhitespace(uint32_t value) {
    return value == 0x20U || (value >= 0x09U && value <= 0x0DU) || value == 0x85U ||
           value == 0xA0U || value == 0x1680U ||
           (value >= 0x2000U && value <= 0x200AU) || value == 0x2028U ||
           value == 0x2029U || value == 0x202FU || value == 0x205FU || value == 0x3000U;
}

bool IsStrongTextBreak(uint32_t value) {
    return value == '.' || value == '!' || value == '?' || value == ';' ||
           value == 0x3002U || value == 0xFF01U || value == 0xFF1FU || value == 0xFF1BU;
}

bool IsWeakTextBreak(uint32_t value) {
    return value == ',' || value == ':' || value == 0x3001U || value == 0xFF0CU ||
           value == 0xFF1AU;
}

bool IsClosingPunctuation(uint32_t value) {
    switch (value) {
        case '\"':
        case '\'':
        case ')':
        case ']':
        case '}':
        case 0x2019U:
        case 0x201DU:
        case 0x3009U:
        case 0x300BU:
        case 0x300DU:
        case 0x300FU:
        case 0x3011U:
        case 0x3015U:
        case 0x3017U:
        case 0x3019U:
        case 0x301BU:
        case 0xFF09U:
            return true;
        default:
            return false;
    }
}

int TextBreakStrength(const std::vector<Utf8CodePoint>& points, size_t index) {
    size_t punctuation = index;
    while (punctuation > 0 && IsClosingPunctuation(points[punctuation].value)) --punctuation;
    if (IsStrongTextBreak(points[punctuation].value)) return 3;
    if (IsWeakTextBreak(points[punctuation].value)) return 2;
    return IsUnicodeWhitespace(points[index].value) ? 1 : 0;
}

void LogInfo(const std::string& message) {
    __android_log_write(ANDROID_LOG_INFO, kLogTag, message.c_str());
}

Json ReadJson(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot open JSON file: " + path.string());
    try {
        return Json::parse(input);
    } catch (const Json::exception& error) {
        throw std::runtime_error("Invalid JSON " + path.string() + ": " + error.what());
    }
}

std::vector<int32_t> IntVector(const Json& value) {
    if (!value.is_array()) throw std::runtime_error("Expected a JSON integer array");
    std::vector<int32_t> result;
    result.reserve(value.size());
    for (const auto& item : value) result.push_back(item.get<int32_t>());
    return result;
}

std::vector<std::string> StringVector(const Json& value) {
    if (!value.is_array()) throw std::runtime_error("Expected a JSON string array");
    std::vector<std::string> result;
    result.reserve(value.size());
    for (const auto& item : value) result.push_back(item.get<std::string>());
    return result;
}

fs::path ExistingCanonical(const fs::path& path, const char* label) {
    std::error_code error;
    const fs::path canonical = fs::weakly_canonical(path, error);
    if (error || !fs::exists(canonical)) {
        throw std::runtime_error(std::string("Missing ") + label + ": " + path.string());
    }
    return canonical;
}

fs::path ResolveManifestPath(const fs::path& model_root) {
    const std::array candidates{
        model_root / "browser_poc_manifest.json",
        model_root / "MOSS-TTS-Nano-100M-ONNX" / "browser_poc_manifest.json",
        model_root / "MOSS-TTS-Nano-ONNX-CPU" / "browser_poc_manifest.json",
    };
    for (const auto& candidate : candidates) {
        if (fs::is_regular_file(candidate)) return fs::weakly_canonical(candidate);
    }
    throw std::runtime_error("browser_poc_manifest.json was not found under " + model_root.string());
}

fs::path ResolveRelativeWithAliases(const fs::path& directory, std::string relative) {
    fs::path direct = directory / relative;
    if (fs::exists(direct)) return fs::weakly_canonical(direct);
    const auto replace_all = [](std::string& value, const std::string& from, const std::string& to) {
        size_t offset = 0;
        while ((offset = value.find(from, offset)) != std::string::npos) {
            value.replace(offset, from.size(), to);
            offset += to.size();
        }
    };
    replace_all(relative, "MOSS-TTS-Nano-ONNX-CPU", "MOSS-TTS-Nano-100M-ONNX");
    replace_all(relative, "MOSS-Audio-Tokenizer-Nano-ONNX-CPU", "MOSS-Audio-Tokenizer-Nano-ONNX");
    return ExistingCanonical(directory / relative, "manifest dependency");
}

size_t CheckedProduct(const std::vector<int64_t>& shape) {
    size_t product = 1;
    for (const int64_t dimension : shape) {
        if (dimension <= 0) throw std::runtime_error("Tensor has a dynamic or invalid runtime shape");
        const size_t value = static_cast<size_t>(dimension);
        if (value > std::numeric_limits<size_t>::max() / product) {
            throw std::runtime_error("Tensor shape is too large");
        }
        product *= value;
    }
    return product;
}

size_t FindInputIndex(const Ort::Session& session, const std::string& name,
                      Ort::AllocatorWithDefaultOptions& allocator) {
    const size_t count = session.GetInputCount();
    for (size_t index = 0; index < count; ++index) {
        const auto current = session.GetInputNameAllocated(index, allocator);
        if (name == current.get()) return index;
    }
    throw std::runtime_error("Missing ONNX input: " + name);
}

size_t FindOutputIndex(const Ort::Session& session, const std::string& name,
                       Ort::AllocatorWithDefaultOptions& allocator) {
    const size_t count = session.GetOutputCount();
    for (size_t index = 0; index < count; ++index) {
        const auto current = session.GetOutputNameAllocated(index, allocator);
        if (name == current.get()) return index;
    }
    throw std::runtime_error("Missing ONNX output: " + name);
}

std::string StateOutputName(const std::string& input_name) {
    const size_t suffix = input_name.rfind('_');
    if (suffix == std::string::npos || suffix + 1 == input_name.size()) {
        throw std::runtime_error("Unexpected codec state input name: " + input_name);
    }
    return input_name.substr(0, suffix) + "_out" + input_name.substr(suffix);
}

std::vector<const char*> NamePointers(const std::vector<std::string>& names) {
    std::vector<const char*> result;
    result.reserve(names.size());
    for (const auto& name : names) result.push_back(name.c_str());
    return result;
}

template <typename T>
Ort::Value Tensor(Ort::MemoryInfo& memory_info, std::vector<T>& values,
                  const std::vector<int64_t>& shape) {
    if (CheckedProduct(shape) != values.size()) {
        throw std::runtime_error("Tensor data length does not match shape");
    }
    return Ort::Value::CreateTensor<T>(memory_info, values.data(), values.size(),
                                       shape.data(), shape.size());
}

bool HasContextBinary(const fs::path& context_model) {
    const fs::path directory = context_model.parent_path();
    const std::string prefix = context_model.stem().string();
    std::error_code error;
    for (fs::directory_iterator iterator(directory, error); !error && iterator != fs::directory_iterator();
         iterator.increment(error)) {
        const auto& path = iterator->path();
        if (path.extension() == ".bin" && path.filename().string().starts_with(prefix)) return true;
    }
    return false;
}

}  // namespace

class RandomSource final {
public:
    explicit RandomSource(uint64_t seed) : engine_(seed), distribution_(0.000001F, 0.999999F) {}
    float Next() { return distribution_(engine_); }

private:
    std::mt19937_64 engine_;
    std::uniform_real_distribution<float> distribution_;
};

std::string MossTtsQnnSession::SynthesisResult::ToJson() const {
    return Json{{"outputPath", output_path.string()},
                {"sampleRate", sample_rate},
                {"generatedFrames", generated_frames},
                {"audioSamples", audio_samples},
                {"durationMs", sample_rate > 0 ? audio_samples * 1000 / sample_rate : 0},
                {"elapsedMs", elapsed_ms},
                {"prefillMs", prefill_ms},
                {"decodeMs", decode_ms},
                {"codecMs", codec_ms},
                {"htpBusyMs", htp_busy_ms},
                {"provider", provider}}
        .dump();
}

std::string MossTtsQnnSession::TelemetryJson() const {
    uint64_t busy_ns = htp_busy_ns_.load(std::memory_order_relaxed);
    const int32_t in_flight = htp_in_flight_.load(std::memory_order_relaxed);
    if (in_flight > 0) {
        const int64_t started = htp_run_started_ns_.load(std::memory_order_relaxed);
        const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        if (started > 0 && now > started) busy_ns += static_cast<uint64_t>(now - started);
    }
    return Json{{"htpBusyNanos", busy_ns},
                {"htpInvocations", htp_invocations_.load(std::memory_order_relaxed)},
                {"htpInFlight", in_flight},
                {"cpuThreads", CpuThreadCount()},
                {"performanceMode", config_.htp_performance_mode}}
        .dump();
}

MossTtsQnnSession::MossTtsQnnSession(InitConfig config)
    : config_(std::move(config)),
      env_(SharedEnv()),
      cpu_memory_info_(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)) {
    config_.model_root = ExistingCanonical(config_.model_root, "model root");
    config_.native_library_dir = ExistingCanonical(config_.native_library_dir, "native library directory");
    if (!config_.fast_rpc_dir.empty()) {
        config_.fast_rpc_dir = ExistingCanonical(config_.fast_rpc_dir, "FastRPC directory");
        std::string search_path = config_.fast_rpc_dir.string() + ";/vendor/dsp/cdsp;/vendor/lib/rfsa/adsp;/dsp";
        if (const char* existing = std::getenv("ADSP_LIBRARY_PATH"); existing && *existing) {
            search_path += ';';
            search_path += existing;
        }
        if (setenv("ADSP_LIBRARY_PATH", search_path.c_str(), 1) != 0) {
            throw std::runtime_error("Failed to configure ADSP_LIBRARY_PATH");
        }
    }
    std::error_code directory_error;
    fs::create_directories(config_.context_cache_dir, directory_error);
    if (directory_error || !fs::is_directory(config_.context_cache_dir)) {
        throw std::runtime_error("Cannot create QNN context cache: " + config_.context_cache_dir.string());
    }
    LoadDeploymentDigests();
    ReportProgress("plugin");
    RegisterQnnPlugin();
    LoadMetadata();
    PruneContextCache();
    CreateSessions();
}

MossTtsQnnSession::~MossTtsQnnSession() {
    ResetSessions();
}

Ort::Env& MossTtsQnnSession::SharedEnv() {
    static Ort::Env environment(ORT_LOGGING_LEVEL_WARNING, "moss_tts_qnn");
    return environment;
}

std::vector<Ort::ConstEpDevice> MossTtsQnnSession::EnsureQnnPlugin(
    const fs::path& native_library_dir) {
    const fs::path plugin_path = ExistingCanonical(
        native_library_dir / "libonnxruntime_providers_qnn.so", "QNN Plugin EP");
    const std::string canonical_path = plugin_path.string();
    std::lock_guard lock(g_qnn_plugin_mutex);
    Ort::Env& environment = SharedEnv();
    const auto find_qnn_devices = [&environment] {
        std::vector<Ort::ConstEpDevice> devices;
        for (const auto& device : environment.GetEpDevices()) {
            if (device.EpName() &&
                std::strcmp(device.EpName(), kQnnExecutionProviderName) == 0) {
                devices.push_back(device);
            }
        }
        return devices;
    };

    // A different ORT client in this process may have registered the dynamic
    // EP before MOSS. Reuse the devices owned by the shared OrtEnv instead of
    // attempting a second registration under the same name.
    auto devices = find_qnn_devices();
    if (!devices.empty()) {
        if (g_qnn_plugin_path.empty()) g_qnn_plugin_path = canonical_path;
        return devices;
    }
    if (g_qnn_plugin_path.empty()) {
        environment.RegisterExecutionProviderLibrary(kQnnExecutionProviderName, canonical_path);
        g_qnn_plugin_path = canonical_path;
    } else if (g_qnn_plugin_path != canonical_path) {
        throw std::runtime_error("QNN Plugin EP is already registered from a different path");
    }

    devices = find_qnn_devices();
    if (devices.empty()) {
        std::ostringstream details;
        details << "QNN Plugin EP registered but exposed no QNNExecutionProvider device; epDevices=[";
        bool first = true;
        for (const auto& device : environment.GetEpDevices()) {
            const auto hardware = device.Device();
            const char* type = hardware.Type() == OrtHardwareDeviceType_NPU ? "NPU" :
                hardware.Type() == OrtHardwareDeviceType_GPU ? "GPU" : "CPU";
            if (!first) details << ',';
            first = false;
            details << (device.EpName() ? device.EpName() : "unknown") << '('
                    << type << ':' << (hardware.Vendor() ? hardware.Vendor() : "unknown")
                    << ":0x" << std::hex << hardware.VendorId() << std::dec
                    << ':' << hardware.DeviceId() << ')';
        }
        details << ']';
        throw std::runtime_error(details.str());
    }
    return devices;
}

int32_t MossTtsQnnSession::ProbeQnnPlugin(const fs::path& native_library_dir) {
    return static_cast<int32_t>(EnsureQnnPlugin(native_library_dir).size());
}

void MossTtsQnnSession::RegisterQnnPlugin() {
    qnn_devices_ = EnsureQnnPlugin(config_.native_library_dir);
    LogInfo("Registered QNN Plugin EP with " + std::to_string(qnn_devices_.size()) + " device(s)");
}

void MossTtsQnnSession::ReportProgress(const std::string& stage) const {
    if (config_.progress_callback) config_.progress_callback(stage);
}

void MossTtsQnnSession::LoadDeploymentDigests() {
    const fs::path manifest_path = config_.model_root / "moss-qnn-deployment.json";
    const Json manifest = ReadJson(ExistingCanonical(manifest_path, "deployment manifest"));
    const Json& files = manifest.at("files");
    if (!files.is_array() || files.empty()) {
        throw std::runtime_error("Deployment manifest contains no files");
    }

    for (const auto& entry : files) {
        const std::string relative_string = entry.at("path").get<std::string>();
        const fs::path relative(relative_string);
        if (relative.empty() || relative.is_absolute()) {
            throw std::runtime_error("Invalid deployment path: " + relative_string);
        }
        for (const auto& component : relative) {
            if (component == "." || component == "..") {
                throw std::runtime_error("Unsafe deployment path: " + relative_string);
            }
        }

        std::string digest = entry.at("sha256").get<std::string>();
        std::transform(digest.begin(), digest.end(), digest.begin(),
                       [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
        if (digest.size() != 64 ||
            !std::all_of(digest.begin(), digest.end(), [](unsigned char value) {
                return std::isdigit(value) || (value >= 'a' && value <= 'f');
            })) {
            throw std::runtime_error("Invalid deployment SHA-256 for " + relative_string);
        }

        const fs::path deployed = ExistingCanonical(config_.model_root / relative, "deployment file");
        std::error_code relative_error;
        const fs::path under_root = fs::relative(deployed, config_.model_root, relative_error);
        if (relative_error || under_root.empty() || *under_root.begin() == "..") {
            throw std::runtime_error("Deployment file escapes model root: " + relative_string);
        }
        if (!deployment_digests_.emplace(deployed.string(), std::move(digest)).second) {
            throw std::runtime_error("Duplicate deployment file: " + relative_string);
        }
    }
}

void MossTtsQnnSession::LoadMetadata() {
    const fs::path manifest_path = ResolveManifestPath(config_.model_root);
    manifest_dir_ = manifest_path.parent_path();
    const Json manifest = ReadJson(manifest_path);
    const Json& model_files = manifest.at("model_files");
    const fs::path tts_meta_path = ResolveRelativeWithAliases(
        manifest_dir_, model_files.at("tts_meta").get<std::string>());
    const fs::path codec_meta_path = ResolveRelativeWithAliases(
        manifest_dir_, model_files.at("codec_meta").get<std::string>());
    tts_dir_ = tts_meta_path.parent_path();
    codec_dir_ = codec_meta_path.parent_path();

    const Json& config = manifest.at("tts_config");
    tts_config_.n_vq = config.at("n_vq").get<int32_t>();
    tts_config_.audio_pad_token_id = config.at("audio_pad_token_id").get<int32_t>();
    tts_config_.audio_start_token_id = config.at("audio_start_token_id").get<int32_t>();
    tts_config_.audio_end_token_id = config.at("audio_end_token_id").get<int32_t>();
    tts_config_.audio_user_slot_token_id = config.value("audio_user_slot_token_id", 8);
    tts_config_.audio_assistant_slot_token_id = config.at("audio_assistant_slot_token_id").get<int32_t>();
    tts_config_.audio_codebook_sizes = IntVector(config.at("audio_codebook_sizes"));
    if (tts_config_.n_vq <= 0 || static_cast<size_t>(tts_config_.n_vq) !=
            tts_config_.audio_codebook_sizes.size()) {
        throw std::runtime_error("Invalid n_vq/audio_codebook_sizes in MOSS manifest");
    }

    const Json& prompts = manifest.at("prompt_templates");
    prompt_prefix_ = IntVector(prompts.at("user_prompt_prefix_token_ids"));
    prompt_after_reference_ = IntVector(prompts.at("user_prompt_after_reference_token_ids"));
    assistant_prefix_ = IntVector(prompts.at("assistant_prompt_prefix_token_ids"));
    generation_max_frames_ = manifest.value("generation_defaults", Json::object())
                                 .value("max_new_frames", 375);

    for (const auto& entry : manifest.value("builtin_voices", Json::array())) {
        std::vector<std::vector<int32_t>> codes;
        for (const auto& row : entry.value("prompt_audio_codes", Json::array())) {
            codes.push_back(IntVector(row));
        }
        if (!codes.empty()) {
            const std::string name = entry.value("voice", "");
            if (fallback_voice_.empty()) fallback_voice_ = name;
            voices_[name] = std::move(codes);
        }
    }
    if (voices_.empty()) throw std::runtime_error("MOSS manifest contains no built-in voice prompt");

    const Json tts_meta = ReadJson(tts_meta_path);
    const Json& tts_files = tts_meta.at("files");
    prefill_file_ = tts_files.at("prefill").get<std::string>();
    decode_file_ = tts_files.at("decode_step").get<std::string>();
    sampler_file_ = tts_files.at("local_fixed_sampled_frame").get<std::string>();
    decode_input_names_ = StringVector(tts_meta.at("onnx").at("decode_input_names"));
    decode_output_names_ = StringVector(tts_meta.at("onnx").at("decode_output_names"));
    if (decode_input_names_.size() < 3 || decode_output_names_.size() < 2) {
        throw std::runtime_error("MOSS decode metadata has no KV cache names");
    }

    const Json codec_meta = ReadJson(codec_meta_path);
    codec_file_ = codec_meta.at("files").at("decode_step").get<std::string>();
    sample_rate_ = codec_meta.at("codec_config").at("sample_rate").get<int32_t>();
    tokenizer_ = std::make_unique<SentencePieceTokenizer>((tts_dir_ / "tokenizer.model").string());
}

fs::path MossTtsQnnSession::ResolveModelFile(const fs::path& directory,
                                             const std::string& file_name) const {
    const fs::path source = directory / file_name;
    const fs::path base = directory / fs::path(file_name).replace_extension();
    const std::array candidates{
        fs::path(base.string() + ".qnn.onnx"),
        fs::path(base.string() + ".static.optimized.onnx"),
        source,
    };
    for (const auto& candidate : candidates) {
        if (fs::is_regular_file(candidate)) return fs::weakly_canonical(candidate);
    }
    throw std::runtime_error("Missing ONNX model: " + source.string());
}

std::string MossTtsQnnSession::ContextKey(const std::string& role,
                                          const fs::path& model_path) const {
    const fs::path canonical = ExistingCanonical(model_path, "ONNX model");
    const auto model_digest = deployment_digests_.find(canonical.string());
    if (model_digest == deployment_digests_.end()) {
        throw std::runtime_error("ONNX model is not covered by the deployment manifest: " +
                                 canonical.string());
    }

    std::vector<std::string> external_digests;
    for (const auto& [path_string, digest] : deployment_digests_) {
        const fs::path path(path_string);
        if (path.parent_path() == canonical.parent_path() && path.extension() == ".data") {
            external_digests.push_back(digest);
        }
    }
    std::sort(external_digests.begin(), external_digests.end());

    const bool enable_fp16 = config_.enable_htp_fp16 && role != "codec";
    std::string key = std::string("v2_q248_o126_f") +
                      (enable_fp16 ? "1_" : "0_") + model_digest->second;
    for (const auto& digest : external_digests) key += '_' + digest;
    if (key.size() > 220) {
        throw std::runtime_error("QNN context identity exceeds the private filename limit");
    }
    return key;
}

fs::path MossTtsQnnSession::ContextModelPath(const std::string& role,
                                              const fs::path& model_path) const {
    return config_.context_cache_dir / (role + '_' + ContextKey(role, model_path) + ".ctx.onnx");
}

void MossTtsQnnSession::PruneContextCache() {
    if (!config_.enable_context_cache) return;

    const std::array role_models{
        std::pair{"prefill", ResolveModelFile(tts_dir_, prefill_file_)},
        std::pair{"decode", ResolveModelFile(tts_dir_, decode_file_)},
        std::pair{"codec", ResolveModelFile(codec_dir_, codec_file_)},
    };
    std::unordered_set<std::string> expected_models;
    std::vector<std::string> expected_binary_prefixes;
    for (const auto& [role, model] : role_models) {
        const fs::path context_model = ContextModelPath(role, model);
        expected_models.insert(context_model.filename().string());
        expected_binary_prefixes.push_back(context_model.stem().string());
    }

    uintmax_t removed_bytes = 0;
    size_t removed_files = 0;
    std::error_code iteration_error;
    for (fs::directory_iterator iterator(config_.context_cache_dir, iteration_error);
         !iteration_error && iterator != fs::directory_iterator(); iterator.increment(iteration_error)) {
        const fs::directory_entry& entry = *iterator;
        std::error_code type_error;
        if (!entry.is_regular_file(type_error) || type_error) continue;
        const fs::path path = entry.path();
        const std::string filename = path.filename().string();
        bool keep = expected_models.contains(filename);
        if (!keep && path.extension() == ".bin") {
            keep = std::any_of(expected_binary_prefixes.begin(), expected_binary_prefixes.end(),
                               [&](const std::string& prefix) { return filename.starts_with(prefix); });
        }
        if (keep) continue;
        if (path.extension() != ".onnx" && path.extension() != ".bin" &&
            path.extension() != ".tmp") {
            continue;
        }
        std::error_code size_error;
        const uintmax_t size = entry.file_size(size_error);
        std::error_code remove_error;
        if (fs::remove(path, remove_error) && !remove_error) {
            ++removed_files;
            if (!size_error) removed_bytes += size;
        } else {
            __android_log_write(ANDROID_LOG_WARN, kLogTag,
                                ("Cannot remove stale QNN context: " + path.string()).c_str());
        }
    }
    if (iteration_error) {
        throw std::runtime_error("Cannot enumerate QNN context cache: " + iteration_error.message());
    }
    if (removed_files > 0) {
        LogInfo("Removed " + std::to_string(removed_files) + " stale context file(s), " +
                std::to_string(removed_bytes) + " bytes");
    }
}

void MossTtsQnnSession::CreateSessions() {
    const auto prepare_qnn_context = [this](const std::string& role, const fs::path& path) {
        ReportProgress(role);
        auto session = CreateSession(role, path, true, config_.hardware_only);
        session.session.reset();
        LogInfo("Prepared and released " + role + " session");
    };
    prepare_qnn_context("prefill", ResolveModelFile(tts_dir_, prefill_file_));
    prepare_qnn_context("decode", ResolveModelFile(tts_dir_, decode_file_));
    ReportProgress("codec");
    auto codec = CreateSession("codec", ResolveModelFile(codec_dir_, codec_file_), false, false);
    codec.session.reset();
    LogInfo("QNN generation contexts and ORT CPU codec are ready; no model session remains resident");
}

void MossTtsQnnSession::ResetSessions() noexcept {
    codec_.session.reset();
    sampler_.session.reset();
    decode_.session.reset();
    prefill_.session.reset();
}

MossTtsQnnSession::SessionHolder MossTtsQnnSession::CreateSession(
    const std::string& role, const fs::path& model_path, bool use_qnn, bool require_full_offload) {
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    options.SetIntraOpNumThreads(use_qnn ? 1 : CpuThreadCount());
    options.SetInterOpNumThreads(1);
    if (use_qnn) {
        options.DisableMemPattern();
    }

    fs::path session_path = model_path;
    fs::path context_model;
    bool generating_context = false;
    if (use_qnn) {
        const bool enable_fp16 = config_.enable_htp_fp16 && role != "codec";
        std::unordered_map<std::string, std::string> ep_options{
            {"backend_path", (config_.native_library_dir / "libQnnHtp.so").string()},
            {"enable_htp_fp16_precision", enable_fp16 ? "1" : "0"},
            {"htp_performance_mode", config_.htp_performance_mode},
            {"qnn_context_priority", "high"},
            {"rpc_control_latency", "10"},
            {"htp_graph_finalization_optimization_mode", role == "codec" ? "0" : "3"},
            {"offload_graph_io_quantization", "0"},
        };
        options.AppendExecutionProvider_V2(env_, qnn_devices_, ep_options);
        options.AddConfigEntry("session.disable_cpu_ep_fallback", require_full_offload ? "1" : "0");

        if (config_.enable_context_cache) {
            context_model = ContextModelPath(role, model_path);
            if (fs::is_regular_file(context_model) && HasContextBinary(context_model)) {
                session_path = context_model;
            } else {
                generating_context = true;
                options.AddConfigEntry("ep.context_enable", "1");
                options.AddConfigEntry("ep.context_embed_mode", "0");
                options.AddConfigEntry("ep.context_file_path", context_model.string().c_str());
            }
        }
    }

    LogInfo("Creating " + role + " session from " + session_path.filename().string());
    auto session = std::make_unique<Ort::Session>(env_, session_path.c_str(), options);
    if (generating_context && (!fs::is_regular_file(context_model) || !HasContextBinary(context_model))) {
        throw std::runtime_error("QNN did not produce a complete context cache for " + role);
    }
    return {role, model_path, std::move(session), use_qnn};
}

int32_t MossTtsQnnSession::CpuThreadCount() {
    const unsigned int available = std::thread::hardware_concurrency();
    return static_cast<int32_t>(std::clamp(available == 0 ? 2U : available / 2U, 2U, 4U));
}

std::vector<Ort::Value> MossTtsQnnSession::RunHtp(
    Ort::Session& session, const char* const* input_names, Ort::Value* inputs,
    size_t input_count, const char* const* output_names, size_t output_count) {
    const auto started = std::chrono::steady_clock::now();
    htp_run_started_ns_.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
        started.time_since_epoch()).count(), std::memory_order_relaxed);
    htp_in_flight_.fetch_add(1, std::memory_order_relaxed);
    try {
        auto outputs = session.Run(Ort::RunOptions{nullptr}, input_names, inputs, input_count,
                                   output_names, output_count);
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started).count();
        htp_busy_ns_.fetch_add(static_cast<uint64_t>(std::max<int64_t>(elapsed, 0)),
                              std::memory_order_relaxed);
        htp_invocations_.fetch_add(1, std::memory_order_relaxed);
        htp_in_flight_.fetch_sub(1, std::memory_order_relaxed);
        htp_run_started_ns_.store(0, std::memory_order_relaxed);
        return outputs;
    } catch (...) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started).count();
        htp_busy_ns_.fetch_add(static_cast<uint64_t>(std::max<int64_t>(elapsed, 0)),
                              std::memory_order_relaxed);
        htp_invocations_.fetch_add(1, std::memory_order_relaxed);
        htp_in_flight_.fetch_sub(1, std::memory_order_relaxed);
        htp_run_started_ns_.store(0, std::memory_order_relaxed);
        throw;
    }
}

void MossTtsQnnSession::RunHtp(Ort::Session& session, Ort::IoBinding& binding) {
    const auto started = std::chrono::steady_clock::now();
    htp_run_started_ns_.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
        started.time_since_epoch()).count(), std::memory_order_relaxed);
    htp_in_flight_.fetch_add(1, std::memory_order_relaxed);
    try {
        session.Run(Ort::RunOptions{nullptr}, binding);
        binding.SynchronizeOutputs();
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started).count();
        htp_busy_ns_.fetch_add(static_cast<uint64_t>(std::max<int64_t>(elapsed, 0)),
                              std::memory_order_relaxed);
        htp_invocations_.fetch_add(1, std::memory_order_relaxed);
        htp_in_flight_.fetch_sub(1, std::memory_order_relaxed);
        htp_run_started_ns_.store(0, std::memory_order_relaxed);
    } catch (...) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started).count();
        htp_busy_ns_.fetch_add(static_cast<uint64_t>(std::max<int64_t>(elapsed, 0)),
                              std::memory_order_relaxed);
        htp_invocations_.fetch_add(1, std::memory_order_relaxed);
        htp_in_flight_.fetch_sub(1, std::memory_order_relaxed);
        htp_run_started_ns_.store(0, std::memory_order_relaxed);
        throw;
    }
}

size_t MossTtsQnnSession::PrefillSequenceCapacity() const {
    const size_t index = FindInputIndex(*prefill_.session, "input_ids",
                                        const_cast<Ort::AllocatorWithDefaultOptions&>(allocator_));
    const auto shape = prefill_.session->GetInputTypeInfo(index).GetTensorTypeAndShapeInfo().GetShape();
    if (shape.size() != 3 || shape[2] != tts_config_.n_vq + 1) {
        throw std::runtime_error("Unexpected prefill input_ids shape");
    }
    if (shape[1] <= 0) return 0;
    return static_cast<size_t>(shape[1]);
}

std::vector<std::vector<int32_t>> MossTtsQnnSession::TokenizeChunks(
    const std::string& text, const std::string& voice) const {
    const auto voice_it = voices_.find(voice);
    const auto& prompt_codes = voice_it == voices_.end()
                                   ? voices_.at(fallback_voice_)
                                   : voice_it->second;
    const size_t fixed_rows = prompt_prefix_.size() + 1 + prompt_codes.size() + 1 +
                              prompt_after_reference_.size() + assistant_prefix_.size() + 1;
    const size_t capacity = PrefillSequenceCapacity();
    const size_t prefill_capacity =
        capacity == 0 ? kMaximumTextTokensPerChunk : capacity - std::min(capacity, fixed_rows);
    const size_t token_capacity = std::min(kMaximumTextTokensPerChunk, prefill_capacity);
    if (token_capacity == 0) throw std::runtime_error("Voice prompt exceeds prefill sequence capacity");

    const auto points = DecodeUtf8Boundaries(text);
    size_t cursor = 0;
    while (cursor < points.size() && IsUnicodeWhitespace(points[cursor].value)) ++cursor;
    size_t text_end = points.size();
    while (text_end > cursor && IsUnicodeWhitespace(points[text_end - 1].value)) --text_end;
    if (cursor == text_end) throw std::invalid_argument("Text produced no SentencePiece tokens");

    std::vector<std::vector<int32_t>> chunks;
    while (cursor < text_end) {
        const size_t byte_begin = points[cursor].begin;
        size_t furthest = cursor;
        std::array<size_t, 4> last_break{cursor, cursor, cursor, cursor};
        for (size_t index = cursor; index < text_end; ++index) {
            const size_t byte_end = points[index].end;
            const auto candidate = tokenizer_->Encode(text.substr(byte_begin, byte_end - byte_begin));
            if (candidate.size() > token_capacity) break;
            furthest = index + 1;
            const int strength = TextBreakStrength(points, index);
            if (strength > 0) last_break[static_cast<size_t>(strength)] = index + 1;
        }
        if (furthest == cursor) {
            throw std::runtime_error("A UTF-8 character exceeds the text token budget");
        }

        size_t chunk_end = furthest;
        if (furthest < text_end) {
            if (last_break[3] > cursor) chunk_end = last_break[3];
            else if (last_break[2] > cursor) chunk_end = last_break[2];
            else if (last_break[1] > cursor) chunk_end = last_break[1];
        }
        size_t encoded_end = chunk_end;
        while (encoded_end > cursor && IsUnicodeWhitespace(points[encoded_end - 1].value)) {
            --encoded_end;
        }
        auto tokens = tokenizer_->Encode(
            text.substr(byte_begin, points[encoded_end - 1].end - byte_begin));
        if (tokens.empty() || tokens.size() > token_capacity) {
            throw std::runtime_error("Text chunking violated the SentencePiece token budget");
        }
        chunks.push_back(std::move(tokens));
        cursor = chunk_end;
        while (cursor < text_end && IsUnicodeWhitespace(points[cursor].value)) ++cursor;
    }
    LogInfo("Tokenized text into " + std::to_string(chunks.size()) +
            " chunks with a " + std::to_string(token_capacity) + "-token limit");
    return chunks;
}

MossTtsQnnSession::InputRows MossTtsQnnSession::BuildInputRows(
    const std::vector<int32_t>& text_tokens, const std::string& voice) const {
    const auto voice_it = voices_.find(voice);
    const auto& prompt_codes = voice_it == voices_.end() ? voices_.at(fallback_voice_) : voice_it->second;
    const size_t width = static_cast<size_t>(tts_config_.n_vq + 1);
    std::vector<std::vector<int32_t>> rows;
    const auto text_row = [&](int32_t token) {
        std::vector<int32_t> row(width, tts_config_.audio_pad_token_id);
        row[0] = token;
        rows.push_back(std::move(row));
    };
    for (int32_t token : prompt_prefix_) text_row(token);
    text_row(tts_config_.audio_start_token_id);
    for (const auto& codes : prompt_codes) {
        std::vector<int32_t> row(width, tts_config_.audio_pad_token_id);
        row[0] = tts_config_.audio_user_slot_token_id;
        for (size_t index = 0; index < std::min(codes.size(), width - 1); ++index) {
            row[index + 1] = codes[index];
        }
        rows.push_back(std::move(row));
    }
    text_row(tts_config_.audio_end_token_id);
    for (int32_t token : prompt_after_reference_) text_row(token);
    for (int32_t token : text_tokens) text_row(token);
    for (int32_t token : assistant_prefix_) text_row(token);
    text_row(tts_config_.audio_start_token_id);

    InputRows result;
    result.rows = rows.size();
    result.width = width;
    result.values.reserve(result.rows * width);
    for (const auto& row : rows) result.values.insert(result.values.end(), row.begin(), row.end());
    result.attention_mask.assign(result.rows, 1);
    return result;
}

MossTtsQnnSession::PrefillResult MossTtsQnnSession::RunPrefill(const InputRows& rows) {
    const size_t capacity = PrefillSequenceCapacity();
    const size_t sequence_length = capacity == 0 ? rows.rows : capacity;
    if (rows.rows > sequence_length) throw std::runtime_error("Text exceeds MOSS prefill capacity");
    std::vector<int32_t> input_values(sequence_length * rows.width, 0);
    std::copy(rows.values.begin(), rows.values.end(), input_values.begin());
    std::vector<int32_t> mask(sequence_length, 0);
    std::copy(rows.attention_mask.begin(), rows.attention_mask.end(), mask.begin());
    std::vector<int64_t> input_shape{1, static_cast<int64_t>(sequence_length),
                                     static_cast<int64_t>(rows.width)};
    std::vector<int64_t> mask_shape{1, static_cast<int64_t>(sequence_length)};
    auto input_tensor = Tensor(cpu_memory_info_, input_values, input_shape);
    auto mask_tensor = Tensor(cpu_memory_info_, mask, mask_shape);
    std::array<Ort::Value, 2> inputs{std::move(input_tensor), std::move(mask_tensor)};
    const std::array<const char*, 2> input_names{"input_ids", "attention_mask"};
    const auto output_names = NamePointers(decode_output_names_);
    auto outputs = RunHtp(*prefill_.session, input_names.data(), inputs.data(), inputs.size(),
                          output_names.data(), output_names.size());

    const auto hidden_shape = TensorShape(outputs.at(0));
    if (hidden_shape.size() != 3 || hidden_shape[0] != 1 ||
        static_cast<size_t>(hidden_shape[1]) < rows.rows) {
        throw std::runtime_error("Unexpected prefill global_hidden shape");
    }
    const auto hidden_values = CopyFloatTensor(outputs[0]);
    const size_t hidden_width = static_cast<size_t>(hidden_shape[2]);
    const size_t hidden_offset = (rows.rows - 1) * hidden_width;
    PrefillResult result;
    result.global_hidden.assign(hidden_values.begin() + static_cast<std::ptrdiff_t>(hidden_offset),
                                hidden_values.begin() + static_cast<std::ptrdiff_t>(hidden_offset + hidden_width));
    result.valid_length = static_cast<int32_t>(rows.rows);
    for (size_t index = 1; index < outputs.size(); ++index) {
        result.cache.push_back({CopyFloatTensor(outputs[index]), TensorShape(outputs[index])});
    }
    return result;
}

MossTtsQnnSession::LocalFrameResult MossTtsQnnSession::RunLocalFrame(
    const std::vector<float>& global_hidden,
    const std::vector<std::unordered_set<int32_t>>& previous_tokens,
    RandomSource& random) {
    const int32_t codebook_size = tts_config_.audio_codebook_sizes.front();
    std::vector<int32_t> seen(static_cast<size_t>(tts_config_.n_vq * codebook_size), 0);
    for (size_t channel = 0; channel < previous_tokens.size(); ++channel) {
        for (int32_t token : previous_tokens[channel]) {
            if (token >= 0 && token < codebook_size) seen[channel * codebook_size + token] = 1;
        }
    }
    std::vector<float> hidden = global_hidden;
    std::vector<float> assistant_random{random.Next()};
    std::vector<float> audio_random(static_cast<size_t>(tts_config_.n_vq));
    std::generate(audio_random.begin(), audio_random.end(), [&] { return random.Next(); });
    std::vector<int64_t> hidden_shape{1, static_cast<int64_t>(hidden.size())};
    std::vector<int64_t> seen_shape{1, tts_config_.n_vq, codebook_size};
    std::vector<int64_t> assistant_shape{1};
    std::vector<int64_t> audio_shape{1, tts_config_.n_vq};
    std::array<Ort::Value, 4> inputs{
        Tensor(cpu_memory_info_, hidden, hidden_shape),
        Tensor(cpu_memory_info_, seen, seen_shape),
        Tensor(cpu_memory_info_, assistant_random, assistant_shape),
        Tensor(cpu_memory_info_, audio_random, audio_shape),
    };
    const std::array<const char*, 4> input_names{
        "global_hidden", "repetition_seen_mask", "assistant_random_u", "audio_random_u"};
    const std::array<const char*, 2> output_names{"should_continue", "frame_token_ids"};
    auto outputs = sampler_.session->Run(Ort::RunOptions{nullptr}, input_names.data(), inputs.data(),
                                         inputs.size(), output_names.data(), output_names.size());
    const auto should_continue = CopyIntTensor(outputs[0]);
    auto frame = CopyIntTensor(outputs[1]);
    if (should_continue.empty() || frame.size() < static_cast<size_t>(tts_config_.n_vq)) {
        throw std::runtime_error("Sampler returned invalid output tensors");
    }
    frame.resize(static_cast<size_t>(tts_config_.n_vq));
    return {should_continue.front() > 0, std::move(frame)};
}

std::vector<std::vector<int32_t>> MossTtsQnnSession::RunDecode(PrefillResult prefill,
                                                                int32_t max_frames,
                                                                uint64_t seed) {
    const std::vector<std::string> past_names(decode_input_names_.begin() + 2, decode_input_names_.end());
    const std::vector<std::string> present_names(decode_output_names_.begin() + 1,
                                                  decode_output_names_.end());
    if (past_names.size() != prefill.cache.size() || present_names.size() != prefill.cache.size()) {
        throw std::runtime_error("MOSS prefill/decode KV cache count mismatch");
    }

    for (size_t index = 0; index < prefill.cache.size(); ++index) {
        const size_t input_index = FindInputIndex(*decode_.session, past_names[index], allocator_);
        const auto input_shape = decode_.session->GetInputTypeInfo(input_index)
                                     .GetTensorTypeAndShapeInfo().GetShape();
        if (input_shape.size() != 4 || input_shape[0] != 1 || input_shape[1] <= 0) {
            throw std::runtime_error("Decode KV cache input must have fixed rank-4 capacity");
        }
        const size_t capacity = static_cast<size_t>(input_shape[1]);
        const auto& source_shape = prefill.cache[index].shape;
        if (source_shape.size() != 4 || source_shape[0] != 1 || source_shape[1] <= 0 ||
            source_shape[2] != input_shape[2] || source_shape[3] != input_shape[3] ||
            static_cast<size_t>(source_shape[1]) > capacity) {
            throw std::runtime_error("Prefill KV cache is incompatible with decode cache");
        }
        const size_t per_position = static_cast<size_t>(input_shape[2] * input_shape[3]);
        std::vector<float> padded(capacity * per_position, 0.0F);
        std::copy(prefill.cache[index].values.begin(), prefill.cache[index].values.end(), padded.begin());
        prefill.cache[index] = {std::move(padded), input_shape};
    }

    std::vector<std::vector<float>> next_cache;
    next_cache.reserve(prefill.cache.size());
    for (size_t index = 0; index < prefill.cache.size(); ++index) {
        const size_t output_index = FindOutputIndex(*decode_.session, present_names[index], allocator_);
        const auto output_info = decode_.session->GetOutputTypeInfo(output_index)
                                     .GetTensorTypeAndShapeInfo();
        if (output_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
            output_info.GetShape() != prefill.cache[index].shape) {
            throw std::runtime_error("Decode I/O binding requires fixed float KV outputs");
        }
        next_cache.emplace_back(prefill.cache[index].values.size(), 0.0F);
    }
    const size_t hidden_output_index = FindOutputIndex(*decode_.session, decode_output_names_.front(),
                                                       allocator_);
    const auto hidden_output_info = decode_.session->GetOutputTypeInfo(hidden_output_index)
                                        .GetTensorTypeAndShapeInfo();
    const auto hidden_output_shape = hidden_output_info.GetShape();
    if (hidden_output_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        hidden_output_shape.size() < 2 || hidden_output_shape.back() <= 0) {
        throw std::runtime_error("Decode I/O binding requires a fixed float hidden output");
    }
    std::vector<float> next_hidden(CheckedProduct(hidden_output_shape), 0.0F);

    RandomSource random(seed);
    std::vector<std::unordered_set<int32_t>> previous(static_cast<size_t>(tts_config_.n_vq));
    std::vector<std::vector<int32_t>> audio_tokens;
    const int32_t capped_frames = std::clamp(max_frames, 1, generation_max_frames_);

    for (int32_t step = 0; step < capped_frames; ++step) {
        const LocalFrameResult sampled = RunLocalFrame(prefill.global_hidden, previous, random);
        if (!sampled.should_continue) break;
        std::vector<int32_t> row(static_cast<size_t>(tts_config_.n_vq + 1),
                                 tts_config_.audio_pad_token_id);
        row[0] = tts_config_.audio_assistant_slot_token_id;
        for (size_t channel = 0; channel < sampled.frame.size(); ++channel) {
            row[channel + 1] = sampled.frame[channel];
            previous[channel].insert(sampled.frame[channel]);
        }
        audio_tokens.push_back(sampled.frame);

        const size_t capacity = static_cast<size_t>(prefill.cache.front().shape[1]);
        if (prefill.valid_length >= static_cast<int32_t>(capacity)) {
            throw std::runtime_error("MOSS decode exceeded fixed KV cache capacity");
        }
        std::vector<int32_t> past_length{prefill.valid_length};
        std::vector<int64_t> row_shape{1, 1, tts_config_.n_vq + 1};
        std::vector<int64_t> length_shape{1};
        Ort::IoBinding binding(*decode_.session);
        std::vector<Ort::Value> bound_inputs;
        std::vector<Ort::Value> bound_outputs;
        bound_inputs.reserve(2 + prefill.cache.size());
        bound_outputs.reserve(1 + prefill.cache.size());
        bound_inputs.push_back(Tensor(cpu_memory_info_, row, row_shape));
        binding.BindInput(decode_input_names_[0].c_str(), bound_inputs.back());
        bound_inputs.push_back(Tensor(cpu_memory_info_, past_length, length_shape));
        binding.BindInput(decode_input_names_[1].c_str(), bound_inputs.back());
        for (size_t index = 0; index < prefill.cache.size(); ++index) {
            auto& cache = prefill.cache[index];
            bound_inputs.push_back(Tensor(cpu_memory_info_, cache.values, cache.shape));
            binding.BindInput(past_names[index].c_str(), bound_inputs.back());
        }
        bound_outputs.push_back(Tensor(cpu_memory_info_, next_hidden, hidden_output_shape));
        binding.BindOutput(decode_output_names_.front().c_str(), bound_outputs.back());
        for (size_t index = 0; index < prefill.cache.size(); ++index) {
            bound_outputs.push_back(Tensor(cpu_memory_info_, next_cache[index], prefill.cache[index].shape));
            binding.BindOutput(present_names[index].c_str(), bound_outputs.back());
        }
        RunHtp(*decode_.session, binding);

        const size_t hidden_width = static_cast<size_t>(hidden_output_shape.back());
        prefill.global_hidden.assign(next_hidden.end() - static_cast<std::ptrdiff_t>(hidden_width),
                                     next_hidden.end());
        for (size_t index = 0; index < prefill.cache.size(); ++index) {
            prefill.cache[index].values.swap(next_cache[index]);
        }
        ++prefill.valid_length;
    }
    if (audio_tokens.empty()) throw std::runtime_error("MOSS generated no audio tokens");
    return audio_tokens;
}

std::vector<float> MossTtsQnnSession::DecodeAudioTokens(
    const std::vector<std::vector<int32_t>>& audio_tokens) {
    struct StateTensor {
        std::string input_name;
        std::string output_name;
        std::vector<int64_t> shape;
        ONNXTensorElementDataType element_type;
        std::array<std::vector<float>, 2> floats;
        std::array<std::vector<int32_t>, 2> integers;
    };

    const size_t codes_index = FindInputIndex(*codec_.session, "audio_codes", allocator_);
    const auto codes_info = codec_.session->GetInputTypeInfo(codes_index)
                                .GetTensorTypeAndShapeInfo();
    const auto codes_shape = codes_info.GetShape();
    if (codes_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32 ||
        codes_shape != std::vector<int64_t>({1, 1, tts_config_.n_vq})) {
        throw std::runtime_error("Streaming codec requires a fixed single-frame audio_codes input");
    }

    std::vector<StateTensor> state;
    state.reserve(codec_.session->GetInputCount() - 2);
    for (size_t input_index = 0; input_index < codec_.session->GetInputCount(); ++input_index) {
        const auto allocated_name = codec_.session->GetInputNameAllocated(input_index, allocator_);
        const std::string input_name = allocated_name.get();
        if (input_name == "audio_codes" || input_name == "audio_code_lengths") continue;
        const std::string output_name = StateOutputName(input_name);
        const auto input_info = codec_.session->GetInputTypeInfo(input_index)
                                    .GetTensorTypeAndShapeInfo();
        const auto shape = input_info.GetShape();
        const auto element_type = input_info.GetElementType();
        const size_t output_index = FindOutputIndex(*codec_.session, output_name, allocator_);
        const auto output_info = codec_.session->GetOutputTypeInfo(output_index)
                                     .GetTensorTypeAndShapeInfo();
        if (output_info.GetShape() != shape || output_info.GetElementType() != element_type) {
            throw std::runtime_error("Streaming codec state I/O is not fixed: " + input_name);
        }
        StateTensor tensor{input_name, output_name, shape, element_type, {}, {}};
        const size_t count = CheckedProduct(shape);
        if (element_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
            for (auto& buffer : tensor.floats) buffer.assign(count, 0.0F);
        } else if (element_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) {
            const int32_t initial =
                input_name.find("cached_positions") != std::string::npos ? -1 : 0;
            for (auto& buffer : tensor.integers) buffer.assign(count, initial);
        } else {
            throw std::runtime_error("Unsupported streaming codec state type: " + input_name);
        }
        state.push_back(std::move(tensor));
    }
    if (state.size() != 52) {
        throw std::runtime_error("Streaming codec exposed an unexpected state tensor count");
    }

    const size_t audio_output_index = FindOutputIndex(*codec_.session, "audio", allocator_);
    const auto audio_info = codec_.session->GetOutputTypeInfo(audio_output_index)
                                .GetTensorTypeAndShapeInfo();
    const auto audio_shape = audio_info.GetShape();
    if (audio_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        audio_shape.size() != 3 || audio_shape[0] != 1 || audio_shape[1] <= 0 ||
        audio_shape[2] <= 0) {
        throw std::runtime_error("Streaming codec requires a fixed float audio output");
    }
    const size_t lengths_output_index =
        FindOutputIndex(*codec_.session, "audio_lengths", allocator_);
    const auto lengths_info = codec_.session->GetOutputTypeInfo(lengths_output_index)
                                  .GetTensorTypeAndShapeInfo();
    if (lengths_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32 ||
        lengths_info.GetShape() != std::vector<int64_t>({1})) {
        throw std::runtime_error("Streaming codec requires a fixed int32 audio_lengths output");
    }

    const std::vector<int64_t> length_shape{1};
    std::vector<int32_t> codes(static_cast<size_t>(tts_config_.n_vq), 0);
    std::vector<int32_t> lengths{1};
    std::vector<float> audio(CheckedProduct(audio_shape), 0.0F);
    std::vector<int32_t> reported(1, 0);
    const size_t channels = static_cast<size_t>(audio_shape[1]);
    if (channels != kOutputChannels) {
        throw std::runtime_error("Streaming codec must produce stereo audio");
    }
    std::vector<float> interleaved;
    const size_t available = static_cast<size_t>(audio_shape[2]);
    interleaved.reserve(audio_tokens.size() * available * channels);
    size_t current_buffer = 0;

    for (const auto& frame : audio_tokens) {
        if (frame.size() < static_cast<size_t>(tts_config_.n_vq)) {
            throw std::runtime_error("Audio token frame has too few quantizers");
        }
        std::copy_n(frame.begin(), tts_config_.n_vq, codes.begin());
        const size_t next_buffer = 1 - current_buffer;
        Ort::IoBinding binding(*codec_.session);
        std::vector<Ort::Value> bound_inputs;
        std::vector<Ort::Value> bound_outputs;
        bound_inputs.reserve(2 + state.size());
        bound_outputs.reserve(2 + state.size());
        bound_inputs.push_back(Tensor(cpu_memory_info_, codes, codes_shape));
        binding.BindInput("audio_codes", bound_inputs.back());
        bound_inputs.push_back(Tensor(cpu_memory_info_, lengths, length_shape));
        binding.BindInput("audio_code_lengths", bound_inputs.back());
        for (auto& tensor : state) {
            if (tensor.element_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
                bound_inputs.push_back(
                    Tensor(cpu_memory_info_, tensor.floats[current_buffer], tensor.shape));
            } else {
                bound_inputs.push_back(
                    Tensor(cpu_memory_info_, tensor.integers[current_buffer], tensor.shape));
            }
            binding.BindInput(tensor.input_name.c_str(), bound_inputs.back());
        }
        bound_outputs.push_back(Tensor(cpu_memory_info_, audio, audio_shape));
        binding.BindOutput("audio", bound_outputs.back());
        bound_outputs.push_back(Tensor(cpu_memory_info_, reported, length_shape));
        binding.BindOutput("audio_lengths", bound_outputs.back());
        for (auto& tensor : state) {
            if (tensor.element_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
                bound_outputs.push_back(
                    Tensor(cpu_memory_info_, tensor.floats[next_buffer], tensor.shape));
            } else {
                bound_outputs.push_back(
                    Tensor(cpu_memory_info_, tensor.integers[next_buffer], tensor.shape));
            }
            binding.BindOutput(tensor.output_name.c_str(), bound_outputs.back());
        }
        if (codec_.qnn) {
            RunHtp(*codec_.session, binding);
        } else {
            codec_.session->Run(Ort::RunOptions{nullptr}, binding);
            binding.SynchronizeOutputs();
        }

        const size_t length =
            std::min(available, static_cast<size_t>(std::max(reported.front(), 0)));
        const size_t output_offset = interleaved.size();
        interleaved.resize(output_offset + length * channels);
        for (size_t sample = 0; sample < length; ++sample) {
            for (size_t channel = 0; channel < channels; ++channel) {
                interleaved[output_offset + sample * channels + channel] =
                    audio[channel * available + sample];
            }
        }
        current_buffer = next_buffer;
    }
    if (interleaved.empty()) throw std::runtime_error("Streaming codec produced no audio samples");
    return interleaved;
}

MossTtsQnnSession::SynthesisResult MossTtsQnnSession::Synthesize(
    const std::string& text, const fs::path& output_path, const std::string& voice,
    int32_t max_frames, uint64_t seed) {
    std::lock_guard lock(run_mutex_);
    if (text.empty()) throw std::invalid_argument("Text is empty");
    const auto started = std::chrono::steady_clock::now();
    const uint64_t htp_started = htp_busy_ns_.load(std::memory_order_relaxed);
    int64_t prefill_ms = 0;
    int64_t decode_ms = 0;
    int64_t codec_ms = 0;
    const fs::path absolute_output = fs::absolute(output_path);
    try {
        prefill_ = CreateSession("prefill", ResolveModelFile(tts_dir_, prefill_file_), true,
                                 config_.hardware_only);
        const auto chunks = TokenizeChunks(text, voice);
        std::error_code error;
        fs::create_directories(absolute_output.parent_path(), error);
        if (error) throw std::runtime_error("Cannot create audio output directory");
        std::fstream output(absolute_output,
                            std::ios::binary | std::ios::in | std::ios::out | std::ios::trunc);
        if (!output) throw std::runtime_error("Cannot create WAV output: " + absolute_output.string());
        std::array<char, 44> empty_header{};
        output.write(empty_header.data(), empty_header.size());

        int64_t total_samples = 0;
        int32_t total_frames = 0;
        const size_t silence_samples = static_cast<size_t>(sample_rate_ * 120 / 1000);
        for (size_t index = 0; index < chunks.size(); ++index) {
            const auto prefill_started = std::chrono::steady_clock::now();
            if (!prefill_.session) {
                prefill_ = CreateSession("prefill", ResolveModelFile(tts_dir_, prefill_file_), true,
                                         config_.hardware_only);
            }
            const InputRows rows = BuildInputRows(chunks[index], voice);
            auto prefill = RunPrefill(rows);
            prefill_.session.reset();
            prefill_ms += std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - prefill_started).count();
            LogInfo("Released prefill session before decode");

            const auto decode_started = std::chrono::steady_clock::now();
            decode_ = CreateSession("decode", ResolveModelFile(tts_dir_, decode_file_), true,
                                    config_.hardware_only);
            // QAIRT 2.48 V81 rejects CumulativeSum in this graph, so only the sampler uses ORT CPU.
            sampler_ = CreateSession("sampler", ResolveModelFile(tts_dir_, sampler_file_), false,
                                     false);
            auto audio_tokens = RunDecode(std::move(prefill), max_frames, seed + index);
            sampler_.session.reset();
            decode_.session.reset();
            decode_ms += std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - decode_started).count();
            LogInfo("Released decode and sampler sessions before codec");

            const auto codec_started = std::chrono::steady_clock::now();
            codec_ = CreateSession("codec", ResolveModelFile(codec_dir_, codec_file_), false, false);
            auto samples = DecodeAudioTokens(audio_tokens);
            codec_.session.reset();
            codec_ms += std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - codec_started).count();
            LogInfo("Released codec session");

            WritePcm16(output, samples);
            if (samples.size() % kOutputChannels != 0) {
                throw std::runtime_error("Codec returned a partial stereo sample frame");
            }
            total_samples += static_cast<int64_t>(samples.size() / kOutputChannels);
            total_frames += static_cast<int32_t>(audio_tokens.size());
            if (index + 1 < chunks.size()) {
                WriteSilence(output, silence_samples, kOutputChannels);
                total_samples += static_cast<int64_t>(silence_samples);
            }
        }
        output.flush();
        WriteWavHeader(output, sample_rate_, kOutputChannels, total_samples);
        output.close();
        ResetSessions();
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        const auto htp_elapsed = htp_busy_ns_.load(std::memory_order_relaxed) - htp_started;
        LogInfo("Synthesis complete: frames=" + std::to_string(total_frames) +
                " elapsed_ms=" + std::to_string(elapsed) +
                " prefill_ms=" + std::to_string(prefill_ms) +
                " decode_ms=" + std::to_string(decode_ms) +
                " codec_ms=" + std::to_string(codec_ms) +
                " htp_busy_ms=" + std::to_string(htp_elapsed / 1'000'000));
        return {absolute_output, sample_rate_, total_frames, total_samples, elapsed,
                prefill_ms, decode_ms, codec_ms, static_cast<int64_t>(htp_elapsed / 1'000'000),
                "QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)"};
    } catch (...) {
        ResetSessions();
        std::error_code remove_error;
        fs::remove(absolute_output, remove_error);
        throw;
    }
}

std::vector<int64_t> MossTtsQnnSession::TensorShape(const Ort::Value& value) {
    if (!value.IsTensor()) throw std::runtime_error("ONNX output is not a tensor");
    return value.GetTensorTypeAndShapeInfo().GetShape();
}

size_t MossTtsQnnSession::TensorElementCount(const Ort::Value& value) {
    return value.GetTensorTypeAndShapeInfo().GetElementCount();
}

std::vector<float> MossTtsQnnSession::CopyFloatTensor(const Ort::Value& value) {
    const auto info = value.GetTensorTypeAndShapeInfo();
    const size_t count = info.GetElementCount();
    std::vector<float> result(count);
    if (info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        const float* data = value.GetTensorData<float>();
        std::copy_n(data, count, result.begin());
    } else if (info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
        const Ort::Float16_t* data = value.GetTensorData<Ort::Float16_t>();
        std::transform(data, data + count, result.begin(), [](Ort::Float16_t item) {
            return static_cast<float>(item);
        });
    } else {
        throw std::runtime_error("Expected float/float16 tensor output");
    }
    return result;
}

std::vector<int32_t> MossTtsQnnSession::CopyIntTensor(const Ort::Value& value) {
    const auto info = value.GetTensorTypeAndShapeInfo();
    const size_t count = info.GetElementCount();
    std::vector<int32_t> result(count);
    if (info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) {
        const int32_t* data = value.GetTensorData<int32_t>();
        std::copy_n(data, count, result.begin());
    } else if (info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
        const int64_t* data = value.GetTensorData<int64_t>();
        std::transform(data, data + count, result.begin(), [](int64_t item) {
            if (item < std::numeric_limits<int32_t>::min() || item > std::numeric_limits<int32_t>::max()) {
                throw std::runtime_error("int64 tensor value does not fit int32");
            }
            return static_cast<int32_t>(item);
        });
    } else if (info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL) {
        const bool* data = value.GetTensorData<bool>();
        std::transform(data, data + count, result.begin(), [](bool item) { return item ? 1 : 0; });
    } else {
        throw std::runtime_error("Expected int32/int64/bool tensor output");
    }
    return result;
}

void MossTtsQnnSession::WritePcm16(std::ostream& output, const std::vector<float>& samples) {
    std::array<char, 16384> bytes{};
    size_t byte_count = 0;
    for (const float sample : samples) {
        const auto value = static_cast<int16_t>(std::lrint(std::clamp(sample, -1.0F, 1.0F) * 32767.0F));
        bytes[byte_count++] = static_cast<char>(value & 0xFF);
        bytes[byte_count++] = static_cast<char>((static_cast<uint16_t>(value) >> 8U) & 0xFFU);
        if (byte_count == bytes.size()) {
            output.write(bytes.data(), static_cast<std::streamsize>(byte_count));
            byte_count = 0;
        }
    }
    if (byte_count > 0) output.write(bytes.data(), static_cast<std::streamsize>(byte_count));
    if (!output) throw std::runtime_error("Failed while writing WAV PCM data");
}

void MossTtsQnnSession::WriteSilence(std::ostream& output, size_t sample_frames,
                                     uint16_t channels) {
    std::array<char, 16384> zeros{};
    if (channels == 0 || sample_frames > std::numeric_limits<size_t>::max() / channels / 2) {
        throw std::runtime_error("Silence buffer is too large");
    }
    size_t bytes = sample_frames * channels * 2;
    while (bytes > 0) {
        const size_t count = std::min(bytes, zeros.size());
        output.write(zeros.data(), static_cast<std::streamsize>(count));
        bytes -= count;
    }
}

void MossTtsQnnSession::WriteWavHeader(std::fstream& output, int32_t sample_rate,
                                       uint16_t channels, int64_t sample_frames) {
    if (sample_rate <= 0 || channels == 0 ||
        sample_rate > static_cast<int32_t>(std::numeric_limits<uint32_t>::max() /
                                           (static_cast<uint32_t>(channels) * 2U))) {
        throw std::runtime_error("Invalid WAV stream format");
    }
    const int64_t bytes_per_frame = static_cast<int64_t>(channels) * 2;
    const int64_t data_size64 = sample_frames * bytes_per_frame;
    constexpr int64_t kMaximumDataSize =
        static_cast<int64_t>(std::numeric_limits<uint32_t>::max()) - 36;
    if (data_size64 < 0 || data_size64 > kMaximumDataSize) {
        throw std::runtime_error("Generated WAV is too large");
    }
    const uint32_t data_size = static_cast<uint32_t>(data_size64);
    std::array<uint8_t, 44> header{};
    const auto put_u16 = [&](size_t offset, uint16_t value) {
        header[offset] = static_cast<uint8_t>(value);
        header[offset + 1] = static_cast<uint8_t>(value >> 8U);
    };
    const auto put_u32 = [&](size_t offset, uint32_t value) {
        for (size_t i = 0; i < 4; ++i) header[offset + i] = static_cast<uint8_t>(value >> (8U * i));
    };
    std::memcpy(header.data(), "RIFF", 4);
    put_u32(4, 36 + data_size);
    std::memcpy(header.data() + 8, "WAVEfmt ", 8);
    put_u32(16, 16);
    put_u16(20, 1);
    put_u16(22, channels);
    put_u32(24, static_cast<uint32_t>(sample_rate));
    put_u32(28, static_cast<uint32_t>(sample_rate) * channels * 2U);
    put_u16(32, static_cast<uint16_t>(channels * 2U));
    put_u16(34, 16);
    std::memcpy(header.data() + 36, "data", 4);
    put_u32(40, data_size);
    output.seekp(0);
    output.write(reinterpret_cast<const char*>(header.data()), header.size());
    output.flush();
    if (!output) throw std::runtime_error("Failed to finalize WAV header");
}
