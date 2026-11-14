// Pinned sets (pinned.h) and the functions on them.
//
//   bm_pin(chunk_id, payload USING PARAMETERS name='aud') OVER ()
//       -> (members, chunks)   pins the union of the payload rows (a saved set, the rows of
//                              bm_eval, the index rows of one predicate) under the name, for
//                              this session. NULL rows are skipped, so a query that appends
//                              "UNION ALL SELECT NULL, NULL" pins the empty set when the
//                              audience is empty instead of not being called at all.
//       The form that evaluates an expression in the same pass is in expr_transforms.cpp.
//   bm_member(entity_id USING PARAMETERS name='aud')            BOOLEAN
//       true if the ID is in the set pinned under the name by this session. Runs on every scan
//       thread; the set does not travel with the rows. An error if no such set is in memory.
//   bm_unpin(name)                                              BOOLEAN
//       drops the set; true if there was one.
#include "block_access.h"
#include "pinned.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <mutex>
#include <numeric>
#include <random>

using namespace Vertica;
using namespace vbitmap_udx;

// ---- PinnedSet --------------------------------------------------------------------------------

void PinnedSet::add(int64_t chunk, const vbitmap::Bitmap &b)
{
    if (b.empty()) return;
    if (chunk_bits_ == 0) {
        chunk_bits_ = b.chunk_bits();
        words_per_chunk_ = b.word_count();
    } else if (b.chunk_bits() != chunk_bits_) {
        throw vbitmap::UsageError("payloads of different chunk widths cannot be pinned as one set");
    }
    auto it = pos_.find(chunk);
    if (it == pos_.end()) {
        pos_.emplace(chunk, ids_.size());
        ids_.push_back(chunk);
        words_.insert(words_.end(), b.words(), b.words() + words_per_chunk_);
    } else {
        uint64_t *w = &words_[it->second * words_per_chunk_];
        for (size_t i = 0; i < words_per_chunk_; ++i) w[i] |= b.words()[i];
    }
}

void PinnedSet::seal()
{
    const size_t n = ids_.size();
    std::vector<size_t> order(n);
    std::iota(order.begin(), order.end(), size_t{0});
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return ids_[a] < ids_[b]; });
    std::vector<int64_t> ids(n);
    std::vector<uint64_t> words(words_.size());
    for (size_t i = 0; i < n; ++i) {
        ids[i] = ids_[order[i]];
        std::memcpy(&words[i * words_per_chunk_], &words_[order[i] * words_per_chunk_], words_per_chunk_ * sizeof(uint64_t));
    }
    ids_.swap(ids);
    words_.swap(words);
    std::unordered_map<int64_t, size_t>().swap(pos_);
    members_ = 0;
    for (uint64_t w : words_) members_ += static_cast<uint64_t>(__builtin_popcountll(w));
    // A direct table when the chunk IDs are close together (dense ID spaces), else binary search.
    dense_ = false;
    if (n > 0) {
        const uint64_t range = static_cast<uint64_t>(ids_.back() - ids_.front()) + 1;
        if (range <= 4 * n + 1024) {
            dense_ = true;
            base_ = ids_.front();
            slot_.assign(static_cast<size_t>(range), -1);
            for (size_t i = 0; i < n; ++i) slot_[static_cast<size_t>(ids_[i] - base_)] = static_cast<int32_t>(i);
        }
    }
}

// ---- registry ---------------------------------------------------------------------------------

namespace {

using Clock = std::chrono::steady_clock;

struct Entry {
    std::shared_ptr<const PinnedSet> set;
    Clock::time_point used;
};

std::mutex g_lock;
std::unordered_map<std::string, Entry> g_sets;
size_t g_bytes = 0;

void erase_locked(std::unordered_map<std::string, Entry>::iterator it)
{
    g_bytes -= it->second.set->bytes();
    g_sets.erase(it);
}

std::string new_token()
{
    static const char digits[] = "0123456789abcdef";
    std::random_device rd;
    std::string t;
    for (int i = 0; i < 4; ++i) {
        uint32_t v = rd();
        for (int k = 0; k < 8; ++k, v >>= 4) t.push_back(digits[v & 15]);
    }
    return t;
}

}  // namespace

std::string pins::put(std::shared_ptr<const PinnedSet> set)
{
    const size_t size = set->bytes();
    if (size > CAP_BYTES)
        throw vbitmap::UsageError("a set of " + std::to_string(size) + " bytes is larger than the limit for pinned sets (" +
                                  std::to_string(CAP_BYTES) + " bytes)");
    const Clock::time_point now = Clock::now();
    std::lock_guard<std::mutex> guard(g_lock);
    for (auto it = g_sets.begin(); it != g_sets.end();) {
        if (now - it->second.used > std::chrono::seconds(IDLE_SECONDS)) {
            g_bytes -= it->second.set->bytes();
            it = g_sets.erase(it);
        } else {
            ++it;
        }
    }
    while (g_bytes + size > CAP_BYTES && !g_sets.empty()) {
        auto oldest = g_sets.begin();
        for (auto it = g_sets.begin(); it != g_sets.end(); ++it)
            if (it->second.used < oldest->second.used) oldest = it;
        erase_locked(oldest);
    }
    std::string token = new_token();
    while (g_sets.count(token)) token = new_token();
    g_sets.emplace(token, Entry{std::move(set), now});
    g_bytes += size;
    return token;
}

std::shared_ptr<const PinnedSet> pins::get(const std::string &token)
{
    std::lock_guard<std::mutex> guard(g_lock);
    auto it = g_sets.find(token);
    if (it == g_sets.end()) return nullptr;
    it->second.used = Clock::now();
    return it->second.set;
}

bool pins::drop(const std::string &token)
{
    std::lock_guard<std::mutex> guard(g_lock);
    auto it = g_sets.find(token);
    if (it == g_sets.end()) return false;
    erase_locked(it);
    return true;
}

std::string pins::param_name(const std::string &name)
{
    if (name.empty() || name.size() > 64) throw vbitmap::UsageError("the name of a pinned set has 1 to 64 characters");
    std::string key = "pin_";
    for (char c : name) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
        if (!ok) throw vbitmap::UsageError("the name of a pinned set may hold letters, digits and underscores only");
        key.push_back(c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c);
    }
    return key;
}

// ---- PinBuilder -------------------------------------------------------------------------------

namespace {

std::string name_param(ServerInterface &srv)
{
    ParamReader p = srv.getParamReader();
    if (!p.containsParameter("name")) throw vbitmap::UsageError("parameter 'name' is required");
    return p.getStringRef("name").str();
}

std::string session_token(ServerInterface &srv, const std::string &key)
{
    ParamReader sp = srv.getUDSessionParamReader("library");
    return sp.containsParameter(key) ? sp.getStringRef(key).str() : std::string();
}

}  // namespace

void PinBuilder::setup(ServerInterface &srv)
{
    key_ = pins::param_name(name_param(srv));
    old_token_ = session_token(srv, key_);
}

void PinBuilder::publish()
{
    check_open();
    set_->seal();
    members_ = set_->members();
    chunks_ = set_->chunks();
    token_ = pins::put(set_);
    set_.reset();
    if (!old_token_.empty()) pins::drop(old_token_);
    published_ = true;
}

void PinBuilder::finish(SessionParamWriterMap &ud)
{
    if (key_.empty()) return;
    ParamWriter &w = ud.getUDSessionParamWriter("library");
    if (published_) w.getStringRef(key_).copy(token_);
    else w.clearParameter(key_);
}

// ---- bm_pin(chunk_id, payload) ----------------------------------------------------------------

class BmPin : public TransformFunction {
    PinBuilder pin_;
    vbitmap::PayloadCodec codec_;
    vbitmap::Bitmap b_;

public:
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        pin_.setup(srv);
        VBITMAP_CATCH("bm_pin")
    }
    void processPartition(ServerInterface &, PartitionReader &in, PartitionWriter &out) override
    {
        VBITMAP_TRY
        uint64_t rows = 0;
        do {
            const vint chunk = in.getIntRef(0);
            const VString &p = in.getStringRef(1);
            if (chunk != vint_null && !p.isNull()) {
                decode(codec_, p, b_);
                pin_.add(chunk, b_);
            }
            VBITMAP_CANCEL_POINT(rows)
        } while (in.next());
        pin_.publish();
        out.setInt(0, static_cast<vint>(pin_.members()));
        out.setInt(1, static_cast<vint>(pin_.chunks()));
        out.next();
        VBITMAP_CATCH("bm_pin")
    }
    void destroy(ServerInterface &, const SizedColumnTypes &, SessionParamWriterMap &ud) override
    {
        VBITMAP_TRY
        pin_.finish(ud);
        VBITMAP_CATCH("bm_pin")
    }
};

class BmPinFactory : public TransformFunctionFactory {
public:
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addInt();
        argTypes.addVarbinary();
        returnType.addInt();
        returnType.addInt();
    }
    void getReturnType(ServerInterface &, const SizedColumnTypes &, SizedColumnTypes &out) override
    {
        out.addInt("members");
        out.addInt("chunks");
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override { params.addVarchar(256, "name"); }
    TransformFunction *createTransformFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmPin>(srv.allocator);
    }
};
RegisterFactory(BmPinFactory);

// ---- bm_member --------------------------------------------------------------------------------

class BmMember : public ScalarFunction {
    std::shared_ptr<const PinnedSet> set_;
    int chunk_bits_ = vbitmap::DEFAULT_CHUNK_BITS;
    vint mask_ = 0xFFFF;
    int64_t last_chunk_ = -1;
    const uint64_t *last_words_ = nullptr;

    vbool test(vint id)
    {
        if (id == vint_null) return vbool_null;
        if (id < 0) return vbool_false;
        const int64_t chunk = id >> chunk_bits_;
        if (chunk != last_chunk_) {
            last_words_ = set_->find(chunk);
            last_chunk_ = chunk;
        }
        if (last_words_ == nullptr) return vbool_false;
        const vint local = id & mask_;
        return (last_words_[local >> 6] >> (local & 63)) & 1 ? vbool_true : vbool_false;
    }

public:
    void setup(ServerInterface &srv, const SizedColumnTypes &) override
    {
        VBITMAP_TRY
        const std::string name = name_param(srv);
        const std::string token = session_token(srv, pins::param_name(name));
        if (token.empty()) throw vbitmap::UsageError("this session has no set pinned as '" + name + "': call bm_pin first");
        set_ = pins::get(token);
        if (!set_)
            throw vbitmap::UsageError("the set pinned as '" + name + "' is not in memory on node " + srv.getCurrentNodeName() +
                                      " (a pinned set lives in the process that ran bm_pin, until it is unpinned, idle for " +
                                      std::to_string(pins::IDLE_SECONDS) + " s or pushed out by newer sets): pin it again");
        if (set_->chunk_bits() != 0) chunk_bits_ = set_->chunk_bits();
        mask_ = (vint{1} << chunk_bits_) - 1;
        VBITMAP_CATCH("bm_member")
    }

    void processBlock(ServerInterface &, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        const int n = BlockCursor::dense_rows(in);
        if (n > 0 && n == BlockCursor::dense_rows(out)) {
            const char *src = in.getColPtr<char>(0);
            char *dst = out.getColPtrForWrite<char>(0);
            const ptrdiff_t ss = in.getColStride(0), ds = out.getColStride(0);
            for (int i = 0; i < n; ++i, src += ss, dst += ds)
                *reinterpret_cast<vbool *>(dst) = test(*reinterpret_cast<const vint *>(src));
            BlockCursor::finish(in);
            BlockCursor::finish(out);
            return;
        }
        do {
            out.setBool(test(in.getIntRef(0)));
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_member")
    }
};

class BmMemberFactory : public ScalarFunctionFactory {
public:
    BmMemberFactory() { vol = STABLE; strict = CALLED_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addInt();
        returnType.addBool();
    }
    void getParameterType(ServerInterface &, SizedColumnTypes &params) override { params.addVarchar(256, "name"); }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmMember>(srv.allocator);
    }
};
RegisterFactory(BmMemberFactory);

// ---- bm_unpin ---------------------------------------------------------------------------------

class BmUnpin : public ScalarFunction {
    std::vector<std::string> keys_;

public:
    void processBlock(ServerInterface &srv, BlockReader &in, BlockWriter &out) override
    {
        VBITMAP_TRY
        do {
            const VString &name = in.getStringRef(0);
            if (name.isNull()) {
                out.setBool(vbool_null);
            } else {
                const std::string key = pins::param_name(name.str());
                const std::string token = session_token(srv, key);
                out.setBool(!token.empty() && pins::drop(token) ? vbool_true : vbool_false);
                keys_.push_back(key);
            }
            out.next();
        } while (in.next());
        VBITMAP_CATCH("bm_unpin")
    }
    void destroy(ServerInterface &, const SizedColumnTypes &, SessionParamWriterMap &ud) override
    {
        VBITMAP_TRY
        for (const std::string &key : keys_) ud.getUDSessionParamWriter("library").clearParameter(key);
        VBITMAP_CATCH("bm_unpin")
    }
};

class BmUnpinFactory : public ScalarFunctionFactory {
public:
    BmUnpinFactory() { vol = VOLATILE; strict = CALLED_ON_NULL_INPUT; }
    void getPrototype(ServerInterface &, ColumnTypes &argTypes, ColumnTypes &returnType) override
    {
        argTypes.addVarchar();
        returnType.addBool();
    }
    ScalarFunction *createScalarFunction(ServerInterface &srv) override
    {
        return vt_createFuncObject<BmUnpin>(srv.allocator);
    }
};
RegisterFactory(BmUnpinFactory);
