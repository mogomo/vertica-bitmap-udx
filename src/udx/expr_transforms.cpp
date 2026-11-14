// Expression transforms: one scan of the index rows of a chunk, no joins.
//
//   bm_count (chunk_id, predicate, payload USING PARAMETERS expr='...') OVER (PARTITION BY chunk_id)
//       -> (chunk_id, cnt)            members of the expression in the chunk (chunks with 0 left out)
//   bm_eval  (chunk_id, predicate, payload USING PARAMETERS expr='...') OVER (PARTITION BY chunk_id)
//       -> (chunk_id, payload)        the result set (empty chunks left out)
//   bm_ids   (chunk_id, predicate, payload USING PARAMETERS expr='...' [, max_ids=N] [, text=true]) OVER (PARTITION BY chunk_id)
//       -> (entity_id)                members in ascending order, at most max_ids per chunk. With
//                                     text = true the column is VARCHAR(20) holding the decimal
//                                     ID: the form for sending one row per ID to a client (the
//                                     same bytes on the wire, formatted here instead of by the
//                                     server's result writer). INT is the form for joins and
//                                     inserts inside the database.
//   bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr='...' [, sep=E'\n']) OVER (PARTITION BY chunk_id)
//       -> (ids)                      the same members as text: decimal IDs in ascending order, joined
//                                     by `sep`, in blocks of at most 65,000 bytes (one row per block,
//                                     no separator at either end). The rows joined by `sep` are the
//                                     list bm_ids returns, at a fraction of the cost of sending one
//                                     row per ID to a client.
//   bm_facets(chunk_id, predicate, payload USING PARAMETERS expr='...', facets='topic_' [, exclude='topic_'])
//            OVER (PARTITION BY chunk_id)
//       -> (predicate, cnt)           for every input row whose predicate starts with `facets`:
//                                     |audience AND that set| (0 left out). With `exclude`, operands
//                                     starting with that prefix are removed from the audience first.
//
//   bm_pin   (chunk_id, predicate, payload USING PARAMETERS expr='...', name='aud') OVER ()
//       -> (members, chunks)          evaluates the expression and pins the result for this
//                                     session (pinned.h); bm_member then tests IDs against it.
//                                     One partition holds every chunk: no PARTITION BY.
//
// The input rows are the index rows of one tenant, snapshot and domain (filter them in WHERE):
// a predicate that is not an operand is ignored (except as a facet), an operand without a row in
// the chunk is the empty set. Expression syntax: src/engine/expr.h.
#include "block_access.h"
#include "expr.h"
#include "pinned.h"
#include "udx_common.h"

#include <charconv>
#include <unordered_map>

using namespace Vertica;
using namespace vbitmap_udx;

namespace {

std::string string_param(ServerInterface &srv, const char *name, bool required)
{
    ParamReader p = srv.getParamReader();
    if (!p.containsParameter(name)) {
        if (required) throw vbitmap::UsageError(std::string("parameter '") + name + "' is required");
        return "";
    }
    return p.getStringRef(name).str();
}

class ExprFunction : public TransformFunction {
protected:
    const char *fn_;
    vbitmap::Expression expr_;
    std::unordered_map<std::string, int> slot_;
    std::vector<std::string> bytes_;
    std::vector<bool> present_;
    std::vector<vbitmap::Bitmap> sets_;
    std::vector<const vbitmap::Bitmap *> ops_;
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap result_;
    vint chunk_ = 0;
    int chunk_bits_ = vbitmap::DEFAULT_CHUNK_BITS;

    explicit ExprFunction(const char *fn) : fn_(fn) {}

    void prepare(const std::string &text, const std::string &exclude)
    {
        expr_ = vbitmap::Expression::parse(text).without_prefix(exclude);
        const size_t n = expr_.names().size();
        slot_.clear();
        for (size_t i = 0; i < n; ++i) slot_.emplace(expr_.names()[i], static_cast<int>(i));
        bytes_.assign(n, std::string());
        present_.assign(n, false);
        sets_.assign(n, vbitmap::Bitmap());
        ops_.assign(n, nullptr);
    }

    // Hook for rows that are not operands (facets).
    virtual void on_row(const VString &, const VString &) {}
    virtual void on_partition_start() {}

    // Reads the partition. Returns false if the result is certainly empty.
    bool gather(PartitionReader &in)
    {
        std::fill(present_.begin(), present_.end(), false);
        on_partition_start();
        bool first = true;
        uint64_t rows = 0;
        do {
            const vint chunk = in.getIntRef(0);
            if (chunk == vint_null) throw vbitmap::UsageError("NULL chunk_id");
            if (first) {
                chunk_ = chunk;
                first = false;
            } else if (chunk != chunk_) {
                throw vbitmap::UsageError("chunk_id differs inside one partition: use OVER (PARTITION BY chunk_id)");
            }
            const VString &pred = in.getStringRef(1);
            const VString &payload = in.getStringRef(2);
            if (pred.isNull() || payload.isNull()) continue;
            on_row(pred, payload);
            auto it = slot_.find(std::string(pred.data(), static_cast<size_t>(pred.length())));
            if (it != slot_.end()) {
                const size_t s = static_cast<size_t>(it->second);
                if (present_[s])
                    throw vbitmap::UsageError("predicate '" + it->first + "' appears twice in chunk " + std::to_string(chunk_) +
                                              ": filter the input to one tenant, snapshot and domain");
                present_[s] = true;
                bytes_[s].assign(payload.data(), static_cast<size_t>(payload.length()));
            }
            if ((++rows & 0xFFFF) == 0 && isCanceled()) return false;
        } while (in.next());
        return expr_.can_be_nonempty(present_);
    }

    // Decodes the present operands and evaluates. Returns false if the result is empty.
    bool evaluate()
    {
        int width = -1;
        for (size_t s = 0; s < bytes_.size(); ++s) {
            ops_[s] = nullptr;
            if (!present_[s]) continue;
            codec_.decode(bytes_[s].data(), bytes_[s].size(), sets_[s]);
            if (sets_[s].empty()) continue;   // an empty payload of any width is the empty set
            if (width < 0) width = sets_[s].chunk_bits();
            else if (sets_[s].chunk_bits() != width)
                throw vbitmap::UsageError("payloads of different chunk widths in chunk " + std::to_string(chunk_));
            ops_[s] = &sets_[s];
        }
        if (width < 0) return false;   // every operand empty or missing
        chunk_bits_ = width;
        expr_.evaluate(ops_, width, result_);
        return !result_.empty();
    }
};

// ---- bm_count ---------------------------------------------------------------------------------

class BmCount : public ExprFunction {
public:
    BmCount() : ExprFunction("bm_count") {}
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        prepare(string_param(srv, "expr", true), "");
        VBITMAP_CATCH(fn_)
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        if (!gather(in) || !evaluate()) return;
        out.setInt(0, chunk_);
        out.setInt(1, static_cast<vint>(result_.cardinality()));
        out.next();
        VBITMAP_CATCH(fn_)
    }
};

// ---- bm_eval ----------------------------------------------------------------------------------

class BmEval : public ExprFunction {
    std::vector<uint8_t> out_;
    int32 width_ = NARROW_WIDTH;

public:
    BmEval() : ExprFunction("bm_eval") {}
    void setup(ServerInterface &srv, const SizedColumnTypes &argTypes) override
    {
        VBITMAP_TRY
        width_ = width_for_inputs(argTypes);
        prepare(string_param(srv, "expr", true), "");
        VBITMAP_CATCH(fn_)
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        if (!gather(in) || !evaluate()) return;
        codec_.encode(result_, out_);
        out.setInt(0, chunk_);
        put_payload(out.getStringRef(1), out_, width_);
        out.next();
        VBITMAP_CATCH(fn_)
    }
};

// ---- bm_ids -----------------------------------------------------------------------------------

class BmIds : public ExprFunction {
    std::vector<uint32_t> ids_;
    vint max_ids_ = 0;
    bool text_ = false;

public:
    BmIds() : ExprFunction("bm_ids") {}
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        prepare(string_param(srv, "expr", true), "");
        ParamReader p = srv.getParamReader();
        max_ids_ = p.containsParameter("max_ids") ? p.getIntRef("max_ids") : 0;
        if (max_ids_ < 0) throw vbitmap::UsageError("max_ids must be 0 (no limit) or positive");
        text_ = p.containsParameter("text") && p.getBoolRef("text") == vbool_true;
        VBITMAP_CATCH(fn_)
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        if (!gather(in) || !evaluate()) return;
        ids_.clear();
        result_.to_local_ids(ids_);
        size_t n = ids_.size();
        if (max_ids_ > 0 && static_cast<vint>(n) > max_ids_) n = static_cast<size_t>(max_ids_);
        // One row per ID. The cursor is stepped block-wise (block_access.h): the values written
        // are valid by construction, so the per-row validation of next() is left out.
        char digits[24];
        for (size_t i = 0; i < n; ++i) {
            const vint id = static_cast<vint>(vbitmap::entity_of(chunk_, ids_[i], chunk_bits_));
            if (text_) {
                const char *end = std::to_chars(digits, digits + sizeof digits, static_cast<long long>(id)).ptr;
                out.getStringRef(0).copy(digits, static_cast<vsize>(end - digits));
            } else {
                out.setInt(0, id);
            }
            if (!BlockCursor::step(out)) out.next();
            if ((i & 0xFFFF) == 0xFFFF && isCanceled()) return;
        }
        VBITMAP_CATCH(fn_)
    }
};

// ---- bm_ids_text ------------------------------------------------------------------------------

class BmIdsText : public ExprFunction {
    static constexpr size_t BLOCK = 65000;   // declared width of the output column
    std::vector<uint32_t> ids_;
    std::string sep_ = "\n";
    std::string block_;

public:
    BmIdsText() : ExprFunction("bm_ids_text") {}
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        prepare(string_param(srv, "expr", true), "");
        ParamReader p = srv.getParamReader();
        if (p.containsParameter("sep")) sep_ = p.getStringRef("sep").str();
        if (sep_.empty()) throw vbitmap::UsageError("sep must not be empty");
        block_.reserve(BLOCK);
        VBITMAP_CATCH(fn_)
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        if (!gather(in) || !evaluate()) return;
        ids_.clear();
        result_.to_local_ids(ids_);
        block_.clear();
        char digits[24];
        for (uint32_t local : ids_) {
            const int64_t id = vbitmap::entity_of(chunk_, local, chunk_bits_);
            const char *end = std::to_chars(digits, digits + sizeof digits, id).ptr;
            const size_t n = static_cast<size_t>(end - digits);
            if (!block_.empty()) {
                if (block_.size() + sep_.size() + n > BLOCK) {
                    out.getStringRef(0).copy(block_.data(), static_cast<vsize>(block_.size()));
                    out.next();
                    block_.clear();
                    if (isCanceled()) return;
                } else {
                    block_ += sep_;
                }
            }
            block_.append(digits, n);
        }
        out.getStringRef(0).copy(block_.data(), static_cast<vsize>(block_.size()));
        out.next();
        VBITMAP_CATCH(fn_)
    }
};

// ---- bm_facets --------------------------------------------------------------------------------

class BmFacets : public ExprFunction {
    std::string prefix_;
    std::vector<std::pair<std::string, std::string>> facets_;   // (predicate, payload bytes)
    vbitmap::Bitmap facet_;

    void on_partition_start() override { facets_.clear(); }
    void on_row(const VString &pred, const VString &payload) override
    {
        const size_t n = static_cast<size_t>(pred.length());
        if (n >= prefix_.size() && std::memcmp(pred.data(), prefix_.data(), prefix_.size()) == 0)
            facets_.emplace_back(std::string(pred.data(), n), std::string(payload.data(), static_cast<size_t>(payload.length())));
    }

public:
    BmFacets() : ExprFunction("bm_facets") {}
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        prefix_ = string_param(srv, "facets", true);
        prepare(string_param(srv, "expr", true), string_param(srv, "exclude", false));
        VBITMAP_CATCH(fn_)
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        if (!gather(in) || !evaluate()) return;
        for (const auto &f : facets_) {
            codec_.decode(f.second.data(), f.second.size(), facet_);
            vbitmap::align_widths(result_, facet_);
            const uint64_t c = vbitmap::and_cardinality(result_, facet_);
            if (c == 0) continue;
            out.getStringRef(0).copy(f.first);
            out.setInt(1, static_cast<vint>(c));
            out.next();
        }
        VBITMAP_CATCH(fn_)
    }
};

// ---- bm_pin (expression form) -----------------------------------------------------------------

class BmPinExpr : public ExprFunction {
    PinBuilder pin_;
    struct Operands {
        std::vector<std::string> bytes;
        std::vector<bool> present;
    };

public:
    BmPinExpr() : ExprFunction("bm_pin") {}
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        prepare(string_param(srv, "expr", true), "");
        pin_.setup(srv);
        VBITMAP_CATCH(fn_)
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        // Every chunk arrives in this one partition, in any order: the operand payloads are
        // collected per chunk, then each chunk is evaluated.
        const size_t n = expr_.names().size();
        std::unordered_map<vint, Operands> chunks;
        uint64_t rows = 0;
        do {
            const vint chunk = in.getIntRef(0);
            const VString &pred = in.getStringRef(1);
            const VString &payload = in.getStringRef(2);
            if (chunk != vint_null && !pred.isNull() && !payload.isNull()) {
                auto it = slot_.find(std::string(pred.data(), static_cast<size_t>(pred.length())));
                if (it != slot_.end()) {
                    Operands &o = chunks[chunk];
                    if (o.bytes.empty()) {
                        o.bytes.assign(n, std::string());
                        o.present.assign(n, false);
                    }
                    const size_t s = static_cast<size_t>(it->second);
                    if (o.present[s])
                        throw vbitmap::UsageError("predicate '" + it->first + "' appears twice in chunk " + std::to_string(chunk) +
                                                  ": filter the input to one tenant, snapshot and domain");
                    o.present[s] = true;
                    o.bytes[s].assign(payload.data(), static_cast<size_t>(payload.length()));
                }
            }
            VBITMAP_CANCEL_POINT(rows)
        } while (in.next());
        for (auto &c : chunks) {
            if (!expr_.can_be_nonempty(c.second.present)) continue;
            chunk_ = c.first;
            bytes_.swap(c.second.bytes);
            present_.swap(c.second.present);
            if (evaluate()) pin_.add(chunk_, result_);
        }
        pin_.publish();
        out.setInt(0, static_cast<vint>(pin_.members()));
        out.setInt(1, static_cast<vint>(pin_.chunks()));
        out.next();
        VBITMAP_CATCH(fn_)
    }
    void destroy(ServerInterface &, const SizedColumnTypes &, SessionParamWriterMap &ud) override
    {
        VBITMAP_TRY
        pin_.finish(ud);
        VBITMAP_CATCH(fn_)
    }
};

// ---- factories --------------------------------------------------------------------------------

void expr_prototype(ColumnTypes &argTypes)
{
    argTypes.addInt();
    argTypes.addVarchar();
    argTypes.addVarbinary();
}

}  // namespace

class BmCountFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        expr_prototype(argTypes);
        returnType.addInt();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addInt("chunk_id");
        out.addInt("cnt");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override { params.addVarchar(65000, "expr"); }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmCount>(srv.allocator);
    }
};
RegisterFactory(BmCountFactory);

class BmEvalFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        expr_prototype(argTypes);
        returnType.addInt();
        returnType.addVarbinary();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &in, SizedColumnTypes &out) override
    {
        out.addInt("chunk_id");
        out.addVarbinary(width_for_inputs(in), "payload");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override { params.addVarchar(65000, "expr"); }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmEval>(srv.allocator);
    }
};
RegisterFactory(BmEvalFactory);

class BmIdsFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        expr_prototype(argTypes);
        returnType.addAny();   // INT, or VARCHAR with text = true
    }
    void getReturnType(ServerInterface &srv, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        ParamReader p = srv.getParamReader();
        if (p.containsParameter("text") && p.getBoolRef("text") == vbool_true) out.addVarchar(20, "entity_id");
        else out.addInt("entity_id");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override
    {
        params.addVarchar(65000, "expr");
        params.addInt("max_ids");
        params.addBool("text");
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmIds>(srv.allocator);
    }
};
RegisterFactory(BmIdsFactory);

class BmIdsTextFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        expr_prototype(argTypes);
        returnType.addVarchar();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarchar(65000, "ids");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override
    {
        params.addVarchar(65000, "expr");
        params.addVarchar(8, "sep");
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmIdsText>(srv.allocator);
    }
};
RegisterFactory(BmIdsTextFactory);

class BmFacetsFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        expr_prototype(argTypes);
        returnType.addVarchar();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addVarchar(80, "predicate");
        out.addInt("cnt");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override
    {
        params.addVarchar(65000, "expr");
        params.addVarchar(80, "facets");
        params.addVarchar(80, "exclude");
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmFacets>(srv.allocator);
    }
};
RegisterFactory(BmFacetsFactory);

class BmPinExprFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        expr_prototype(argTypes);
        returnType.addInt();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addInt("members");
        out.addInt("chunks");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override
    {
        params.addVarchar(65000, "expr");
        params.addVarchar(256, "name");
    }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmPinExpr>(srv.allocator);
    }
};
RegisterFactory(BmPinExprFactory);
