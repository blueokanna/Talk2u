#include "SentencePieceTokenizer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <queue>
#include <stdexcept>
#include <utility>

namespace {

constexpr uint32_t kWireVarint = 0;
constexpr uint32_t kWireFixed64 = 1;
constexpr uint32_t kWireLengthDelimited = 2;
constexpr uint32_t kWireFixed32 = 5;

class ProtoReader final {
public:
    explicit ProtoReader(std::vector<uint8_t> bytes)
        : owned_(std::move(bytes)), data_(owned_.data()), size_(owned_.size()) {}

    ProtoReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

    [[nodiscard]] bool HasMore() const { return position_ < size_; }

    uint64_t Varint() {
        uint64_t value = 0;
        for (uint32_t shift = 0; shift < 64; shift += 7) {
            Require(1);
            const uint8_t byte = data_[position_++];
            value |= static_cast<uint64_t>(byte & 0x7FU) << shift;
            if ((byte & 0x80U) == 0) return value;
        }
        throw std::runtime_error("SentencePiece protobuf varint is too long");
    }

    std::pair<uint32_t, uint32_t> Tag() {
        const uint64_t tag = Varint();
        if ((tag >> 3U) == 0) throw std::runtime_error("Invalid SentencePiece protobuf tag");
        return {static_cast<uint32_t>(tag >> 3U), static_cast<uint32_t>(tag & 7U)};
    }

    std::string String() {
        const auto [bytes, length] = Bytes();
        return {reinterpret_cast<const char*>(bytes), length};
    }

    float Float() {
        Require(4);
        float value;
        std::memcpy(&value, data_ + position_, sizeof(value));
        position_ += 4;
        return value;
    }

    ProtoReader Message() {
        const auto [bytes, length] = Bytes();
        return {bytes, length};
    }

    void Skip(uint32_t wire_type) {
        switch (wire_type) {
            case kWireVarint:
                static_cast<void>(Varint());
                return;
            case kWireFixed64:
                Require(8);
                position_ += 8;
                return;
            case kWireLengthDelimited: {
                const size_t length = CheckedSize(Varint());
                Require(length);
                position_ += length;
                return;
            }
            case kWireFixed32:
                Require(4);
                position_ += 4;
                return;
            default:
                throw std::runtime_error("Unsupported SentencePiece protobuf wire type");
        }
    }

private:
    std::vector<uint8_t> owned_;
    const uint8_t* data_ = nullptr;
    size_t size_ = 0;
    size_t position_ = 0;

    [[nodiscard]] static size_t CheckedSize(uint64_t value) {
        if (value > std::numeric_limits<size_t>::max()) {
            throw std::runtime_error("SentencePiece protobuf field is too large");
        }
        return static_cast<size_t>(value);
    }

    std::pair<const uint8_t*, size_t> Bytes() {
        const size_t length = CheckedSize(Varint());
        Require(length);
        const uint8_t* result = data_ + position_;
        position_ += length;
        return {result, length};
    }

    void Require(size_t count) const {
        if (count > size_ - position_) {
            throw std::runtime_error("Truncated SentencePiece protobuf model");
        }
    }
};

size_t Utf8CodePointLength(const std::string& text, size_t offset) {
    if (offset >= text.size()) return 0;
    const uint8_t first = static_cast<uint8_t>(text[offset]);
    size_t length = 1;
    if ((first & 0xE0U) == 0xC0U) length = 2;
    else if ((first & 0xF0U) == 0xE0U) length = 3;
    else if ((first & 0xF8U) == 0xF0U) length = 4;
    if (offset + length > text.size()) return 1;
    for (size_t i = 1; i < length; ++i) {
        if ((static_cast<uint8_t>(text[offset + i]) & 0xC0U) != 0x80U) return 1;
    }
    return length;
}

uint32_t DecodeUtf8(const std::string& text, size_t offset, size_t length) {
    const uint8_t first = static_cast<uint8_t>(text[offset]);
    if (length == 1) return first;
    uint32_t value = first & ((1U << (7U - static_cast<uint32_t>(length))) - 1U);
    for (size_t i = 1; i < length; ++i) {
        value = (value << 6U) | (static_cast<uint8_t>(text[offset + i]) & 0x3FU);
    }
    return value;
}

void AppendUtf8(std::string& output, uint32_t codepoint) {
    if (codepoint <= 0x7FU) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7FFU) {
        output.push_back(static_cast<char>(0xC0U | (codepoint >> 6U)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3FU)));
    } else if (codepoint <= 0xFFFFU) {
        output.push_back(static_cast<char>(0xE0U | (codepoint >> 12U)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3FU)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3FU)));
    } else {
        output.push_back(static_cast<char>(0xF0U | (codepoint >> 18U)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 12U) & 0x3FU)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3FU)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3FU)));
    }
}

bool IsWhitespace(uint32_t codepoint) {
    if (codepoint == 0x20U || (codepoint >= 0x09U && codepoint <= 0x0DU)) return true;
    return codepoint == 0x85U || codepoint == 0xA0U || codepoint == 0x1680U ||
           (codepoint >= 0x2000U && codepoint <= 0x200AU) || codepoint == 0x2028U ||
           codepoint == 0x2029U || codepoint == 0x202FU || codepoint == 0x205FU ||
           codepoint == 0x3000U;
}

}  // namespace

SentencePieceTokenizer::SentencePieceTokenizer(const std::string& model_path) {
    LoadModel(model_path);
    BuildIndex();
}

void SentencePieceTokenizer::LoadModel(const std::string& model_path) {
    std::ifstream input(model_path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("Cannot open tokenizer.model: " + model_path);
    const std::streamsize length = input.tellg();
    if (length <= 0 || length > 64 * 1024 * 1024) {
        throw std::runtime_error("Invalid tokenizer.model size");
    }
    input.seekg(0);
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    if (!input.read(reinterpret_cast<char*>(bytes.data()), length)) {
        throw std::runtime_error("Cannot read tokenizer.model");
    }

    ProtoReader root(std::move(bytes));
    while (root.HasMore()) {
        const auto [field, wire] = root.Tag();
        if (field == 1 && wire == kWireLengthDelimited) {
            ProtoReader piece_reader = root.Message();
            Piece piece;
            while (piece_reader.HasMore()) {
                const auto [piece_field, piece_wire] = piece_reader.Tag();
                if (piece_field == 1 && piece_wire == kWireLengthDelimited) {
                    piece.text = piece_reader.String();
                } else if (piece_field == 2 && piece_wire == kWireFixed32) {
                    piece.score = piece_reader.Float();
                } else if (piece_field == 3 && piece_wire == kWireVarint) {
                    piece.type = static_cast<PieceType>(piece_reader.Varint());
                } else {
                    piece_reader.Skip(piece_wire);
                }
            }
            pieces_.push_back(std::move(piece));
        } else if (field == 2 && wire == kWireLengthDelimited) {
            ProtoReader trainer = root.Message();
            while (trainer.HasMore()) {
                const auto [trainer_field, trainer_wire] = trainer.Tag();
                if (trainer_field == 3 && trainer_wire == kWireVarint) {
                    const auto type = static_cast<int32_t>(trainer.Varint());
                    if (type != static_cast<int32_t>(ModelType::Unigram) &&
                        type != static_cast<int32_t>(ModelType::Bpe)) {
                        throw std::runtime_error("Only SentencePiece Unigram and BPE models are supported");
                    }
                    model_type_ = static_cast<ModelType>(type);
                } else if (trainer_field == 35 && trainer_wire == kWireVarint) {
                    byte_fallback_ = trainer.Varint() != 0;
                } else if (trainer_field == 40 && trainer_wire == kWireVarint) {
                    unknown_id_ = static_cast<int32_t>(trainer.Varint());
                } else {
                    trainer.Skip(trainer_wire);
                }
            }
        } else if (field == 3 && wire == kWireLengthDelimited) {
            ProtoReader normalizer = root.Message();
            while (normalizer.HasMore()) {
                const auto [normalizer_field, normalizer_wire] = normalizer.Tag();
                if (normalizer_field == 3 && normalizer_wire == kWireVarint) {
                    add_dummy_prefix_ = normalizer.Varint() != 0;
                } else if (normalizer_field == 4 && normalizer_wire == kWireVarint) {
                    remove_extra_whitespaces_ = normalizer.Varint() != 0;
                } else if (normalizer_field == 5 && normalizer_wire == kWireVarint) {
                    escape_whitespaces_ = normalizer.Varint() != 0;
                } else {
                    normalizer.Skip(normalizer_wire);
                }
            }
        } else {
            root.Skip(wire);
        }
    }
    if (pieces_.empty() || unknown_id_ < 0 || static_cast<size_t>(unknown_id_) >= pieces_.size()) {
        throw std::runtime_error("tokenizer.model has no valid vocabulary or unknown token");
    }
}

void SentencePieceTokenizer::BuildIndex() {
    for (size_t id = 0; id < pieces_.size(); ++id) {
        const Piece& piece = pieces_[id];
        piece_to_id_.emplace(piece.text, static_cast<int32_t>(id));
        if (piece.type == PieceType::Byte && piece.text.size() == 6 &&
            piece.text.starts_with("<0x") && piece.text.back() == '>') {
            try {
                const auto value = static_cast<uint8_t>(std::stoul(piece.text.substr(3, 2), nullptr, 16));
                byte_to_id_[value] = static_cast<int32_t>(id);
            } catch (...) {
                // Invalid byte token remains a regular vocabulary entry.
            }
        }
        if (piece.text.empty() || piece.type == PieceType::Control ||
            piece.type == PieceType::Unknown || piece.type == PieceType::Unused ||
            piece.type == PieceType::Byte) {
            continue;
        }
        size_t node = 0;
        for (const unsigned char byte : piece.text) {
            auto [it, inserted] = trie_[node].children.try_emplace(byte, trie_.size());
            if (inserted) trie_.push_back({});
            node = it->second;
        }
        trie_[node].piece_id = static_cast<int32_t>(id);
    }
}

std::string SentencePieceTokenizer::Normalize(const std::string& text) const {
    std::string normalized;
    normalized.reserve(text.size() + 4);
    bool previous_space = false;
    for (size_t offset = 0; offset < text.size();) {
        const size_t length = Utf8CodePointLength(text, offset);
        uint32_t codepoint = DecodeUtf8(text, offset, length);
        offset += length;
        if (codepoint == 0x3000U) codepoint = 0x20U;
        else if (codepoint >= 0xFF01U && codepoint <= 0xFF5EU) codepoint -= 0xFEE0U;

        const bool space = IsWhitespace(codepoint);
        if (space && remove_extra_whitespaces_) {
            if (previous_space || normalized.empty()) continue;
            normalized.push_back(' ');
            previous_space = true;
        } else {
            AppendUtf8(normalized, codepoint);
            previous_space = space;
        }
    }
    if (remove_extra_whitespaces_ && !normalized.empty() && normalized.back() == ' ') {
        normalized.pop_back();
    }
    if (add_dummy_prefix_ && !normalized.empty() && normalized.front() != ' ') {
        normalized.insert(normalized.begin(), ' ');
    }
    if (escape_whitespaces_) {
        std::string escaped;
        escaped.reserve(normalized.size() + 4);
        for (char value : normalized) {
            if (value == ' ') escaped.append("\xE2\x96\x81");
            else escaped.push_back(value);
        }
        return escaped;
    }
    return normalized;
}

std::vector<std::pair<size_t, int32_t>> SentencePieceTokenizer::Matches(
    const std::string& text, size_t offset) const {
    std::vector<std::pair<size_t, int32_t>> matches;
    size_t node = 0;
    for (size_t cursor = offset; cursor < text.size(); ++cursor) {
        const auto found = trie_[node].children.find(static_cast<uint8_t>(text[cursor]));
        if (found == trie_[node].children.end()) break;
        node = found->second;
        if (trie_[node].piece_id >= 0) matches.emplace_back(cursor + 1, trie_[node].piece_id);
    }
    return matches;
}

std::vector<int32_t> SentencePieceTokenizer::UnknownBytes(
    const std::string& text, size_t offset, size_t length) const {
    if (!byte_fallback_) return {unknown_id_};
    std::vector<int32_t> result;
    result.reserve(length);
    for (size_t index = offset; index < offset + length; ++index) {
        const auto found = byte_to_id_.find(static_cast<uint8_t>(text[index]));
        if (found == byte_to_id_.end()) return {unknown_id_};
        result.push_back(found->second);
    }
    return result;
}

std::vector<int32_t> SentencePieceTokenizer::Encode(const std::string& text) const {
    if (text.empty()) return {};
    const std::string normalized = Normalize(text);
    return model_type_ == ModelType::Bpe ? EncodeBpe(normalized) : EncodeUnigram(normalized);
}

std::vector<int32_t> SentencePieceTokenizer::EncodeUnigram(const std::string& normalized) const {
    struct State { float score = -std::numeric_limits<float>::infinity(); size_t previous = 0; int32_t id = -1; };
    std::vector<State> best(normalized.size() + 1);
    best[0].score = 0.0F;
    float minimum_score = 0.0F;
    for (const Piece& piece : pieces_) minimum_score = std::min(minimum_score, piece.score);

    for (size_t offset = 0; offset < normalized.size(); ++offset) {
        if (!std::isfinite(best[offset].score)) continue;
        const auto matches = Matches(normalized, offset);
        for (const auto& [end, id] : matches) {
            const float candidate = best[offset].score + pieces_[static_cast<size_t>(id)].score;
            if (candidate > best[end].score) best[end] = {candidate, offset, id};
        }
        const size_t length = Utf8CodePointLength(normalized, offset);
        const size_t end = offset + length;
        const float unknown_score = best[offset].score + minimum_score - 10.0F;
        if (unknown_score > best[end].score) best[end] = {unknown_score, offset, -1};
    }
    if (best.back().id == -1 && best.back().previous == 0 && normalized.size() > 1) {
        throw std::runtime_error("SentencePiece failed to tokenize input");
    }

    std::vector<std::pair<size_t, int32_t>> reversed;
    for (size_t cursor = normalized.size(); cursor > 0;) {
        const State& state = best[cursor];
        if (!std::isfinite(state.score) || state.previous >= cursor) {
            throw std::runtime_error("SentencePiece unigram backtracking failed");
        }
        reversed.emplace_back(cursor, state.id);
        cursor = state.previous;
    }
    std::reverse(reversed.begin(), reversed.end());
    std::vector<int32_t> result;
    size_t previous = 0;
    for (const auto& [end, id] : reversed) {
        if (id >= 0) result.push_back(id);
        else {
            auto bytes = UnknownBytes(normalized, previous, end - previous);
            result.insert(result.end(), bytes.begin(), bytes.end());
        }
        previous = end;
    }
    return result;
}

std::vector<int32_t> SentencePieceTokenizer::EncodeBpe(const std::string& normalized) const {
    struct Symbol { std::string text; int32_t id = -1; bool active = true; int previous = -1; int next = -1; };
    struct Merge { float score; int left; int right; uint64_t generation; };
    struct Compare { bool operator()(const Merge& a, const Merge& b) const { return a.score < b.score; } };

    std::vector<Symbol> symbols;
    for (size_t offset = 0; offset < normalized.size();) {
        const size_t length = Utf8CodePointLength(normalized, offset);
        std::string symbol = normalized.substr(offset, length);
        const auto found = piece_to_id_.find(symbol);
        if (found != piece_to_id_.end()) {
            symbols.push_back({std::move(symbol), found->second, true,
                               static_cast<int>(symbols.size()) - 1, -1});
        } else {
            auto bytes = UnknownBytes(normalized, offset, length);
            for (int32_t id : bytes) {
                symbols.push_back({pieces_[static_cast<size_t>(id)].text, id, true,
                                   static_cast<int>(symbols.size()) - 1, -1});
            }
        }
        offset += length;
    }
    for (size_t i = 0; i < symbols.size(); ++i) {
        symbols[i].previous = i == 0 ? -1 : static_cast<int>(i - 1);
        symbols[i].next = i + 1 == symbols.size() ? -1 : static_cast<int>(i + 1);
    }

    std::priority_queue<Merge, std::vector<Merge>, Compare> queue;
    uint64_t generation = 0;
    auto enqueue = [&](int left) {
        if (left < 0 || !symbols[static_cast<size_t>(left)].active) return;
        const int right = symbols[static_cast<size_t>(left)].next;
        if (right < 0 || !symbols[static_cast<size_t>(right)].active) return;
        const std::string merged = symbols[static_cast<size_t>(left)].text +
                                   symbols[static_cast<size_t>(right)].text;
        const auto found = piece_to_id_.find(merged);
        if (found != piece_to_id_.end()) {
            queue.push({pieces_[static_cast<size_t>(found->second)].score, left, right, generation++});
        }
    };
    for (size_t i = 0; i < symbols.size(); ++i) enqueue(static_cast<int>(i));

    while (!queue.empty()) {
        const Merge merge = queue.top();
        queue.pop();
        Symbol& left = symbols[static_cast<size_t>(merge.left)];
        Symbol& right = symbols[static_cast<size_t>(merge.right)];
        if (!left.active || !right.active || left.next != merge.right || right.previous != merge.left) continue;
        const std::string merged = left.text + right.text;
        const auto found = piece_to_id_.find(merged);
        if (found == piece_to_id_.end() || pieces_[static_cast<size_t>(found->second)].score != merge.score) continue;
        left.text = merged;
        left.id = found->second;
        left.next = right.next;
        if (right.next >= 0) symbols[static_cast<size_t>(right.next)].previous = merge.left;
        right.active = false;
        enqueue(left.previous);
        enqueue(merge.left);
    }

    std::vector<int32_t> result;
    int cursor = symbols.empty() ? -1 : 0;
    while (cursor >= 0) {
        const Symbol& symbol = symbols[static_cast<size_t>(cursor)];
        if (symbol.active) result.push_back(symbol.id);
        cursor = symbol.next;
    }
    return result;
}
