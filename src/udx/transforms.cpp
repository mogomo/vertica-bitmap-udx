// Transform functions.
//
//   bm_build(key_1, ..., key_n, local_id USING PARAMETERS chunk_bits=16)
//       OVER (PARTITION BY key_1, ..., key_n)
//     One output row per partition: the n keys and the payload of all local IDs. Duplicates are
//     idempotent; a NULL or out-of-range local ID is an error; keys must be constant inside a
//     partition (an error otherwise: the PARTITION BY clause misses a key).
//     The specification form is bm_build(tenant_id, snapshot_id, domain, predicate, chunk_id, local_id).
//
//   bm_union(key_1, ..., key_n, payload) OVER (PARTITION BY key_1, ..., key_n)
//     One output row per partition: the keys and the union of all payloads (NULL payloads skipped).
//     The specification form is bm_union(tenant_id, domain, chunk_id, payload).
//
//   bm_to_ids(chunk_id, payload) OVER (PARTITION ROW)
//     Exploder: one row per member, entity_id = (chunk_id << chunk_bits) | local_id, ascending.
//
// Key columns may be INT, BOOLEAN, FLOAT, DATE, TIME, TIMESTAMP, TIMESTAMPTZ, CHAR, VARCHAR,
// BINARY or VARBINARY.
#include "udx_common.h"

#include <cstring>

using namespace Vertica;
using namespace vbitmap_udx;

static bool supported_key_type(const VerticaType &t)
{
    return t.isInt() || t.isBool() || t.isFloat() || t.isDate() || t.isTime() || t.isTimestamp() ||
           t.isTimestampTz() || t.isChar() || t.isVarchar() || t.isBinary() || t.isVarbinary();
}

static std::string type_name(const VerticaType &t) { return t.getPrettyPrintStr(); }

// Remembers the key values of the first row of a partition and compares later rows with them,
// without allocating per row.
class PartitionKeys {
    struct Key {
        size_t col;
        bool is_string;
        bool null;
        std::string bytes;   // string value
        uint64_t fixed;      // fixed-width value (8 bytes or less)
        size_t fixed_size;
    };
    std::vector<Key> keys_;

public:
    void setup(const SizedColumnTypes &types, const std::vector<size_t> &cols)
    {
        keys_.clear();
        for (size_t c : cols) {
            const VerticaType &t = types.getColumnType(c);
            Key k{};
            k.col = c;
            k.is_string = t.isStringType();
            k.fixed_size = k.is_string ? 0 : static_cast<size_t>(t.getMaxSize());
            if (!k.is_string && k.fixed_size > sizeof(uint64_t))
                throw vbitmap::UsageError("unsupported key type " + type_name(t));
            keys_.push_back(k);
        }
    }

    void remember(const BlockReader &r)
    {
        for (Key &k : keys_) {
            if (k.is_string) {
                const VString &s = r.getStringRef(k.col);
                k.null = s.isNull();
                if (!k.null) k.bytes.assign(s.data(), static_cast<size_t>(s.length()));
            } else {
                k.fixed = 0;
                std::memcpy(&k.fixed, r.getColPtr<char>(k.col), k.fixed_size);
            }
        }
    }

    bool same(const BlockReader &r) const
    {
        for (const Key &k : keys_) {
            if (k.is_string) {
                const VString &s = r.getStringRef(k.col);
                if (s.isNull() != k.null) return false;
                if (!k.null && (static_cast<size_t>(s.length()) != k.bytes.size() ||
                                std::memcmp(s.data(), k.bytes.data(), k.bytes.size()) != 0))
                    return false;
            } else {
                uint64_t v = 0;
                std::memcpy(&v, r.getColPtr<char>(k.col), k.fixed_size);
                if (v != k.fixed) return false;
            }
        }
        return true;
    }
};

// Shared factory logic of bm_build and bm_union: keys..., last argument of a given kind.
static void keyed_return_type(const char *fn, const SizedColumnTypes &in, SizedColumnTypes &out, bool last_is_payload,
                       int32 payload_width)
{
    std::vector<size_t> args;
    in.getArgumentColumns(args);
    if (args.empty())
        vt_report_error(5, "%s: expects key columns (none is allowed) followed by %s", fn, last_is_payload ? "the payload" : "the local ID");
    const VerticaType &last = in.getColumnType(args.back());
    if (last_is_payload ? !(last.isVarbinary() || last.isBinary()) : !last.isInt())
        vt_report_error(5, "%s: the last argument must be %s, not %s", fn, last_is_payload ? "VARBINARY" : "INT",
                        type_name(last).c_str());
    for (size_t i = 0; i + 1 < args.size(); ++i) {
        const VerticaType &t = in.getColumnType(args[i]);
        if (!supported_key_type(t))
            vt_report_error(5, "%s: key column %zu has unsupported type %s", fn, i + 1, type_name(t).c_str());
        const std::string name = in.getColumnName(args[i]);
        out.addArg(t, name.empty() ? "key_" + std::to_string(i + 1) : name);
    }
    out.addVarbinary(payload_width, "payload");
}

// ---- bm_build ---------------------------------------------------------------------------------

class BmBuild : public TransformFunction {
    std::vector<size_t> args_;
    PartitionKeys keys_;
    vbitmap::Bitmap bm_;
    vbitmap::PayloadCodec codec_;
    std::vector<uint8_t> out_;
    int32 width_ = NARROW_WIDTH;

public:
    void setup(ServerInterface &srv, const SizedColumnTypes &argTypes) override
    {
        VBITMAP_TRY
        argTypes.getArgumentColumns(args_);
        const int cb = chunk_bits_param(srv);
        bm_.reset(cb);
        width_ = width_for_chunk_bits(cb);
        keys_.setup(argTypes, std::vector<size_t>(args_.begin(), args_.end() - 1));
        VBITMAP_CATCH("bm_build")
    }

    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        const size_t nkeys = args_.size() - 1;
        const size_t id_col = args_.back();
        const vint universe = static_cast<vint>(bm_.universe());
        bm_.clear();
        keys_.remember(in);
        for (size_t k = 0; k < nkeys; ++k) out.copyFromInput(k, in, args_[k]);
        uint64_t rows = 0;
        do {
            if (!keys_.same(in))
                throw vbitmap::UsageError("key values differ inside one partition: PARTITION BY must list every key column");
            const vint id = in.getIntRef(id_col);
            if (id == vint_null) throw vbitmap::UsageError("NULL local ID");
            if (id < 0 || id >= universe)
                throw vbitmap::UsageError("local ID " + std::to_string(id) + " is outside a chunk of " +
                                          std::to_string(bm_.chunk_bits()) + " bits");
            bm_.add(static_cast<uint32_t>(id));
            VBITMAP_CANCEL_POINT(rows)
        } while (in.next());
        codec_.encode(bm_, out_);
        put_payload(out.getStringRef(nkeys), out_, width_);
        out.next();
        VBITMAP_CATCH("bm_build")
    }
};

class BmBuildFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addAny();
        returnType.addAny();
    }
    void getReturnType(ServerInterface &srv, const SizedColumnTypes &in, SizedColumnTypes &out) override
    {
        int cb = vbitmap::DEFAULT_CHUNK_BITS;
        VBITMAP_TRY
        cb = chunk_bits_param(srv);
        VBITMAP_CATCH("bm_build")
        keyed_return_type("bm_build", in, out, false, width_for_chunk_bits(cb));
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override { params.addInt("chunk_bits"); }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmBuild>(srv.allocator);
    }
};
RegisterFactory(BmBuildFactory);

// ---- bm_union ---------------------------------------------------------------------------------

class BmUnion : public TransformFunction {
    std::vector<size_t> args_;
    PartitionKeys keys_;
    vbitmap::Bitmap acc_;
    vbitmap::PayloadCodec codec_;
    std::vector<uint8_t> out_;
    std::string single_;
    int32 width_ = NARROW_WIDTH;

public:
    void setup(ServerInterface &, const SizedColumnTypes &argTypes) override
    {
        VBITMAP_TRY
        argTypes.getArgumentColumns(args_);
        const VerticaType &p = argTypes.getColumnType(args_.back());
        width_ = p.getStringLength() > NARROW_WIDTH ? WIDE_WIDTH : NARROW_WIDTH;
        keys_.setup(argTypes, std::vector<size_t>(args_.begin(), args_.end() - 1));
        VBITMAP_CATCH("bm_union")
    }

    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        const size_t nkeys = args_.size() - 1;
        const size_t payload_col = args_.back();
        acc_.reset(vbitmap::DEFAULT_CHUNK_BITS);   // empty: takes the width of the first payload
        keys_.remember(in);
        for (size_t k = 0; k < nkeys; ++k) out.copyFromInput(k, in, args_[k]);
        // A partition of one row is returned as it is after the cheap validation (header and
        // checksum), without decoding: the common case when a live aggregate projection is read
        // after its containers were merged.
        const VString &first = in.getStringRef(payload_col);
        single_.clear();
        const bool first_null = first.isNull();
        if (!first_null) single_.assign(first.data(), static_cast<size_t>(first.length()));
        if (!in.next()) {
            if (first_null) {
                codec_.encode(acc_, out_);
                put_payload(out.getStringRef(nkeys), out_, width_);
            } else {
                vbitmap::inspect(single_.data(), single_.size());
                if (single_.size() > static_cast<size_t>(width_))
                    throw vbitmap::UsageError("payload exceeds the output width");
                out.getStringRef(nkeys).copy(single_.data(), static_cast<vsize>(single_.size()));
            }
            out.next();
            return;
        }
        if (!first_null) codec_.decode_or(single_.data(), single_.size(), acc_);
        uint64_t rows = 0;
        do {
            if (!keys_.same(in))
                throw vbitmap::UsageError("key values differ inside one partition: PARTITION BY must list every key column");
            const VString &p = in.getStringRef(payload_col);
            if (!p.isNull()) codec_.decode_or(p.data(), static_cast<size_t>(p.length()), acc_);
            VBITMAP_CANCEL_POINT(rows)
        } while (in.next());
        codec_.encode(acc_, out_);
        put_payload(out.getStringRef(nkeys), out_, width_);
        out.next();
        VBITMAP_CATCH("bm_union")
    }
};

class BmUnionFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addAny();
        returnType.addAny();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &in, SizedColumnTypes &out) override
    {
        std::vector<size_t> args;
        in.getArgumentColumns(args);
        int32 w = NARROW_WIDTH;
        if (!args.empty() && in.getColumnType(args.back()).getStringLength() > NARROW_WIDTH) w = WIDE_WIDTH;
        keyed_return_type("bm_union", in, out, true, w);
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmUnion>(srv.allocator);
    }
};
RegisterFactory(BmUnionFactory);

// ---- bm_pair_count ----------------------------------------------------------------------------
//
//   bm_pair_count(name, a, b) OVER (PARTITION BEST)
//     One output row (name, cnt) per input row whose two sets share members: cnt = |a AND b|.
//     Rows are independent, so Vertica may hand them to as many threads as the query has
//     (PARTITION BEST); a first argument repeated row after row is decoded once per run.

class BmPairCount : public TransformFunction {
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap a_, b_;
    std::string last_a_;
    bool have_a_ = false;

public:
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        uint64_t rows = 0;
        do {
            const VString &name = in.getStringRef(0);
            const VString &x = in.getStringRef(1);
            const VString &y = in.getStringRef(2);
            if (!x.isNull() && !y.isNull()) {
                const size_t n = static_cast<size_t>(x.length());
                if (!have_a_ || n != last_a_.size() || std::memcmp(x.data(), last_a_.data(), n) != 0) {
                    decode(codec_, x, a_);
                    last_a_.assign(x.data(), n);
                    have_a_ = true;
                }
                decode(codec_, y, b_);
                vbitmap::align_widths(a_, b_);
                const uint64_t c = vbitmap::and_cardinality(a_, b_);
                if (c > 0) {
                    if (name.isNull()) out.getStringRef(0).setNull();
                    else out.getStringRef(0).copy(name.data(), name.length());
                    out.setInt(1, static_cast<vint>(c));
                    out.next();
                }
            }
            VBITMAP_CANCEL_POINT(rows)
        } while (in.next());
        VBITMAP_CATCH("bm_pair_count")
    }
};

class BmPairCountFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarchar();
        argTypes.addVarbinary();
        argTypes.addVarbinary();
        returnType.addVarchar();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarchar(80, "name");
        out.addInt("cnt");
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmPairCount>(srv.allocator);
    }
};
RegisterFactory(BmPairCountFactory);

// ---- bm_to_ids --------------------------------------------------------------------------------

class BmToIds : public TransformFunction {
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap b_;
    std::vector<uint32_t> ids_;

public:
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        uint64_t rows = 0;
        do {
            const vint chunk = in.getIntRef(0);
            const VString &p = in.getStringRef(1);
            if (chunk == vint_null || p.isNull()) continue;
            decode(codec_, p, b_);
            const int cb = b_.chunk_bits();
            if (chunk < 0 || chunk > (vint{0x7FFFFFFFFFFFFFFF} >> cb))
                throw vbitmap::UsageError("chunk_id " + std::to_string(chunk) + " out of range");
            ids_.clear();
            b_.to_local_ids(ids_);
            for (uint32_t local : ids_) {
                out.setInt(0, static_cast<vint>(vbitmap::entity_of(chunk, local, cb)));
                out.next();
                VBITMAP_CANCEL_POINT(rows)
            }
        } while (in.next());
        VBITMAP_CATCH("bm_to_ids")
    }
};

class BmToIdsFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addInt();
        argTypes.addVarbinary();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addInt("entity_id");
    }
    void getFunctionProperties(ServerInterface &, const SizedColumnTypes &, Properties &properties) override
    {
        properties.isExploder = true;
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmToIds>(srv.allocator);
    }
};
RegisterFactory(BmToIdsFactory);
