// Set operations against a reference implementation, algebraic laws, boundaries, errors.
#include "test_util.h"

#include <algorithm>
#include <iterator>

using test::RefSet;
using vbitmap::Bitmap;

static RefSet ref_and(const RefSet &a, const RefSet &b)
{
    RefSet r;
    std::set_intersection(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end()));
    return r;
}
static RefSet ref_or(const RefSet &a, const RefSet &b)
{
    RefSet r;
    std::set_union(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end()));
    return r;
}
static RefSet ref_xor(const RefSet &a, const RefSet &b)
{
    RefSet r;
    std::set_symmetric_difference(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end()));
    return r;
}
static RefSet ref_andnot(const RefSet &a, const RefSet &b)
{
    RefSet r;
    std::set_difference(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end()));
    return r;
}

template <class Op>
static Bitmap apply(Bitmap a, const Bitmap &b, Op op)
{
    (a.*op)(b);
    return a;
}

static void boundaries()
{
    for (int cb : {8, 16, 18}) {
        Bitmap b(cb);
        const uint32_t last = b.universe() - 1;
        CHECK(b.empty() && b.cardinality() == 0);
        b.add(0);
        b.add(last);
        b.add(last);   // duplicates are idempotent
        CHECK(b.cardinality() == 2);
        CHECK(b.contains(0) && b.contains(last) && !b.contains(1) && !b.contains(last + 1));
        CHECK_THROWS(vbitmap::UsageError, b.add(last + 1));
        std::vector<uint32_t> ids;
        b.to_local_ids(ids);
        CHECK(ids.size() == 2 && ids[0] == 0 && ids[1] == last);
        b.fill();
        CHECK(b.cardinality() == b.universe());
        b.clear();
        CHECK(b.empty());
    }
    CHECK_THROWS(vbitmap::UsageError, Bitmap(7));
    CHECK_THROWS(vbitmap::UsageError, Bitmap(19));
    Bitmap a(16), c(18);
    CHECK_THROWS(vbitmap::UsageError, a.and_with(c));
    CHECK_THROWS(vbitmap::UsageError, a.or_with(c));
    CHECK_THROWS(vbitmap::UsageError, a.xor_with(c));
    CHECK_THROWS(vbitmap::UsageError, a.andnot_with(c));
    CHECK_THROWS(vbitmap::UsageError, vbitmap::and_cardinality(a, c));
    // align_widths: the empty set adapts, two non-empty sets of different widths do not.
    Bitmap e16(16), x18(18);
    x18.add(70000);
    vbitmap::align_widths(e16, x18);
    CHECK(e16.chunk_bits() == 18 && e16.empty());
    Bitmap x16(16);
    x16.add(1);
    Bitmap e18(18);
    vbitmap::align_widths(x16, e18);
    CHECK(e18.chunk_bits() == 16);
    Bitmap y18(18);
    y18.add(2);
    CHECK_THROWS(vbitmap::UsageError, vbitmap::align_widths(x16, y18));
}

static void entity_ids()
{
    using vbitmap::chunk_of;
    using vbitmap::entity_of;
    using vbitmap::local_of;
    const int64_t ids[] = {0, 1, 65535, 65536, 4294967295LL, 4294967296LL, 9223372036854775807LL};
    for (int cb : {16, 18})
        for (int64_t id : ids) CHECK(entity_of(chunk_of(id, cb), local_of(id, cb), cb) == id);
    CHECK(chunk_of(65536, 16) == 1 && local_of(65536, 16) == 0);
    CHECK(chunk_of(4294967296LL, 16) == 65536 && local_of(4294967296LL, 16) == 0);   // 2^32 does not collide with 0
    CHECK(chunk_of(9223372036854775807LL, 16) == 140737488355327LL && local_of(9223372036854775807LL, 16) == 65535);
}

static void against_reference()
{
    for (int cb : {8, 16, 18}) {
        const auto &d = test::densities();
        for (size_t i = 0; i < d.size(); ++i) {
            for (size_t j = 0; j < d.size(); j += 3) {
                const RefSet ra = test::random_ref(cb, d[i]);
                const RefSet rb = (j % 2) ? test::random_runs(cb, 20, 3000) : test::random_ref(cb, d[j]);
                const Bitmap a = test::to_bitmap(ra, cb), b = test::to_bitmap(rb, cb);
                CHECK(test::to_ref(a) == ra);
                CHECK(a.cardinality() == ra.size());
                CHECK(test::to_ref(apply(a, b, &Bitmap::and_with)) == ref_and(ra, rb));
                CHECK(test::to_ref(apply(a, b, &Bitmap::or_with)) == ref_or(ra, rb));
                CHECK(test::to_ref(apply(a, b, &Bitmap::xor_with)) == ref_xor(ra, rb));
                CHECK(test::to_ref(apply(a, b, &Bitmap::andnot_with)) == ref_andnot(ra, rb));
                CHECK(vbitmap::and_cardinality(a, b) == ref_and(ra, rb).size());
                for (uint32_t probe : {0u, 1u, a.universe() / 2, a.universe() - 1})
                    CHECK(a.contains(probe) == (ra.count(probe) == 1));
            }
        }
    }
}

static void laws()
{
    const int cb = 16;
    for (int round = 0; round < 40; ++round) {
        const double da = test::densities()[round % test::densities().size()];
        const Bitmap a = test::to_bitmap(test::random_ref(cb, da), cb);
        const Bitmap b = test::to_bitmap(test::random_runs(cb, 10, 5000), cb);
        const Bitmap c = test::to_bitmap(test::random_ref(cb, 0.3), cb);
        Bitmap u(cb);
        u.fill();
        Bitmap e(cb);
        // commutative
        CHECK(apply(a, b, &Bitmap::and_with) == apply(b, a, &Bitmap::and_with));
        CHECK(apply(a, b, &Bitmap::or_with) == apply(b, a, &Bitmap::or_with));
        CHECK(apply(a, b, &Bitmap::xor_with) == apply(b, a, &Bitmap::xor_with));
        // associative
        CHECK(apply(apply(a, b, &Bitmap::and_with), c, &Bitmap::and_with) == apply(a, apply(b, c, &Bitmap::and_with), &Bitmap::and_with));
        CHECK(apply(apply(a, b, &Bitmap::or_with), c, &Bitmap::or_with) == apply(a, apply(b, c, &Bitmap::or_with), &Bitmap::or_with));
        CHECK(apply(apply(a, b, &Bitmap::xor_with), c, &Bitmap::xor_with) == apply(a, apply(b, c, &Bitmap::xor_with), &Bitmap::xor_with));
        // idempotence, identities
        CHECK(apply(a, a, &Bitmap::and_with) == a && apply(a, a, &Bitmap::or_with) == a);
        CHECK(apply(a, a, &Bitmap::xor_with) == e && apply(a, a, &Bitmap::andnot_with) == e);
        CHECK(apply(a, u, &Bitmap::and_with) == a && apply(a, e, &Bitmap::or_with) == a);
        // distributive
        CHECK(apply(a, apply(b, c, &Bitmap::or_with), &Bitmap::and_with) ==
              apply(apply(a, b, &Bitmap::and_with), apply(a, c, &Bitmap::and_with), &Bitmap::or_with));
        // De Morgan against an explicit universe: U - (A | B) = (U - A) & (U - B)
        CHECK(apply(u, apply(a, b, &Bitmap::or_with), &Bitmap::andnot_with) ==
              apply(apply(u, a, &Bitmap::andnot_with), apply(u, b, &Bitmap::andnot_with), &Bitmap::and_with));
        CHECK(apply(u, apply(a, b, &Bitmap::and_with), &Bitmap::andnot_with) ==
              apply(apply(u, a, &Bitmap::andnot_with), apply(u, b, &Bitmap::andnot_with), &Bitmap::or_with));
        // A - B = A & (U - B); A ^ B = (A - B) | (B - A)
        CHECK(apply(a, b, &Bitmap::andnot_with) == apply(a, apply(u, b, &Bitmap::andnot_with), &Bitmap::and_with));
        CHECK(apply(a, b, &Bitmap::xor_with) ==
              apply(apply(a, b, &Bitmap::andnot_with), apply(b, a, &Bitmap::andnot_with), &Bitmap::or_with));
        // inclusion-exclusion
        CHECK(apply(a, b, &Bitmap::or_with).cardinality() + vbitmap::and_cardinality(a, b) == a.cardinality() + b.cardinality());
    }
}

int main()
{
    boundaries();
    entity_ids();
    against_reference();
    laws();
    return test::finish("test_bitmap");
}
