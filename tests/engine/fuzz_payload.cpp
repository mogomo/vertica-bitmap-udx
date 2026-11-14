// libFuzzer target for the payload reader (make fuzz). Each input is decoded as given, then once
// more with its checksum rewritten, so that the fuzzer also reaches the checks behind the
// checksum. A payload that decodes must re-encode to a payload of the same set. Any crash,
// sanitizer report or abort is a finding; FormatError is the expected outcome for bad input.
#include "vbitmap.h"

#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    static vbitmap::PayloadCodec codec;
    static vbitmap::Bitmap b, again;
    std::vector<uint8_t> in(data, data + size);
    for (int pass = 0; pass < 2; ++pass) {
        if (pass == 1) {
            if (in.size() < vbitmap::HEADER_SIZE) break;
            uint32_t crc = vbitmap::crc32c(in.data(), 12);
            crc = vbitmap::crc32c(in.data() + 16, in.size() - 16, crc);
            std::memcpy(in.data() + 12, &crc, 4);
        }
        vbitmap::PayloadInfo info;
        try {
            info = vbitmap::inspect(in.data(), in.size());
            codec.decode(in.data(), in.size(), b);
        } catch (const vbitmap::FormatError &) {
            continue;
        }
        if (b.cardinality() != info.cardinality || b.chunk_bits() != info.chunk_bits) std::abort();
        std::vector<uint8_t> out;
        codec.encode(b, out);
        codec.decode(out.data(), out.size(), again);
        if (!(again == b)) std::abort();
        if (out.size() > in.size()) std::abort();   // the canonical form is never larger
    }
    return 0;
}
