/*
 * Ground probes for the Vertica SDK on the target server (milestone M0).
 * Not part of the vbitmap library. Built as build/libvbitmap_probe.so by "make probe".
 *
 *   probe_popcount(VARBINARY)               scalar: number of one-bits; settles flags, ABI, fenced scalar
 *   probe_partition(chunk_id, payload
 *       USING PARAMETERS expr = '...')      transform: one output row per partition (rows read,
 *                                           bytes read, length of the expr parameter)
 *   probe_count(INT)                        aggregate: plain count; checks where aggregates may run
 */
#include "Vertica.h"

#include <cstdint>
#include <string>

using namespace Vertica;

static vint popcount_bytes(const char *p, size_t n)
{
    vint c = 0;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t w;
        __builtin_memcpy(&w, p + i, 8);
        c += __builtin_popcountll(w);
    }
    for (; i < n; ++i) c += __builtin_popcount(static_cast<unsigned char>(p[i]));
    return c;
}

class ProbePopcount : public ScalarFunction
{
public:
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        do {
            const VString &b = in.getStringRef(0);
            if (b.isNull()) out.setNull();
            else out.setInt(popcount_bytes(b.data(), b.length()));
            out.next();
        } while (in.next());
    }
};

class ProbePopcountFactory : public ScalarFunctionFactory
{
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarbinary();
        returnType.addInt();
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<ProbePopcount>(srv.allocator);
    }
public:
    ProbePopcountFactory() { vol = IMMUTABLE; strict = RETURN_NULL_ON_NULL_INPUT; }
};
RegisterFactory(ProbePopcountFactory);

class ProbePartition : public TransformFunction
{
    std::string expr;

    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        ParamReader p = srv.getParamReader();
        expr = p.containsParameter("expr") ? p.getStringRef("expr").str() : "";
    }

    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        vint rows = 0, bytes = 0, chunk = 0;
        do {
            if (rows == 0) chunk = in.getIntRef(0);
            const VString &b = in.getStringRef(1);
            if (!b.isNull()) bytes += b.length();
            ++rows;
        } while (in.next());
        out.setInt(0, chunk);
        out.setInt(1, rows);
        out.setInt(2, bytes);
        out.setInt(3, static_cast<vint>(expr.size()));
        out.next();
    }
};

class ProbePartitionFactory : public TransformFunctionFactory
{
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addInt();
        argTypes.addVarbinary();
        returnType.addInt();
        returnType.addInt();
        returnType.addInt();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addInt("chunk_id");
        out.addInt("rows_read");
        out.addInt("bytes_read");
        out.addInt("expr_len");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override
    {
        params.addVarchar(65000, "expr");
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<ProbePartition>(srv.allocator);
    }
};
RegisterFactory(ProbePartitionFactory);

class ProbeCount : public AggregateFunction
{
    void initAggregate(ServerInterface &, IntermediateAggs &aggs) override { aggs.getIntRef(0) = 0; }
    // Not virtual in the SDK: InlineAggregate() below generates the dispatch to it.
    void aggregate(ServerInterface &, BlockReader &in, IntermediateAggs &aggs)
    {
        vint &c = aggs.getIntRef(0);
        do { if (in.getIntRef(0) != vint_null) ++c; } while (in.next());
    }
    void combine(ServerInterface &, IntermediateAggs &aggs, MultipleIntermediateAggs &other) override
    {
        vint &c = aggs.getIntRef(0);
        do { c += other.getIntRef(0); } while (other.next());
    }
    void terminate(ServerInterface &, BlockWriter &out, IntermediateAggs &aggs) override
    {
        out.setInt(aggs.getIntRef(0));
    }
    InlineAggregate()
};

class ProbeCountFactory : public AggregateFunctionFactory
{
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addInt();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addInt();
    }
    void getIntermediateTypes(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &inter) override
    {
        inter.addInt();
    }
    AggregateFunction *createAggregateFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<ProbeCount>(srv.allocator);
    }
};
RegisterFactory(ProbeCountFactory);
