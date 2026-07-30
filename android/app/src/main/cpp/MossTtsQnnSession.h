#pragma once

#include "SentencePieceTokenizer.h"

#include <onnxruntime_cxx_api.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

class MossTtsQnnSession final {
public:
    struct InitConfig {
        std::filesystem::path model_root;
        std::filesystem::path native_library_dir;
        std::filesystem::path context_cache_dir;
        std::filesystem::path fast_rpc_dir;
        bool hardware_only = true;
        bool enable_context_cache = true;
        bool enable_htp_fp16 = true;
        std::string htp_performance_mode = "burst";
        std::function<void(const std::string&)> progress_callback;
    };

    struct SynthesisResult {
        std::filesystem::path output_path;
        int32_t sample_rate = 0;
        int32_t generated_frames = 0;
        int64_t audio_samples = 0;
        int64_t elapsed_ms = 0;
        int64_t prefill_ms = 0;
        int64_t decode_ms = 0;
        int64_t codec_ms = 0;
        int64_t htp_busy_ms = 0;
        std::string provider;

        [[nodiscard]] std::string ToJson() const;
    };

    explicit MossTtsQnnSession(InitConfig config);
    ~MossTtsQnnSession();

    MossTtsQnnSession(const MossTtsQnnSession&) = delete;
    MossTtsQnnSession& operator=(const MossTtsQnnSession&) = delete;

    [[nodiscard]] static int32_t ProbeQnnPlugin(
        const std::filesystem::path& native_library_dir);

    SynthesisResult Synthesize(const std::string& text,
                               const std::filesystem::path& output_path,
                               const std::string& voice,
                               int32_t max_frames,
                               uint64_t seed);
    [[nodiscard]] std::string TelemetryJson() const;

private:
    struct TtsConfig {
        int32_t n_vq = 0;
        int32_t audio_pad_token_id = 0;
        int32_t audio_start_token_id = 0;
        int32_t audio_end_token_id = 0;
        int32_t audio_user_slot_token_id = 8;
        int32_t audio_assistant_slot_token_id = 0;
        std::vector<int32_t> audio_codebook_sizes;
    };

    struct InputRows {
        std::vector<int32_t> values;
        std::vector<int32_t> attention_mask;
        size_t rows = 0;
        size_t width = 0;
    };

    struct TensorBuffer {
        std::vector<float> values;
        std::vector<int64_t> shape;
    };

    struct PrefillResult {
        std::vector<float> global_hidden;
        int32_t valid_length = 0;
        std::vector<TensorBuffer> cache;
    };

    struct LocalFrameResult {
        bool should_continue = false;
        std::vector<int32_t> frame;
    };

    struct SessionHolder {
        std::string role;
        std::filesystem::path model_path;
        std::unique_ptr<Ort::Session> session;
        bool qnn = false;
    };

    InitConfig config_;
    Ort::Env& env_;
    Ort::MemoryInfo cpu_memory_info_;
    Ort::AllocatorWithDefaultOptions allocator_;
    std::vector<Ort::ConstEpDevice> qnn_devices_;
    std::mutex run_mutex_;
    std::atomic<uint64_t> htp_busy_ns_{0};
    std::atomic<uint64_t> htp_invocations_{0};
    std::atomic<int32_t> htp_in_flight_{0};
    std::atomic<int64_t> htp_run_started_ns_{0};

    std::filesystem::path manifest_dir_;
    std::filesystem::path tts_dir_;
    std::filesystem::path codec_dir_;
    TtsConfig tts_config_;
    int32_t sample_rate_ = 24000;
    int32_t generation_max_frames_ = 375;
    std::vector<int32_t> prompt_prefix_;
    std::vector<int32_t> prompt_after_reference_;
    std::vector<int32_t> assistant_prefix_;
    std::unordered_map<std::string, std::vector<std::vector<int32_t>>> voices_;
    std::string fallback_voice_;
    std::vector<std::string> decode_input_names_;
    std::vector<std::string> decode_output_names_;
    std::unordered_map<std::string, std::string> deployment_digests_;
    std::string prefill_file_;
    std::string decode_file_;
    std::string sampler_file_;
    std::string codec_file_;

    std::unique_ptr<SentencePieceTokenizer> tokenizer_;
    SessionHolder prefill_;
    SessionHolder decode_;
    SessionHolder sampler_;
    SessionHolder codec_;

    void RegisterQnnPlugin();
    [[nodiscard]] static Ort::Env& SharedEnv();
    [[nodiscard]] static std::vector<Ort::ConstEpDevice> EnsureQnnPlugin(
        const std::filesystem::path& native_library_dir);
    void LoadDeploymentDigests();
    void LoadMetadata();
    void CreateSessions();
    void PruneContextCache();
    void ReportProgress(const std::string& stage) const;
    void ResetSessions() noexcept;
    SessionHolder CreateSession(const std::string& role,
                                const std::filesystem::path& model_path,
                                bool use_qnn,
                                bool require_full_offload);
    std::vector<Ort::Value> RunHtp(Ort::Session& session,
                                   const char* const* input_names,
                                   Ort::Value* inputs,
                                   size_t input_count,
                                   const char* const* output_names,
                                   size_t output_count);
    void RunHtp(Ort::Session& session, Ort::IoBinding& binding);
    [[nodiscard]] static int32_t CpuThreadCount();
    [[nodiscard]] std::filesystem::path ResolveModelFile(
        const std::filesystem::path& directory, const std::string& file_name) const;
    [[nodiscard]] std::string ContextKey(const std::string& role,
                                         const std::filesystem::path& model_path) const;
    [[nodiscard]] std::filesystem::path ContextModelPath(
        const std::string& role, const std::filesystem::path& model_path) const;

    [[nodiscard]] InputRows BuildInputRows(const std::vector<int32_t>& text_tokens,
                                           const std::string& voice) const;
    [[nodiscard]] PrefillResult RunPrefill(const InputRows& rows);
    [[nodiscard]] std::vector<std::vector<int32_t>> RunDecode(PrefillResult prefill,
                                                              int32_t max_frames,
                                                              uint64_t seed);
    [[nodiscard]] LocalFrameResult RunLocalFrame(
        const std::vector<float>& global_hidden,
        const std::vector<std::unordered_set<int32_t>>& previous_tokens,
        class RandomSource& random);
    [[nodiscard]] std::vector<float> DecodeAudioTokens(
        const std::vector<std::vector<int32_t>>& audio_tokens);

    [[nodiscard]] std::vector<std::vector<int32_t>> TokenizeChunks(
        const std::string& text, const std::string& voice) const;
    [[nodiscard]] size_t PrefillSequenceCapacity() const;
    static std::vector<int64_t> TensorShape(const Ort::Value& value);
    static size_t TensorElementCount(const Ort::Value& value);
    static std::vector<float> CopyFloatTensor(const Ort::Value& value);
    static std::vector<int32_t> CopyIntTensor(const Ort::Value& value);
    static void WritePcm16(std::ostream& output, const std::vector<float>& samples);
    static void WriteSilence(std::ostream& output, size_t sample_frames, uint16_t channels);
    static void WriteWavHeader(std::fstream& output, int32_t sample_rate, uint16_t channels,
                               int64_t sample_frames);
};
