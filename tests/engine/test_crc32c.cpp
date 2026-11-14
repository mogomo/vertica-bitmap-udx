// CRC-32C: known vectors; hardware and software paths agree; incremental use.
#include "test_util.h"

namespace vbitmap {
uint32_t crc32c_software(const void *data, size_t size, uint32_t crc = 0);
}

int main()
{
    using vbitmap::crc32c;
    using vbitmap::crc32c_software;

    const std::string nine = "123456789";
    CHECK(crc32c(nine.data(), nine.size()) == 0xE3069283u);   // standard check value
    CHECK(crc32c_software(nine.data(), nine.size()) == 0xE3069283u);
    CHECK(crc32c("", 0) == 0u);
    std::vector<unsigned char> zeros(32, 0), ones(32, 0xFF);
    CHECK(crc32c(zeros.data(), zeros.size()) == 0x8A9136AAu);   // RFC 3720 B.4
    CHECK(crc32c(ones.data(), ones.size()) == 0x62A8AB43u);

    std::uniform_int_distribution<int> byte(0, 255);
    for (size_t n = 0; n < 300; ++n) {
        std::vector<unsigned char> buf(n);
        for (auto &c : buf) c = static_cast<unsigned char>(byte(test::rng()));
        const uint32_t whole = crc32c(buf.data(), n);
        CHECK(whole == crc32c_software(buf.data(), n));
        const size_t cut = n / 3;
        CHECK(whole == crc32c(buf.data() + cut, n - cut, crc32c(buf.data(), cut)));
    }
    return test::finish("test_crc32c");
}
