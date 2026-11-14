// Pinned sets: a set kept in the memory of the process that runs the functions, so that a scalar
// function can test rows against it on every scan thread without the set travelling with the rows.
//
//   bm_pin    builds the set and registers it under a random token; the token is written to a
//             user-defined session parameter (pin_<name>) when the statement ends.
//   bm_member reads the token of its session and tests IDs against the set.
//
// A set belongs to the session that pinned it: another session has no token for it. Sets live in
// process memory: unfenced that is the server process of the node that ran bm_pin, fenced the
// side process of the session. A set that is no longer there (dropped after IDLE_SECONDS without
// use, pushed out by CAP_BYTES, node restarted, another node) is reported as an error by
// bm_member, never read as an empty set.
#pragma once

#include "udx_common.h"

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace vbitmap_udx {

class PinnedSet {
public:
    // Adds the members of one chunk (union if the chunk was added before). Before seal() only.
    void add(int64_t chunk, const vbitmap::Bitmap &b);
    // Builds the lookup table. After it the set is read-only and safe to share between threads.
    void seal();

    int chunk_bits() const { return chunk_bits_; }
    size_t chunks() const { return ids_.size(); }
    uint64_t members() const { return members_; }
    size_t bytes() const { return words_.size() * sizeof(uint64_t) + slot_.size() * sizeof(int32_t) + ids_.size() * sizeof(int64_t); }

    // The words of a chunk, or nullptr if no member is in it.
    const uint64_t *find(int64_t chunk) const
    {
        if (dense_) {
            const uint64_t c = static_cast<uint64_t>(chunk - base_);
            if (c >= slot_.size()) return nullptr;
            const int32_t s = slot_[c];
            return s < 0 ? nullptr : &words_[static_cast<size_t>(s) * words_per_chunk_];
        }
        size_t lo = 0, hi = ids_.size();
        while (lo < hi) {
            const size_t mid = (lo + hi) / 2;
            if (ids_[mid] < chunk) lo = mid + 1;
            else hi = mid;
        }
        return lo < ids_.size() && ids_[lo] == chunk ? &words_[lo * words_per_chunk_] : nullptr;
    }

private:
    int chunk_bits_ = 0;   // 0 until the first chunk
    size_t words_per_chunk_ = 0;
    uint64_t members_ = 0;
    std::vector<int64_t> ids_;      // chunk IDs; ascending after seal()
    std::vector<uint64_t> words_;   // ids_.size() * words_per_chunk_
    std::unordered_map<int64_t, size_t> pos_;   // chunk -> position, before seal()
    bool dense_ = false;
    int64_t base_ = 0;
    std::vector<int32_t> slot_;     // chunk - base_ -> position or -1 (dense chunk ranges)
};

namespace pins {

inline constexpr int64_t IDLE_SECONDS = 1800;          // a set not used for this long may be dropped
inline constexpr size_t CAP_BYTES = size_t{1} << 30;   // all pinned sets of a process together

// Registers a sealed set and returns its token. Drops idle sets, then the least recently used
// ones while the total is above CAP_BYTES.
std::string put(std::shared_ptr<const PinnedSet> set);
// The set of a token, or nullptr.
std::shared_ptr<const PinnedSet> get(const std::string &token);
// True if a set was dropped.
bool drop(const std::string &token);

// "pin_<name>" after checking the name: letters, digits and underscore, at most 64 characters.
std::string param_name(const std::string &name);

}  // namespace pins

// The part bm_pin's two forms share: the name, the set under construction, the token.
class PinBuilder {
public:
    void setup(Vertica::ServerInterface &srv);
    void add(int64_t chunk, const vbitmap::Bitmap &b)
    {
        check_open();
        set_->add(chunk, b);
    }
    // Seals and registers the set; replaces the set the session pinned under the name before.
    void publish();
    uint64_t members() const { return members_; }
    size_t chunks() const { return chunks_; }
    // Writes the token to the session (or clears the parameter if nothing was pinned).
    void finish(Vertica::SessionParamWriterMap &ud);

private:
    // One partition holds the whole set: a second partition is a usage error, never a second set.
    void check_open() const
    {
        if (published_ || !set_) throw vbitmap::UsageError("all rows must be in one partition: call it OVER ()");
    }
    std::string key_, old_token_, token_;
    std::shared_ptr<PinnedSet> set_ = std::make_shared<PinnedSet>();
    uint64_t members_ = 0;
    size_t chunks_ = 0;
    bool published_ = false;
};

}  // namespace vbitmap_udx
