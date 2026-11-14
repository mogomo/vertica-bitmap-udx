// Writes seed payloads for the fuzzer into the directory given as the only argument.
#include "vbitmap.h"

#include <cstdio>
#include <string>
#include <vector>

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: make_corpus DIR\n");
        return 2;
    }
    vbitmap::PayloadCodec codec;
    int n = 0;
    auto put = [&](const vbitmap::Bitmap &b) {
        std::vector<uint8_t> p;
        codec.encode(b, p);
        const std::string path = std::string(argv[1]) + "/seed_" + std::to_string(n++);
        FILE *f = std::fopen(path.c_str(), "wb");
        if (!f) return;
        std::fwrite(p.data(), 1, p.size(), f);
        std::fclose(f);
    };
    for (int cb : {8, 10, 16, 18}) {
        vbitmap::Bitmap b(cb);
        put(b);                                   // empty
        b.add(0);
        b.add(b.universe() - 1);
        put(b);                                   // array
        for (uint32_t i = 100; i < 300 && i < b.universe(); ++i) b.add(i);
        put(b);                                   // run
        for (uint32_t i = 0; i < b.universe(); i += 3) b.add(i);
        put(b);                                   // dense: raw or bitset containers
        b.fill();
        put(b);                                   // full
    }
    return 0;
}
