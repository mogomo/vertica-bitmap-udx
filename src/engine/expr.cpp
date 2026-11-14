// Expression parser (recursive descent) and evaluator (postfix program over a stack of bitmaps).
#include "expr.h"

#include <algorithm>
#include <cstring>
#include <iterator>
#include <unordered_map>

namespace vbitmap {

bool is_bare_name_char(char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' ||
           c == ':' || c == '#';
}

class ExprParser {
public:
    ExprParser(const std::string &text, Expression &e) : s_(text), e_(e) {}

    void run()
    {
        if (s_.size() > Expression::MAX_LENGTH)
            fail(0, "is " + std::to_string(s_.size()) + " characters long; the limit is " +
                        std::to_string(Expression::MAX_LENGTH) +
                        " (a parameter of 65,000 characters may have been cut)");
        skip();
        if (pos_ == s_.size()) fail(pos_, "is empty");
        e_.root_ = parse_or(0);
        skip();
        if (pos_ != s_.size()) fail(pos_, std::string("has an unexpected '") + s_[pos_] + "'");
    }

private:
    const std::string &s_;
    Expression &e_;
    size_t pos_ = 0;
    std::unordered_map<std::string, int> slots_;

    [[noreturn]] void fail(size_t at, const std::string &what) const
    {
        throw UsageError("expression " + what + " at position " + std::to_string(at + 1));
    }

    void skip()
    {
        while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r')) ++pos_;
    }

    int add(Expression::Kind k, int l, int r, int slot = -1)
    {
        e_.nodes_.push_back({k, l, r, slot});
        return static_cast<int>(e_.nodes_.size()) - 1;
    }

    // Balanced tree over items[lo, hi): its height grows with log2 of the operand count, so
    // long chains such as "t1 | t2 | ... | t500" never need deep recursion.
    int balanced(Expression::Kind kind, const std::vector<int> &items, size_t lo, size_t hi)
    {
        if (hi - lo == 1) return items[lo];
        const size_t mid = lo + (hi - lo) / 2;
        const int l = balanced(kind, items, lo, mid);
        return add(kind, l, balanced(kind, items, mid, hi));
    }

    // Chain of one binary operator over operands parsed by next(). &, | and ^ are associative;
    // a - b - c is (a - b) - c, built as a - (b | c).
    template <class Next>
    int chain(char op, Expression::Kind kind, Next next)
    {
        std::vector<int> items = {next()};
        for (;;) {
            skip();
            if (pos_ < s_.size() && s_[pos_] == op) {
                ++pos_;
                items.push_back(next());
            } else {
                break;
            }
        }
        if (items.size() == 1) return items[0];
        if (kind != Expression::Kind::AndNot) return balanced(kind, items, 0, items.size());
        const std::vector<int> rest(items.begin() + 1, items.end());
        const int removed = balanced(Expression::Kind::Or, rest, 0, rest.size());
        return add(Expression::Kind::AndNot, items[0], removed);
    }

    int parse_or(int d) { return chain('|', Expression::Kind::Or, [this, d] { return parse_xor(d); }); }
    int parse_xor(int d) { return chain('^', Expression::Kind::Xor, [this, d] { return parse_diff(d); }); }
    int parse_diff(int d) { return chain('-', Expression::Kind::AndNot, [this, d] { return parse_and(d); }); }
    int parse_and(int d) { return chain('&', Expression::Kind::And, [this, d] { return parse_primary(d); }); }

    int parse_primary(int depth)
    {
        skip();
        if (pos_ == s_.size()) fail(pos_, "ends where an operand is expected");
        const char c = s_[pos_];
        if (c == '(') {
            if (depth + 1 > Expression::MAX_DEPTH)
                fail(pos_, "is nested deeper than " + std::to_string(Expression::MAX_DEPTH) + " parentheses");
            ++pos_;
            const int inner = parse_or(depth + 1);
            skip();
            if (pos_ == s_.size() || s_[pos_] != ')') fail(pos_, "misses a ')'");
            ++pos_;
            return inner;
        }
        std::string name;
        const size_t start = pos_;
        if (c == '"') {
            ++pos_;
            for (;;) {
                if (pos_ == s_.size()) fail(start, "has an unterminated quoted name");
                if (s_[pos_] == '"') {
                    if (pos_ + 1 < s_.size() && s_[pos_ + 1] == '"') {
                        name += '"';
                        pos_ += 2;
                        continue;
                    }
                    ++pos_;
                    break;
                }
                if (s_[pos_] == '\0') fail(pos_, "contains a NUL character");
                name += s_[pos_++];
            }
            if (name.empty()) fail(start, "has an empty quoted name");
        } else if (is_bare_name_char(c)) {
            while (pos_ < s_.size() && is_bare_name_char(s_[pos_])) name += s_[pos_++];
        } else {
            fail(pos_, std::string("has an unexpected '") + c + "' where an operand is expected");
        }
        if (name.size() > Expression::MAX_NAME_LENGTH)
            fail(start, "has a name longer than " + std::to_string(Expression::MAX_NAME_LENGTH) + " characters");
        auto it = slots_.find(name);
        int slot;
        if (it == slots_.end()) {
            if (e_.names_.size() >= Expression::MAX_NAMES)
                fail(start, "has more than " + std::to_string(Expression::MAX_NAMES) + " distinct names");
            slot = static_cast<int>(e_.names_.size());
            e_.names_.push_back(name);
            slots_.emplace(name, slot);
        } else {
            slot = it->second;
        }
        return add(Expression::Kind::Name, -1, -1, slot);
    }
};

Expression Expression::parse(const std::string &text)
{
    Expression e;
    ExprParser(text, e).run();
    e.finish();
    return e;
}

int Expression::slot_of(const std::string &name) const
{
    for (size_t i = 0; i < names_.size(); ++i)
        if (names_[i] == name) return static_cast<int>(i);
    return -1;
}

// Postfix program, stack depth, required slots.
void Expression::finish()
{
    program_.clear();
    std::vector<std::vector<int>> req(nodes_.size());
    std::vector<int> depth(nodes_.size(), 0);
    // Children are always created before their parent, so index order is a valid bottom-up order.
    for (size_t i = 0; i < nodes_.size(); ++i) {
        const Node &n = nodes_[i];
        if (n.kind == Kind::Name) {
            req[i] = {n.slot};
            depth[i] = 1;
            continue;
        }
        const auto &a = req[static_cast<size_t>(n.left)];
        const auto &b = req[static_cast<size_t>(n.right)];
        std::vector<int> r;
        if (n.kind == Kind::And) {
            std::set_union(a.begin(), a.end(), b.begin(), b.end(), std::back_inserter(r));
        } else if (n.kind == Kind::AndNot) {
            r = a;
        } else {   // Or, Xor: empty only if both sides are empty
            std::set_intersection(a.begin(), a.end(), b.begin(), b.end(), std::back_inserter(r));
        }
        req[i] = std::move(r);
        // Evaluating the left side leaves one value on the stack while the right side runs.
        depth[i] = std::max(depth[static_cast<size_t>(n.left)], 1 + depth[static_cast<size_t>(n.right)]);
    }
    // Postfix order of the nodes reachable from the root (iterative, no recursion).
    std::vector<std::pair<int, bool>> todo = {{root_, false}};
    while (!todo.empty()) {
        auto [node, expanded] = todo.back();
        todo.pop_back();
        const Node &n = nodes_[static_cast<size_t>(node)];
        if (n.kind == Kind::Name || expanded) {
            program_.push_back(node);
        } else {
            todo.push_back({node, true});
            todo.push_back({n.right, false});
            todo.push_back({n.left, false});
        }
    }
    required_ = req[static_cast<size_t>(root_)];
    stack_depth_ = depth[static_cast<size_t>(root_)];
}

bool Expression::can_be_nonempty(const std::vector<bool> &present) const
{
    for (int s : required_)
        if (!present[static_cast<size_t>(s)]) return false;
    return true;
}

void Expression::evaluate(const std::vector<const Bitmap *> &operands, int chunk_bits, Bitmap &out) const
{
    if (operands.size() != names_.size()) throw std::logic_error("evaluate: wrong number of operands");
    if (stack_.size() < static_cast<size_t>(stack_depth_)) stack_.resize(static_cast<size_t>(stack_depth_), Bitmap(chunk_bits));
    size_t top = 0;
    for (int idx : program_) {
        const Node &n = nodes_[static_cast<size_t>(idx)];
        if (n.kind == Kind::Name) {
            Bitmap &dst = stack_[top++];
            const Bitmap *src = operands[static_cast<size_t>(n.slot)];
            if (dst.chunk_bits() != chunk_bits) dst.reset(chunk_bits);
            if (src == nullptr) {
                dst.clear();
            } else {
                if (src->chunk_bits() != chunk_bits)
                    throw UsageError("operand '" + names_[static_cast<size_t>(n.slot)] + "' has chunks of " +
                                     std::to_string(src->chunk_bits()) + " bits, expected " + std::to_string(chunk_bits));
                std::memcpy(dst.words(), src->words(), dst.word_count() * sizeof(uint64_t));
            }
            continue;
        }
        Bitmap &a = stack_[top - 2];
        const Bitmap &b = stack_[top - 1];
        switch (n.kind) {
        case Kind::And: a.and_with(b); break;
        case Kind::Or: a.or_with(b); break;
        case Kind::Xor: a.xor_with(b); break;
        case Kind::AndNot: a.andnot_with(b); break;
        case Kind::Name: break;
        }
        --top;
    }
    if (out.chunk_bits() != chunk_bits) out.reset(chunk_bits);
    std::memcpy(out.words(), stack_[0].words(), out.word_count() * sizeof(uint64_t));
}

// Copies the subtree of src at node into *this without operands starting with prefix.
// Returns the new node, or -1 if the whole subtree was removed.
int Expression::copy_without(const Expression &src, int node, const std::string &prefix)
{
    const Node &n = src.nodes_[static_cast<size_t>(node)];
    if (n.kind == Kind::Name) {
        const std::string &name = src.names_[static_cast<size_t>(n.slot)];
        if (name.compare(0, prefix.size(), prefix) == 0) return -1;
        int slot = slot_of(name);
        if (slot < 0) {
            slot = static_cast<int>(names_.size());
            names_.push_back(name);
        }
        nodes_.push_back({Kind::Name, -1, -1, slot});
        return static_cast<int>(nodes_.size()) - 1;
    }
    const int l = copy_without(src, n.left, prefix);
    const int r = copy_without(src, n.right, prefix);
    if (l < 0 && r < 0) return -1;
    if (r < 0) return l;                                // A op removed = A
    if (l < 0) return n.kind == Kind::AndNot ? -1 : r;  // removed - B = removed; removed op B = B
    nodes_.push_back({n.kind, l, r, -1});
    return static_cast<int>(nodes_.size()) - 1;
}

Expression Expression::without_prefix(const std::string &prefix) const
{
    if (prefix.empty()) return *this;
    Expression e;
    e.root_ = e.copy_without(*this, root_, prefix);
    if (e.root_ < 0) throw UsageError("expression has no operand left after excluding '" + prefix + "'");
    e.finish();
    return e;
}

std::string Expression::render_node(int node, const std::function<std::string(const std::string &)> &leaf,
                                    const std::function<std::string(char, const std::string &, const std::string &)> &binary) const
{
    const Node &n = nodes_[static_cast<size_t>(node)];
    if (n.kind == Kind::Name) return leaf(names_[static_cast<size_t>(n.slot)]);
    const char op = n.kind == Kind::And ? '&' : n.kind == Kind::Or ? '|' : n.kind == Kind::Xor ? '^' : '-';
    return binary(op, render_node(n.left, leaf, binary), render_node(n.right, leaf, binary));
}

std::string Expression::render(const std::function<std::string(const std::string &)> &leaf,
                               const std::function<std::string(char, const std::string &, const std::string &)> &binary) const
{
    return render_node(root_, leaf, binary);
}

std::string Expression::to_string() const
{
    return render(
        [](const std::string &name) {
            if (std::all_of(name.begin(), name.end(), is_bare_name_char)) return name;
            std::string q = "\"";
            for (char c : name) q += (c == '"') ? std::string("\"\"") : std::string(1, c);
            return q + "\"";
        },
        [](char op, const std::string &l, const std::string &r) { return "(" + l + " " + op + " " + r + ")"; });
}

}  // namespace vbitmap
