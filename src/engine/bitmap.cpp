// Dense bitset of one chunk and its set operations.
#include "vbitmap.h"

#include <string>

// The word loops below are compiled three times on x86-64 with GCC (AVX2 with BMI and POPCNT,
// POPCNT alone, baseline) and the loader picks one per machine, so that one library file runs on
// every node of a cluster and still uses the hardware population count where it exists. The
// baseline x86-64 instruction set has none, and counting is the inner loop of facets and overlaps.
#if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__) && !defined(VBITMAP_NO_CLONES)
#if __GNUC__ >= 11
#define VBITMAP_KERNEL __attribute__((target_clones("arch=x86-64-v3", "popcnt", "default")))
#else
#define VBITMAP_KERNEL __attribute__((target_clones("avx2", "popcnt", "default")))
#endif
#else
#define VBITMAP_KERNEL
#endif

namespace {

VBITMAP_KERNEL uint64_t k_count(const uint64_t *w, size_t n)
{
    uint64_t c = 0;
    for (size_t i = 0; i < n; ++i) c += static_cast<uint64_t>(__builtin_popcountll(w[i]));
    return c;
}

VBITMAP_KERNEL uint64_t k_and_count(const uint64_t *a, const uint64_t *b, size_t n)
{
    uint64_t c = 0;
    for (size_t i = 0; i < n; ++i) c += static_cast<uint64_t>(__builtin_popcountll(a[i] & b[i]));
    return c;
}

VBITMAP_KERNEL void k_and(uint64_t *a, const uint64_t *b, size_t n)
{
    for (size_t i = 0; i < n; ++i) a[i] &= b[i];
}

VBITMAP_KERNEL void k_or(uint64_t *a, const uint64_t *b, size_t n)
{
    for (size_t i = 0; i < n; ++i) a[i] |= b[i];
}

VBITMAP_KERNEL void k_xor(uint64_t *a, const uint64_t *b, size_t n)
{
    for (size_t i = 0; i < n; ++i) a[i] ^= b[i];
}

VBITMAP_KERNEL void k_andnot(uint64_t *a, const uint64_t *b, size_t n)
{
    for (size_t i = 0; i < n; ++i) a[i] &= ~b[i];
}

VBITMAP_KERNEL bool k_any(const uint64_t *w, size_t n)
{
    uint64_t any = 0;
    for (size_t i = 0; i < n; ++i) any |= w[i];
    return any != 0;
}

}  // namespace

namespace vbitmap {

void check_chunk_bits(int chunk_bits)
{
    if (chunk_bits < MIN_CHUNK_BITS || chunk_bits > MAX_CHUNK_BITS)
        throw UsageError("chunk_bits must be between " + std::to_string(MIN_CHUNK_BITS) + " and " +
                         std::to_string(MAX_CHUNK_BITS) + ", not " + std::to_string(chunk_bits));
}

Bitmap::Bitmap(int chunk_bits) : chunk_bits_(chunk_bits)
{
    check_chunk_bits(chunk_bits);
    words_.assign((size_t{1} << chunk_bits) / 64, 0);
}

void Bitmap::reset(int chunk_bits)
{
    check_chunk_bits(chunk_bits);
    chunk_bits_ = chunk_bits;
    words_.assign((size_t{1} << chunk_bits) / 64, 0);
}

void Bitmap::clear()
{
    for (auto &w : words_) w = 0;
}

void Bitmap::fill()
{
    for (auto &w : words_) w = ~uint64_t{0};
}

void Bitmap::add(uint32_t local_id)
{
    if (local_id >= universe())
        throw UsageError("local ID " + std::to_string(local_id) + " is outside a chunk of " +
                         std::to_string(chunk_bits_) + " bits");
    words_[local_id >> 6] |= uint64_t{1} << (local_id & 63);
}

bool Bitmap::contains(uint32_t local_id) const
{
    return local_id < universe() && ((words_[local_id >> 6] >> (local_id & 63)) & 1);
}

uint64_t Bitmap::cardinality() const
{
    return k_count(words_.data(), words_.size());
}

bool Bitmap::empty() const
{
    return !k_any(words_.data(), words_.size());
}

void Bitmap::check_same_width(const Bitmap &o) const
{
    if (o.chunk_bits_ != chunk_bits_)
        throw UsageError("sets of different chunk widths (" + std::to_string(chunk_bits_) + " and " +
                         std::to_string(o.chunk_bits_) + " bits)");
}

void Bitmap::and_with(const Bitmap &o)
{
    check_same_width(o);
    k_and(words_.data(), o.words_.data(), words_.size());
}

void Bitmap::or_with(const Bitmap &o)
{
    check_same_width(o);
    k_or(words_.data(), o.words_.data(), words_.size());
}

void Bitmap::xor_with(const Bitmap &o)
{
    check_same_width(o);
    k_xor(words_.data(), o.words_.data(), words_.size());
}

void Bitmap::andnot_with(const Bitmap &o)
{
    check_same_width(o);
    k_andnot(words_.data(), o.words_.data(), words_.size());
}

void Bitmap::to_local_ids(std::vector<uint32_t> &out) const
{
    for (size_t i = 0; i < words_.size(); ++i) {
        uint64_t w = words_[i];
        while (w) {
            out.push_back(static_cast<uint32_t>(i * 64 + static_cast<size_t>(__builtin_ctzll(w))));
            w &= w - 1;
        }
    }
}

void align_widths(Bitmap &a, Bitmap &b)
{
    if (a.chunk_bits() == b.chunk_bits()) return;
    if (a.empty()) a.reset(b.chunk_bits());
    else if (b.empty()) b.reset(a.chunk_bits());
    else
        throw UsageError("sets of different chunk widths (" + std::to_string(a.chunk_bits()) + " and " +
                         std::to_string(b.chunk_bits()) + " bits)");
}

uint64_t and_cardinality(const Bitmap &a, const Bitmap &b)
{
    if (a.chunk_bits() != b.chunk_bits())
        throw UsageError("sets of different chunk widths (" + std::to_string(a.chunk_bits()) + " and " +
                         std::to_string(b.chunk_bits()) + " bits)");
    return k_and_count(a.words(), b.words(), a.word_count());
}

}  // namespace vbitmap
