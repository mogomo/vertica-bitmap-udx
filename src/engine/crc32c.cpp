// CRC-32C (Castagnoli, reflected polynomial 0x82F63B78). Software slicing-by-8, and the SSE4.2
// crc32 instruction on x86-64 when the CPU has it (checked once at run time, so the library is
// still built for the x86-64 baseline).
#include "vbitmap.h"

#include <cstring>

#if defined(__x86_64__)
#include <nmmintrin.h>
#endif

namespace vbitmap {
namespace {

struct Tables {
    uint32_t t[8][256];
    Tables()
    {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (0x82F63B78u & (0u - (c & 1u)));
            t[0][i] = c;
        }
        for (uint32_t i = 0; i < 256; ++i)
            for (int s = 1; s < 8; ++s) t[s][i] = (t[s - 1][i] >> 8) ^ t[0][t[s - 1][i] & 0xFF];
    }
};

const Tables &tables()
{
    static const Tables tb;
    return tb;
}

uint32_t crc_soft(const unsigned char *p, size_t n, uint32_t crc)
{
    const Tables &tb = tables();
    while (n >= 8) {
        uint64_t v;
        std::memcpy(&v, p, 8);
        v ^= crc;
        crc = tb.t[7][v & 0xFF] ^ tb.t[6][(v >> 8) & 0xFF] ^ tb.t[5][(v >> 16) & 0xFF] ^
              tb.t[4][(v >> 24) & 0xFF] ^ tb.t[3][(v >> 32) & 0xFF] ^ tb.t[2][(v >> 40) & 0xFF] ^
              tb.t[1][(v >> 48) & 0xFF] ^ tb.t[0][v >> 56];
        p += 8;
        n -= 8;
    }
    while (n--) crc = (crc >> 8) ^ tb.t[0][(crc ^ *p++) & 0xFF];
    return crc;
}

#if defined(__x86_64__)
__attribute__((target("sse4.2"))) uint32_t crc_hw(const unsigned char *p, size_t n, uint32_t crc)
{
    uint64_t c = crc;
    while (n >= 8) {
        uint64_t v;
        std::memcpy(&v, p, 8);
        c = _mm_crc32_u64(c, v);
        p += 8;
        n -= 8;
    }
    uint32_t c32 = static_cast<uint32_t>(c);
    while (n--) c32 = _mm_crc32_u8(c32, *p++);
    return c32;
}

bool have_sse42()
{
    static const bool yes = __builtin_cpu_supports("sse4.2");
    return yes;
}
#endif

}  // namespace

uint32_t crc32c(const void *data, size_t size, uint32_t crc)
{
    const auto *p = static_cast<const unsigned char *>(data);
    crc = ~crc;
#if defined(__x86_64__)
    if (have_sse42()) return ~crc_hw(p, size, crc);
#endif
    return ~crc_soft(p, size, crc);
}

// Exposed for the tests: the software path regardless of the CPU.
uint32_t crc32c_software(const void *data, size_t size, uint32_t crc)
{
    return ~crc_soft(static_cast<const unsigned char *>(data), size, ~crc);
}

}  // namespace vbitmap
