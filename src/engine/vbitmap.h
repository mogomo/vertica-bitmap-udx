// vbitmap engine: one chunk of an entity set, its payload format and the set operations.
// Plain C++17, no Vertica headers. The format is described in docs/FORMAT.md.
//
// Entity IDs are nonnegative 64-bit integers. With chunk_bits = b (16 by default):
//     chunk_id = id >> b,  local_id = id & (2^b - 1),  id = (chunk_id << b) | local_id
// A Bitmap holds the local IDs of one chunk as a dense bitset of 2^b bits. Payloads store it
// either as a portable Roaring bitmap or as the raw bitset, whichever is smaller.
#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "vbitmap assumes a little-endian CPU");

namespace vbitmap {

inline constexpr int MIN_CHUNK_BITS = 8;
inline constexpr int MAX_CHUNK_BITS = 18;   // raw body 32,768 bytes: fits VARBINARY(65000)
inline constexpr int DEFAULT_CHUNK_BITS = 16;
inline constexpr size_t HEADER_SIZE = 16;
inline constexpr uint8_t FORMAT_VERSION = 1;

enum class Codec : uint8_t { Empty = 0, Roaring = 1, Raw = 2 };

// A payload that is not a valid vbitmap payload. Never treated as an empty set.
class FormatError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

// A valid request that cannot be served: local ID out of range, chunk widths that differ, ...
class UsageError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

void check_chunk_bits(int chunk_bits);   // UsageError unless MIN_CHUNK_BITS..MAX_CHUNK_BITS

inline int64_t chunk_of(int64_t id, int chunk_bits) { return id >> chunk_bits; }
inline uint32_t local_of(int64_t id, int chunk_bits) { return static_cast<uint32_t>(id & ((int64_t{1} << chunk_bits) - 1)); }
inline int64_t entity_of(int64_t chunk_id, uint32_t local_id, int chunk_bits) { return (chunk_id << chunk_bits) | local_id; }

class Bitmap {
public:
    explicit Bitmap(int chunk_bits = DEFAULT_CHUNK_BITS);

    int chunk_bits() const { return chunk_bits_; }
    uint32_t universe() const { return uint32_t{1} << chunk_bits_; }
    size_t word_count() const { return words_.size(); }
    const uint64_t *words() const { return words_.data(); }
    uint64_t *words() { return words_.data(); }

    void reset(int chunk_bits);              // empty set of the given width
    void clear();                            // empty set, same width
    void fill();                             // every local ID of the chunk
    void add(uint32_t local_id);             // UsageError if local_id >= universe()
    bool contains(uint32_t local_id) const;  // false if local_id >= universe()
    uint64_t cardinality() const;
    bool empty() const;

    // In-place set operations. UsageError if the chunk widths differ.
    void and_with(const Bitmap &o);
    void or_with(const Bitmap &o);
    void xor_with(const Bitmap &o);
    void andnot_with(const Bitmap &o);

    // Local IDs in ascending order (appended to out).
    void to_local_ids(std::vector<uint32_t> &out) const;

    bool operator==(const Bitmap &o) const { return chunk_bits_ == o.chunk_bits_ && words_ == o.words_; }
    bool operator!=(const Bitmap &o) const { return !(*this == o); }

private:
    void check_same_width(const Bitmap &o) const;
    int chunk_bits_;
    std::vector<uint64_t> words_;
};

uint64_t and_cardinality(const Bitmap &a, const Bitmap &b);

// Before a binary operation: an empty set takes the width of the other operand, so that the
// canonical empty payload combines with sets of any chunk width. UsageError if both sets are
// non-empty and their widths differ.
void align_widths(Bitmap &a, Bitmap &b);

// Header of a payload, after the cheap checks of inspect().
struct PayloadInfo {
    Codec codec;
    int chunk_bits;
    uint32_t cardinality;
    size_t size;        // whole payload, header included
};

// Cheap validation: header fields, length for the codec, checksum (header and body).
// Does not decode the body. FormatError if any check fails.
PayloadInfo inspect(const void *data, size_t size);

// "codec=roaring chunk_bits=16 cardinality=3 bytes=30" after a full decode.
std::string describe(const void *data, size_t size);

// Encodes and decodes payloads. Keeps scratch buffers between calls: one per thread.
class PayloadCodec {
public:
    PayloadCodec();
    ~PayloadCodec();
    PayloadCodec(const PayloadCodec &) = delete;
    PayloadCodec &operator=(const PayloadCodec &) = delete;

    // Full validation, then out = the set (out takes the payload's chunk width).
    void decode(const void *data, size_t size, Bitmap &out);
    // Full validation, then acc |= the set. Widths are aligned as in align_widths().
    void decode_or(const void *data, size_t size, Bitmap &acc);
    // Canonical payload: header alone for the empty set, else the smaller of Roaring and raw
    // (raw when equal). The same set always gives the same bytes.
    void encode(const Bitmap &b, std::vector<uint8_t> &out);

private:
    Bitmap tmp_;
    std::vector<uint32_t> ids_;
    std::vector<char> buf_;
    void *bitset_;   // roaring bitset_t, created on first use
};

// CRC-32C (Castagnoli), as used by the payload header. Hardware instruction when available.
uint32_t crc32c(const void *data, size_t size, uint32_t crc = 0);

// Version of the vendored CRoaring library.
const char *roaring_version();

// Raw size of the body for a chunk width.
inline size_t raw_body_size(int chunk_bits) { return (size_t{1} << chunk_bits) / 8; }

}  // namespace vbitmap
