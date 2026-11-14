// Payload format: round trips, canonical codec choice, every class of malformed payload.
#include "test_util.h"

#include "roaring.h"

#include <cstring>

using test::RefSet;
using vbitmap::Bitmap;
using vbitmap::Codec;
using vbitmap::FormatError;
using vbitmap::PayloadCodec;
using Bytes = std::vector<uint8_t>;

static PayloadCodec codec;

static Bytes encode(const Bitmap &b)
{
    Bytes out;
    codec.encode(b, out);
    return out;
}

// Rewrites the checksum so that a deliberately corrupted payload reaches the deeper checks.
static void reseal(Bytes &p)
{
    uint32_t crc = vbitmap::crc32c(p.data(), 12);
    crc = vbitmap::crc32c(p.data() + 16, p.size() - 16, crc);
    std::memcpy(p.data() + 12, &crc, 4);
}

static bool rejects(const Bytes &p)
{
    Bitmap b;
    try {
        codec.decode(p.data(), p.size(), b);
    } catch (const FormatError &) {
        return true;   // a corrupt payload is an error, never an empty set
    }
    return false;
}

// Independent computation of the expected codec and size with CRoaring itself.
static void expected_form(const Bitmap &b, Codec &codec_out, size_t &size_out)
{
    const uint64_t card = b.cardinality();
    const size_t raw = vbitmap::raw_body_size(b.chunk_bits());
    if (card == 0) {
        codec_out = Codec::Empty;
        size_out = 16;
        return;
    }
    std::vector<uint32_t> ids;
    b.to_local_ids(ids);
    roaring::api::roaring_bitmap_t *r = roaring::api::roaring_bitmap_of_ptr(ids.size(), ids.data());
    roaring::api::roaring_bitmap_run_optimize(r);
    const size_t rs = roaring::api::roaring_bitmap_portable_size_in_bytes(r);
    roaring::api::roaring_bitmap_free(r);
    codec_out = rs < raw ? Codec::Roaring : Codec::Raw;
    size_out = 16 + (rs < raw ? rs : raw);
}

static void round_trip(const RefSet &s, int cb)
{
    const Bitmap b = test::to_bitmap(s, cb);
    const Bytes p = encode(b);
    Bitmap back(vbitmap::DEFAULT_CHUNK_BITS);
    codec.decode(p.data(), p.size(), back);
    CHECK(back == b);
    CHECK(back.chunk_bits() == cb);
    const vbitmap::PayloadInfo info = vbitmap::inspect(p.data(), p.size());
    CHECK(info.cardinality == s.size() && info.chunk_bits == cb && info.size == p.size());
    CHECK(encode(back) == p);   // canonical: the same set gives the same bytes
    Codec want;
    size_t want_size;
    expected_form(b, want, want_size);
    CHECK(info.codec == want);
    CHECK(p.size() == want_size);
}

static void round_trips()
{
    for (int cb : {8, 12, 16, 17, 18}) {
        for (double d : test::densities()) round_trip(test::random_ref(cb, d), cb);
        for (int runs : {1, 5, 50, 500}) round_trip(test::random_runs(cb, runs, 200), cb);
        RefSet edge = {0, (1u << cb) - 1};
        round_trip(edge, cb);
        round_trip(RefSet{0}, cb);
        round_trip(RefSet{(1u << cb) - 1}, cb);
    }
    // Codec crossover in a 16-bit chunk: n random values, Roaring array (2n bytes) against raw 8,192.
    // Both sides of the crossover must be reached.
    int seen[3] = {0, 0, 0};
    for (uint32_t n = 4060; n <= 4110; ++n) {
        RefSet s;
        std::uniform_int_distribution<uint32_t> v(0, 65535);
        while (s.size() < n) s.insert(v(test::rng()));
        round_trip(s, 16);
        ++seen[encode(test::to_bitmap(s, 16))[5]];
    }
    CHECK(seen[1] > 0 && seen[2] > 0);
    // 18-bit chunk with one sparse and three dense containers: mixed forms.
    RefSet mixed = test::random_ref(18, 0.4);
    for (auto it = mixed.begin(); it != mixed.end();) it = (*it < 65536 && (*it % 97)) ? mixed.erase(it) : std::next(it);
    round_trip(mixed, 18);

    Bitmap empty(16);
    const Bytes pe = encode(empty);
    CHECK(pe.size() == 16 && pe[5] == 0);
    Bitmap full(16);
    full.fill();
    const Bytes pf = encode(full);
    CHECK(pf[5] == static_cast<uint8_t>(Codec::Roaring) && pf.size() < 40);   // one run
}

static void decode_or_many()
{
    Bitmap acc(16);
    RefSet want;
    for (int i = 0; i < 30; ++i) {
        const RefSet s = (i % 3) ? test::random_ref(16, 0.001 * i) : test::random_runs(16, 3, 1000);
        want.insert(s.begin(), s.end());
        const Bytes p = encode(test::to_bitmap(s, 16));
        codec.decode_or(p.data(), p.size(), acc);
    }
    CHECK(test::to_ref(acc) == want);
    // An empty accumulator takes the width of the first set; an empty payload of another width is neutral.
    Bitmap other(18);
    const Bytes p = encode(test::to_bitmap(RefSet{1, 2}, 16));
    codec.decode_or(p.data(), p.size(), other);
    CHECK(other.chunk_bits() == 16 && other.cardinality() == 2);
    const Bytes e18 = encode(Bitmap(18));
    codec.decode_or(e18.data(), e18.size(), other);
    CHECK(other.chunk_bits() == 16 && other.cardinality() == 2);
    Bitmap full18(18);
    full18.add(5);
    CHECK_THROWS(vbitmap::UsageError, codec.decode_or(p.data(), p.size(), full18));
}

static std::vector<Bytes> samples()
{
    std::vector<Bytes> v;
    for (int cb : {8, 16}) {
        v.push_back(encode(Bitmap(cb)));                                      // empty
        v.push_back(encode(test::to_bitmap(RefSet{0, 3, 77}, cb)));           // Roaring array
        v.push_back(encode(test::to_bitmap(test::random_runs(cb, 4, 50), cb)));   // Roaring runs
        v.push_back(encode(test::to_bitmap(test::random_ref(cb, 0.5), cb)));  // raw
    }
    return v;
}

static void malformed()
{
    CHECK_THROWS(FormatError, vbitmap::inspect(nullptr, 0));
    for (const Bytes &good : samples()) {
        CHECK(!rejects(good));
        // truncated: every shorter length
        for (size_t n = 0; n < good.size(); n += (good.size() > 200 ? 37 : 1))
            CHECK(rejects(Bytes(good.begin(), good.begin() + static_cast<long>(n))));
        // extended, with and without a valid checksum
        Bytes ext = good;
        ext.push_back(0);
        CHECK(rejects(ext));
        reseal(ext);
        CHECK(rejects(ext));
        // every single-bit flip (sampled for the large raw payload)
        const size_t step = good.size() > 200 ? 13 : 1;
        for (size_t i = 0; i < good.size(); i += step)
            for (int bit = 0; bit < 8; ++bit) {
                Bytes f = good;
                f[i] ^= static_cast<uint8_t>(1u << bit);
                CHECK(rejects(f));
            }
        // header fields with a valid checksum
        auto field = [&](size_t at, uint8_t value) {
            Bytes f = good;
            f[at] = value;
            reseal(f);
            return rejects(f);
        };
        CHECK(field(0, 'X'));           // magic
        CHECK(field(4, 2));             // version
        CHECK(field(5, 3));             // unknown codec
        CHECK(field(7, 1));             // reserved
        CHECK(field(6, 7));             // chunk bits below the range
        CHECK(field(6, 19));            // chunk bits above the range
        uint32_t card;
        std::memcpy(&card, good.data() + 8, 4);
        for (uint32_t wrong : {card + 1, card - 1, 0xFFFFFFFFu}) {
            Bytes f = good;
            std::memcpy(f.data() + 8, &wrong, 4);
            reseal(f);
            CHECK(rejects(f));
        }
        // codec relabelled (Roaring as raw, raw as Roaring, either as empty)
        for (uint8_t c = 0; c <= 2; ++c)
            if (c != good[5]) CHECK(field(5, c));
    }

    // Roaring value outside the chunk: an 18-bit set relabelled as 16-bit.
    {
        Bytes p = encode(test::to_bitmap(RefSet{5, 70000}, 18));
        CHECK(p[5] == static_cast<uint8_t>(Codec::Roaring));
        p[6] = 16;
        reseal(p);
        CHECK(rejects(p));
    }
    // Roaring body replaced by random bytes of plausible length, with a valid checksum.
    std::uniform_int_distribution<int> byte(0, 255);
    for (int round = 0; round < 2000; ++round) {
        Bytes p = encode(test::to_bitmap(RefSet{1, 2, 3, 1000, 2000}, 16));
        const size_t body = 16 + static_cast<size_t>(round % 64);
        p.resize(body + 16);
        for (size_t i = 16; i < p.size(); ++i) p[i] = static_cast<uint8_t>(byte(test::rng()));
        reseal(p);
        CHECK(rejects(p));
    }
    // Raw body all zero with cardinality 0 is not the canonical empty set.
    {
        Bytes p = encode(test::to_bitmap(test::random_ref(16, 0.5), 16));
        CHECK(p[5] == static_cast<uint8_t>(Codec::Raw));
        std::fill(p.begin() + 8, p.end(), 0);
        reseal(p);
        CHECK(rejects(p));
    }
}

static void describe_text()
{
    const Bytes p = encode(test::to_bitmap(RefSet{1, 2, 3}, 16));
    const std::string d = vbitmap::describe(p.data(), p.size());
    CHECK(d.find("codec=roaring") != std::string::npos);
    CHECK(d.find("chunk_bits=16") != std::string::npos);
    CHECK(d.find("cardinality=3") != std::string::npos);
    CHECK(d.find("bytes=" + std::to_string(p.size())) != std::string::npos);
    const Bytes e = encode(Bitmap(16));
    CHECK(vbitmap::describe(e.data(), e.size()) == "codec=empty chunk_bits=16 cardinality=0 bytes=16");
}

int main()
{
    round_trips();
    decode_or_many();
    malformed();
    describe_text();
    return test::finish("test_payload");
}
