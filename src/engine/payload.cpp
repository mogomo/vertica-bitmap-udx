// Payload format (docs/FORMAT.md): 16-byte header, then a portable Roaring bitmap or the raw
// bitset. Every reader check of the format is here; a payload that fails one raises FormatError.
#include "vbitmap.h"

#include "roaring.h"

#include <algorithm>
#include <cstring>
#include <memory>

namespace vbitmap {

using roaring::api::roaring_bitmap_t;
using roaring::api::bitset_t;

namespace {

constexpr unsigned char MAGIC[4] = {'V', 'B', 'M', '1'};

[[noreturn]] void bad(const std::string &why) { throw FormatError("invalid bitmap payload: " + why); }

uint32_t load32(const unsigned char *p)
{
    uint32_t v;
    std::memcpy(&v, p, 4);
    return v;
}

void store32(unsigned char *p, uint32_t v) { std::memcpy(p, &v, 4); }

uint32_t payload_crc(const unsigned char *p, size_t size)
{
    // Covers the first 12 header bytes (everything except the checksum itself) and the body.
    uint32_t crc = crc32c(p, 12);
    return crc32c(p + HEADER_SIZE, size - HEADER_SIZE, crc);
}

struct RoaringDeleter {
    void operator()(roaring_bitmap_t *r) const { roaring::api::roaring_bitmap_free(r); }
};
using RoaringPtr = std::unique_ptr<roaring_bitmap_t, RoaringDeleter>;

// Lower bound of the portable Roaring size: per 65,536-value container the smallest of the
// array (2 bytes per value), run (2 + 4 per run) and bitset (8,192 bytes) forms, plus the
// 4-byte cookie. Used only to skip building a Roaring bitmap when it cannot beat the raw form.
size_t roaring_size_lower_bound(const Bitmap &b)
{
    const size_t words_per_container = 65536 / 64;
    size_t total = 4;
    for (size_t start = 0; start < b.word_count(); start += words_per_container) {
        const size_t end = std::min(b.word_count(), start + words_per_container);
        uint64_t card = 0, runs = 0, prev_top = 0;
        for (size_t i = start; i < end; ++i) {
            const uint64_t w = b.words()[i];
            card += static_cast<uint64_t>(__builtin_popcountll(w));
            // run starts: bits set whose lower neighbour is clear
            runs += static_cast<uint64_t>(__builtin_popcountll(w & ~((w << 1) | prev_top)));
            prev_top = w >> 63;
        }
        if (card == 0) continue;
        total += std::min<uint64_t>({2 * card, 2 + 4 * runs, 8192});
    }
    return total;
}

}  // namespace

PayloadInfo inspect(const void *data, size_t size)
{
    const auto *p = static_cast<const unsigned char *>(data);
    if (data == nullptr || size < HEADER_SIZE) bad("shorter than the 16-byte header");
    if (std::memcmp(p, MAGIC, 4) != 0) bad("wrong magic");
    if (p[4] != FORMAT_VERSION) bad("unknown format version " + std::to_string(p[4]));
    if (p[5] > static_cast<uint8_t>(Codec::Raw)) bad("unknown codec " + std::to_string(p[5]));
    const int cb = p[6];
    if (cb < MIN_CHUNK_BITS || cb > MAX_CHUNK_BITS) bad("chunk bits " + std::to_string(cb) + " out of range");
    if (p[7] != 0) bad("reserved byte is not zero");

    PayloadInfo info;
    info.codec = static_cast<Codec>(p[5]);
    info.chunk_bits = cb;
    info.cardinality = load32(p + 8);
    info.size = size;
    const size_t body = size - HEADER_SIZE;
    const size_t raw = raw_body_size(cb);
    const uint64_t universe = uint64_t{1} << cb;

    switch (info.codec) {
    case Codec::Empty:
        if (body != 0) bad("empty codec with a body");
        if (info.cardinality != 0) bad("empty codec with a nonzero cardinality");
        break;
    case Codec::Raw:
        if (body != raw) bad("raw body of " + std::to_string(body) + " bytes, expected " + std::to_string(raw));
        if (info.cardinality == 0 || info.cardinality > universe) bad("cardinality out of range for the codec");
        break;
    case Codec::Roaring:
        if (body == 0 || body >= raw) bad("Roaring body of " + std::to_string(body) + " bytes (not smaller than raw)");
        if (info.cardinality == 0 || info.cardinality > universe) bad("cardinality out of range for the codec");
        break;
    }
    if (payload_crc(p, size) != load32(p + 12)) bad("checksum mismatch");
    return info;
}

PayloadCodec::PayloadCodec() : tmp_(DEFAULT_CHUNK_BITS), bitset_(nullptr) {}

PayloadCodec::~PayloadCodec()
{
    if (bitset_) roaring::api::bitset_free(static_cast<bitset_t *>(bitset_));
}

void PayloadCodec::decode(const void *data, size_t size, Bitmap &out)
{
    const PayloadInfo info = inspect(data, size);
    const auto *body = static_cast<const unsigned char *>(data) + HEADER_SIZE;
    const size_t body_size = size - HEADER_SIZE;
    if (out.chunk_bits() != info.chunk_bits) out.reset(info.chunk_bits);

    switch (info.codec) {
    case Codec::Empty:
        out.clear();
        return;
    case Codec::Raw:
        std::memcpy(out.words(), body, body_size);
        if (out.cardinality() != info.cardinality) bad("cardinality in the header does not match the body");
        return;
    case Codec::Roaring:
        break;
    }

    const char *buf = reinterpret_cast<const char *>(body);
    if (roaring::api::roaring_bitmap_portable_deserialize_size(buf, body_size) != body_size)
        bad("Roaring body is malformed or has trailing bytes");
    RoaringPtr r(roaring::api::roaring_bitmap_portable_deserialize_safe(buf, body_size));
    if (!r) bad("Roaring body cannot be read");
    const char *reason = nullptr;
    if (!roaring::api::roaring_bitmap_internal_validate(r.get(), &reason))
        bad(std::string("Roaring body is inconsistent: ") + (reason ? reason : "?"));
    if (roaring::api::roaring_bitmap_get_cardinality(r.get()) != info.cardinality)
        bad("cardinality in the header does not match the body");
    // cardinality >= 1 (inspect), so the maximum exists
    if (roaring::api::roaring_bitmap_maximum(r.get()) >= out.universe()) bad("value outside the chunk");

    if (!bitset_) {
        bitset_ = roaring::api::bitset_create_with_capacity(size_t{1} << MAX_CHUNK_BITS);
        if (!bitset_) throw std::bad_alloc();
    }
    auto *bs = static_cast<bitset_t *>(bitset_);
    roaring::api::bitset_clear(bs);   // to_bitset expects an empty bitset
    if (!roaring::api::roaring_bitmap_to_bitset(r.get(), bs)) throw std::bad_alloc();
    out.clear();
    const size_t n = std::min(bs->arraysize, out.word_count());
    std::memcpy(out.words(), bs->array, n * sizeof(uint64_t));
}

void PayloadCodec::decode_or(const void *data, size_t size, Bitmap &acc)
{
    decode(data, size, tmp_);
    align_widths(acc, tmp_);
    acc.or_with(tmp_);
}

void PayloadCodec::encode(const Bitmap &b, std::vector<uint8_t> &out)
{
    const uint64_t card = b.cardinality();
    const size_t raw = raw_body_size(b.chunk_bits());
    Codec codec = Codec::Empty;
    size_t body = 0;
    RoaringPtr r;

    if (card > 0) {
        codec = Codec::Raw;
        body = raw;
        if (roaring_size_lower_bound(b) < raw) {
            ids_.clear();
            b.to_local_ids(ids_);
            r.reset(roaring::api::roaring_bitmap_create_with_capacity(0));
            if (!r) throw std::bad_alloc();
            roaring::api::roaring_bitmap_add_many(r.get(), ids_.size(), ids_.data());
            roaring::api::roaring_bitmap_run_optimize(r.get());
            const size_t rsize = roaring::api::roaring_bitmap_portable_size_in_bytes(r.get());
            if (rsize < raw) {
                codec = Codec::Roaring;
                body = rsize;
            }
        }
    }

    out.resize(HEADER_SIZE + body);
    unsigned char *p = out.data();
    std::memcpy(p, MAGIC, 4);
    p[4] = FORMAT_VERSION;
    p[5] = static_cast<uint8_t>(codec);
    p[6] = static_cast<uint8_t>(b.chunk_bits());
    p[7] = 0;
    store32(p + 8, static_cast<uint32_t>(card));
    if (codec == Codec::Raw) {
        std::memcpy(p + HEADER_SIZE, b.words(), raw);
    } else if (codec == Codec::Roaring) {
        const size_t written = roaring::api::roaring_bitmap_portable_serialize(r.get(), reinterpret_cast<char *>(p + HEADER_SIZE));
        if (written != body) throw std::logic_error("Roaring serialization wrote an unexpected size");
    }
    store32(p + 12, payload_crc(p, out.size()));
}

const char *roaring_version() { return ROARING_VERSION; }

std::string describe(const void *data, size_t size)
{
    PayloadCodec codec;
    Bitmap b;
    codec.decode(data, size, b);
    const PayloadInfo info = inspect(data, size);
    static const char *names[] = {"empty", "roaring", "raw"};
    return std::string("codec=") + names[static_cast<int>(info.codec)] + " chunk_bits=" + std::to_string(info.chunk_bits) +
           " cardinality=" + std::to_string(info.cardinality) + " bytes=" + std::to_string(size);
}

}  // namespace vbitmap
