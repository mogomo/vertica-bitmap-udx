// Minimal test helpers: CHECK macros, a seeded random generator, a reference set.
#pragma once

#include "vbitmap.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <set>
#include <string>
#include <vector>

namespace test {

inline int failures = 0;
inline int checks = 0;

#define CHECK(cond)                                                                       \
    do {                                                                                  \
        ++test::checks;                                                                   \
        if (!(cond)) {                                                                    \
            ++test::failures;                                                             \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                                 \
    } while (0)

#define CHECK_THROWS(ExType, stmt)                                                                  \
    do {                                                                                            \
        ++test::checks;                                                                             \
        bool thrown_ = false;                                                                       \
        try {                                                                                       \
            stmt;                                                                                   \
        } catch (const ExType &) {                                                                  \
            thrown_ = true;                                                                         \
        } catch (const std::exception &e_) {                                                        \
            std::fprintf(stderr, "%s:%d: wrong exception: %s\n", __FILE__, __LINE__, e_.what());    \
        }                                                                                           \
        if (!thrown_) {                                                                             \
            ++test::failures;                                                                       \
            std::fprintf(stderr, "%s:%d: expected " #ExType " from: %s\n", __FILE__, __LINE__, #stmt); \
        }                                                                                           \
    } while (0)

inline int finish(const char *name)
{
    if (failures) {
        std::printf("%s: %d of %d checks FAILED\n", name, failures, checks);
        return 1;
    }
    std::printf("%s: %d checks passed\n", name, checks);
    return 0;
}

inline std::mt19937_64 &rng()
{
    static std::mt19937_64 g(20261111);
    return g;
}

// Reference implementation: an ordered set of local IDs.
using RefSet = std::set<uint32_t>;

inline RefSet random_ref(int chunk_bits, double density)
{
    RefSet s;
    const uint32_t u = uint32_t{1} << chunk_bits;
    std::bernoulli_distribution pick(density);
    for (uint32_t i = 0; i < u; ++i)
        if (pick(rng())) s.insert(i);
    return s;
}

// Runs of consecutive IDs: compresses well as Roaring run containers.
inline RefSet random_runs(int chunk_bits, int runs, uint32_t max_len)
{
    RefSet s;
    const uint32_t u = uint32_t{1} << chunk_bits;
    std::uniform_int_distribution<uint32_t> start(0, u - 1), len(1, max_len);
    for (int r = 0; r < runs; ++r) {
        uint32_t a = start(rng()), n = len(rng());
        for (uint32_t i = a; i < u && i < a + n; ++i) s.insert(i);
    }
    return s;
}

inline vbitmap::Bitmap to_bitmap(const RefSet &s, int chunk_bits)
{
    vbitmap::Bitmap b(chunk_bits);
    for (uint32_t v : s) b.add(v);
    return b;
}

inline RefSet to_ref(const vbitmap::Bitmap &b)
{
    std::vector<uint32_t> ids;
    b.to_local_ids(ids);
    return RefSet(ids.begin(), ids.end());
}

// Densities that cover the empty, sparse (array), dense (bitset) and full cases.
inline const std::vector<double> &densities()
{
    static const std::vector<double> d = {0.0, 0.00005, 0.001, 0.01, 0.05, 0.06, 0.07, 0.2, 0.5, 0.9, 0.999, 1.0};
    return d;
}

}  // namespace test
