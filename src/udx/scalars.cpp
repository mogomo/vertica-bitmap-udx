// Scalar functions over payloads.
//
//   bm_and(a, b) / bm_or / bm_xor / bm_andnot   VARBINARY  exact set operation
//   bm_cardinality(b)                            INT        from the checked header
//   bm_and_cardinality(a, b)                     INT        |a AND b| without building the result
//   bm_contains(b, local_id)                     BOOLEAN    error if local_id is outside the chunk
//   bm_empty(USING PARAMETERS chunk_bits=16)     VARBINARY  canonical empty set (never NULL)
//   bm_info(b)                                   VARCHAR    codec, chunk bits, cardinality, bytes
//   bm_version()                                 VARCHAR    library, CRoaring and build flags
//
// SQL NULL in, SQL NULL out. A malformed payload raises an error.
#include "udx_common.h"

#include <cstring>

using namespace Vertica;
using namespace vbitmap_udx;

namespace {

enum class Op { And, Or, Xor, AndNot };

constexpr const char *op_name(Op op)
{
    return op == Op::And ? "bm_and" : op == Op::Or ? "bm_or" : op == Op::Xor ? "bm_xor" : "bm_andnot";
}

template <Op OP>
class SetOp : public ScalarFunction {
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap a_, b_;
    std::vector<uint8_t> out_;
    int32 width_ = NARROW_WIDTH;

public:
    void setup(ServerInterface &, const SizedColumnTypes &argTypes) override { width_ = width_for_inputs(argTypes); }

    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            const VString &x = in.getStringRef(0);
            const VString &y = in.getStringRef(1);
            if (x.isNull() || y.isNull()) {
                out.getStringRef().setNull();
            } else {
                decode(codec_, x, a_);
                decode(codec_, y, b_);
                vbitmap::align_widths(a_, b_);
                switch (OP) {
                case Op::And: a_.and_with(b_); break;
                case Op::Or: a_.or_with(b_); break;
                case Op::Xor: a_.xor_with(b_); break;
                case Op::AndNot: a_.andnot_with(b_); break;
                }
                codec_.encode(a_, out_);
                put_payload(out.getStringRef(), out_, width_);
            }
            out.next();
        } while (in.next());
        VBITMAP_CATCH(op_name(OP))
    }
};

template <Op OP>
class SetOpFactory : public ScalarFunctionFactory {
public:
    SetOpFactory() { vol = IMMUTABLE; strict = RETURN_NULL_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarbinary();
        argTypes.addVarbinary();
        returnType.addVarbinary();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &in, SizedColumnTypes &out) override
    {
        out.addVarbinary(width_for_inputs(in), "payload");
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<SetOp<OP>>(srv.allocator);
    }
};

}  // namespace

class BmAndFactory : public SetOpFactory<Op::And> {};
class BmOrFactory : public SetOpFactory<Op::Or> {};
class BmXorFactory : public SetOpFactory<Op::Xor> {};
class BmAndNotFactory : public SetOpFactory<Op::AndNot> {};
RegisterFactory(BmAndFactory);
RegisterFactory(BmOrFactory);
RegisterFactory(BmXorFactory);
RegisterFactory(BmAndNotFactory);

// ---- bm_cardinality ---------------------------------------------------------------------------

class BmCardinality : public ScalarFunction {
public:
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            const VString &x = in.getStringRef(0);
            if (x.isNull()) out.setInt(vint_null);
            else out.setInt(static_cast<vint>(vbitmap::inspect(x.data(), static_cast<size_t>(x.length())).cardinality));
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_cardinality")
    }
};

class BmCardinalityFactory : public ScalarFunctionFactory {
public:
    BmCardinalityFactory() { vol = IMMUTABLE; strict = RETURN_NULL_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarbinary();
        returnType.addInt();
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmCardinality>(srv.allocator);
    }
};
RegisterFactory(BmCardinalityFactory);

// ---- bm_and_cardinality -----------------------------------------------------------------------

class BmAndCardinality : public ScalarFunction {
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap a_, b_;
    std::string last_a_;   // bytes of the first argument of the previous row
    bool have_a_ = false;

public:
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            const VString &x = in.getStringRef(0);
            const VString &y = in.getStringRef(1);
            if (x.isNull() || y.isNull()) {
                out.setInt(vint_null);
            } else {
                // One audience joined to many sets passes the same first argument row after row:
                // it is decoded once per run of equal bytes (compared in full, not by checksum).
                const size_t n = static_cast<size_t>(x.length());
                if (!have_a_ || n != last_a_.size() || std::memcmp(x.data(), last_a_.data(), n) != 0) {
                    decode(codec_, x, a_);
                    last_a_.assign(x.data(), n);
                    have_a_ = true;
                }
                decode(codec_, y, b_);
                vbitmap::align_widths(a_, b_);
                out.setInt(static_cast<vint>(vbitmap::and_cardinality(a_, b_)));
            }
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_and_cardinality")
    }
};

class BmAndCardinalityFactory : public ScalarFunctionFactory {
public:
    BmAndCardinalityFactory() { vol = IMMUTABLE; strict = RETURN_NULL_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarbinary();
        argTypes.addVarbinary();
        returnType.addInt();
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmAndCardinality>(srv.allocator);
    }
};
RegisterFactory(BmAndCardinalityFactory);

// ---- bm_contains ------------------------------------------------------------------------------

class BmContains : public ScalarFunction {
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap b_;

public:
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            const VString &x = in.getStringRef(0);
            const vint id = in.getIntRef(1);
            if (x.isNull() || id == vint_null) {
                out.setBool(vbool_null);
            } else {
                decode(codec_, x, b_);
                if (id < 0 || id >= static_cast<vint>(b_.universe()))
                    throw vbitmap::UsageError("local ID " + std::to_string(id) + " is outside a chunk of " +
                                              std::to_string(b_.chunk_bits()) + " bits (pass entity_id & (2^bits - 1))");
                out.setBool(b_.contains(static_cast<uint32_t>(id)) ? vbool_true : vbool_false);
            }
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_contains")
    }
};

class BmContainsFactory : public ScalarFunctionFactory {
public:
    BmContainsFactory() { vol = IMMUTABLE; strict = RETURN_NULL_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarbinary();
        argTypes.addInt();
        returnType.addBool();
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmContains>(srv.allocator);
    }
};
RegisterFactory(BmContainsFactory);

// ---- bm_empty ---------------------------------------------------------------------------------

class BmEmpty : public ScalarFunction {
    std::vector<uint8_t> out_;

public:
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        vbitmap::PayloadCodec codec;
        codec.encode(vbitmap::Bitmap(chunk_bits_param(srv)), out_);
    }
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            put_payload(out.getStringRef(), out_, static_cast<int32>(vbitmap::HEADER_SIZE));
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_empty")
    }
};

class BmEmptyFactory : public ScalarFunctionFactory {
public:
    BmEmptyFactory() { vol = IMMUTABLE; }
    void getPrototype(ServerInterface &, ColumnTypes &, ColumnTypes &returnType) override { returnType.addVarbinary(); }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarbinary(static_cast<int32>(vbitmap::HEADER_SIZE), "payload");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override { params.addInt("chunk_bits"); }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmEmpty>(srv.allocator);
    }
};
RegisterFactory(BmEmptyFactory);

// ---- bm_info ----------------------------------------------------------------------------------

class BmInfo : public ScalarFunction {
public:
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            const VString &x = in.getStringRef(0);
            if (x.isNull()) out.getStringRef().setNull();
            else out.getStringRef().copy(vbitmap::describe(x.data(), static_cast<size_t>(x.length())));
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_info")
    }
};

class BmInfoFactory : public ScalarFunctionFactory {
public:
    BmInfoFactory() { vol = IMMUTABLE; strict = RETURN_NULL_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarbinary();
        returnType.addVarchar();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarchar(128, "info");
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmInfo>(srv.allocator);
    }
};
RegisterFactory(BmInfoFactory);

// ---- bm_version -------------------------------------------------------------------------------

#ifndef VBITMAP_VERSION
#define VBITMAP_VERSION "dev"
#endif
#ifndef VBITMAP_BUILD_FLAGS
#define VBITMAP_BUILD_FLAGS ""
#endif

class BmVersion : public ScalarFunction {
public:
    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        const std::string v = std::string("vbitmap ") + VBITMAP_VERSION + "; format " + std::to_string(vbitmap::FORMAT_VERSION) +
                              "; CRoaring " + vbitmap::roaring_version() + "; " + VBITMAP_BUILD_FLAGS;
        do {
            out.getStringRef().copy(v);
            out.next();
        } while (in.next());
    }
};

class BmVersionFactory : public ScalarFunctionFactory {
public:
    BmVersionFactory() { vol = IMMUTABLE; }
    void getPrototype(ServerInterface &, ColumnTypes &, ColumnTypes &returnType) override { returnType.addVarchar(); }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarchar(256, "version");
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmVersion>(srv.allocator);
    }
};
RegisterFactory(BmVersionFactory);
