// Aggregate functions: the sets of a GROUP BY, built on every thread of the query.
//
//   bm_build_agg(local_id)   VARBINARY   payload of the local IDs of the group
//   bm_union_agg(payload)    VARBINARY   union of the payloads of the group (NULL payloads skipped)
//
//   SELECT predicate, entity_id >> 16 AS chunk_id, vbitmap.bm_build_agg(entity_id & 65535)
//   FROM ... GROUP BY 1, 2;
//
// The same payloads as bm_build / bm_union OVER (PARTITION BY ...), byte for byte, without the
// sort a PARTITION BY clause needs: Vertica groups by hashing (or in one pass when the input is
// sorted on the keys) and spreads the work over the threads of the query. The intermediate state
// of a group is its raw bitset (8,192 bytes), so give the statement a memory budget that holds
// one bitset per group, or the group-by spills to disk.
//
// Vertica runs user-defined aggregates inside the server process only: these two functions are
// installed when the library is deployed unfenced. Chunks are 16 bits wide here.
#include "udx_common.h"

#include <cstring>

using namespace Vertica;
using namespace vbitmap_udx;

namespace {

constexpr int AGG_CHUNK_BITS = 16;
constexpr vsize STATE_BYTES = 8192;
constexpr size_t STATE_WORDS = STATE_BYTES / sizeof(uint64_t);

// The intermediate value is created by initAggregate as STATE_BYTES zero bytes; unaligned access
// is done through memcpy.
inline void or_bit(char *state, vint local)
{
    uint64_t w;
    char *p = state + (static_cast<size_t>(local) >> 6) * sizeof(uint64_t);
    std::memcpy(&w, p, sizeof w);
    w |= uint64_t{1} << (local & 63);
    std::memcpy(p, &w, sizeof w);
}

inline void or_words(char *state, const uint64_t *src)
{
    for (size_t i = 0; i < STATE_WORDS; ++i) {
        uint64_t w;
        std::memcpy(&w, state + i * sizeof(uint64_t), sizeof w);
        w |= src[i];
        std::memcpy(state + i * sizeof(uint64_t), &w, sizeof w);
    }
}

class StateAggregate : public AggregateFunction {
protected:
    vbitmap::Bitmap bm_;
    vbitmap::PayloadCodec codec_;
    std::vector<uint8_t> out_;

    static char *state(IntermediateAggs &aggs)
    {
        VString &s = aggs.getStringRef(0);
        if (s.isNull() || s.length() != STATE_BYTES) vt_report_error(6, "aggregate state of an unexpected size");
        return s.data();
    }

public:
    void initAggregate(ServerInterface &, IntermediateAggs &aggs) override { aggs.getStringRef(0).alloc(STATE_BYTES); }

    void combine(ServerInterface &, IntermediateAggs &aggs, MultipleIntermediateAggs &other) override
    {
        char *dst = state(aggs);
        do {
            const VString &o = other.getStringRef(0);
            if (o.isNull() || o.length() != STATE_BYTES) vt_report_error(6, "aggregate state of an unexpected size");
            uint64_t tmp[STATE_WORDS];
            std::memcpy(tmp, o.data(), STATE_BYTES);
            or_words(dst, tmp);
        } while (other.next());
    }

    void terminate(ServerInterface &, BlockWriter &res, IntermediateAggs &aggs) override
    {
        VBITMAP_TRY
        bm_.reset(AGG_CHUNK_BITS);
        std::memcpy(bm_.words(), state(aggs), STATE_BYTES);
        codec_.encode(bm_, out_);
        put_payload(res.getStringRef(), out_, NARROW_WIDTH);
        VBITMAP_CATCH("bm_build_agg")
    }
};

class BmBuildAgg : public StateAggregate {
public:
    void aggregate(ServerInterface &, BlockReader &arg, IntermediateAggs &aggs)
    {
        char *dst = state(aggs);
        do {
            const vint id = arg.getIntRef(0);
            if (id == vint_null) vt_report_error(2, "bm_build_agg: NULL local ID");
            if (id < 0 || id >= (vint{1} << AGG_CHUNK_BITS))
                vt_report_error(2, "bm_build_agg: local ID %lld is outside a chunk of %d bits", static_cast<long long>(id), AGG_CHUNK_BITS);
            or_bit(dst, id);
        } while (arg.next());
    }
    InlineAggregate()
};

class BmUnionAgg : public StateAggregate {
public:
    void aggregate(ServerInterface &, BlockReader &arg, IntermediateAggs &aggs)
    {
        VBITMAP_TRY
        char *dst = state(aggs);
        do {
            const VString &p = arg.getStringRef(0);
            if (p.isNull()) continue;
            codec_.decode(p.data(), static_cast<size_t>(p.length()), bm_);
            if (bm_.empty()) continue;
            if (bm_.chunk_bits() != AGG_CHUNK_BITS) throw vbitmap::UsageError("the aggregate takes payloads of 16-bit chunks only");
            or_words(dst, bm_.words());
        } while (arg.next());
        VBITMAP_CATCH("bm_union_agg")
    }
    InlineAggregate()
};

template <class F, bool PAYLOAD_IN>
class StateAggregateFactory : public AggregateFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        if (PAYLOAD_IN) argTypes.addVarbinary();
        else argTypes.addInt();
        returnType.addVarbinary();
    }
    void getIntermediateTypes(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &intermediate) override
    {
        intermediate.addVarbinary(STATE_BYTES);
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarbinary(NARROW_WIDTH, "payload");
    }
    AggregateFunction *createAggregateFunction(ServerInterface &srv) override { return vt_createFuncObject<F>(srv.allocator); }
};

}  // namespace

class BmBuildAggFactory : public StateAggregateFactory<BmBuildAgg, false> {};
RegisterFactory(BmBuildAggFactory);

class BmUnionAggFactory : public StateAggregateFactory<BmUnionAgg, true> {};
RegisterFactory(BmUnionAggFactory);
