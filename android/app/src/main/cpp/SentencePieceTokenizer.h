#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

class SentencePieceTokenizer final {
public:
    explicit SentencePieceTokenizer(const std::string& model_path);

    [[nodiscard]] std::vector<int32_t> Encode(const std::string& text) const;

private:
    enum class ModelType : int32_t { Unigram = 1, Bpe = 2 };
    enum class PieceType : int32_t {
        Normal = 1,
        Unknown = 2,
        Control = 3,
        UserDefined = 4,
        Unused = 5,
        Byte = 6,
    };

    struct Piece {
        std::string text;
        float score = 0.0F;
        PieceType type = PieceType::Normal;
    };

    struct TrieNode {
        std::unordered_map<uint8_t, size_t> children;
        int32_t piece_id = -1;
    };

    std::vector<Piece> pieces_;
    std::vector<TrieNode> trie_{1};
    std::unordered_map<std::string, int32_t> piece_to_id_;
    std::unordered_map<uint8_t, int32_t> byte_to_id_;
    ModelType model_type_ = ModelType::Unigram;
    int32_t unknown_id_ = 0;
    bool byte_fallback_ = false;
    bool add_dummy_prefix_ = true;
    bool remove_extra_whitespaces_ = true;
    bool escape_whitespaces_ = true;

    void LoadModel(const std::string& model_path);
    void BuildIndex();
    [[nodiscard]] std::string Normalize(const std::string& text) const;
    [[nodiscard]] std::vector<int32_t> EncodeUnigram(const std::string& normalized) const;
    [[nodiscard]] std::vector<int32_t> EncodeBpe(const std::string& normalized) const;
    [[nodiscard]] std::vector<std::pair<size_t, int32_t>> Matches(
        const std::string& text, size_t offset) const;
    [[nodiscard]] std::vector<int32_t> UnknownBytes(
        const std::string& text, size_t offset, size_t length) const;
};
