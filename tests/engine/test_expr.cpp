// Expression parser and evaluator: grammar, precedence, errors, limits, exclusion, and
// evaluation of random expressions against a reference implementation.
#include "test_util.h"

#include "expr.h"

#include <algorithm>
#include <iterator>
#include <memory>

using test::RefSet;
using vbitmap::Bitmap;
using vbitmap::Expression;
using vbitmap::UsageError;

static std::string canon(const std::string &text) { return Expression::parse(text).to_string(); }

static bool error_contains(const std::string &text, const std::string &part)
{
    try {
        Expression::parse(text);
    } catch (const UsageError &e) {
        if (std::string(e.what()).find(part) != std::string::npos) return true;
        std::fprintf(stderr, "error for [%.60s]: %s\n", text.c_str(), e.what());
        return false;
    }
    std::fprintf(stderr, "no error for [%.60s]\n", text.c_str());
    return false;
}

static void grammar()
{
    CHECK(canon("a") == "a");
    CHECK(canon("  a&b ") == "(a & b)");
    CHECK(canon("a | b & c") == "(a | (b & c))");          // & binds tighter than |
    CHECK(canon("a - b & c") == "(a - (b & c))");          // & binds tighter than -
    CHECK(canon("a ^ b - c") == "(a ^ (b - c))");          // - binds tighter than ^
    CHECK(canon("a | b ^ c") == "(a | (b ^ c))");          // ^ binds tighter than |
    CHECK(canon("a - b - c") == "(a - (b | c))");          // (a - b) - c
    CHECK(canon("(a | b) & c") == "((a | b) & c)");
    CHECK(canon("a & b & c & d") == "((a & b) & (c & d))");   // balanced
    CHECK(canon("country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)") ==
          "((country_IL & age_25_54) & (consent_true & (suspended_false & (topic_sports | topic_finance))))");
    CHECK(canon("\"topic_rock & roll\" | x.y:z#1") == "(\"topic_rock & roll\" | x.y:z#1)");
    CHECK(canon("\"say \"\"hi\"\"\"") == "\"say \"\"hi\"\"\"");
    CHECK(canon("\"plain\"") == "plain");
    const Expression e = Expression::parse("b & a | b - c");
    CHECK(e.names().size() == 3 && e.names()[0] == "b" && e.names()[1] == "a" && e.names()[2] == "c");
    CHECK(e.slot_of("a") == 1 && e.slot_of("zz") == -1);
    // round trip of the canonical text
    for (const char *t : {"a|b&c-d^e", "((a))", "a-b-c-d", "\"x y\" & (\"p\"\"q\" | r)"})
        CHECK(canon(canon(t)) == canon(t));
}

static void errors()
{
    CHECK(error_contains("", "is empty"));
    CHECK(error_contains("   ", "is empty"));
    CHECK(error_contains("a &", "ends where an operand is expected"));
    CHECK(error_contains("a & & b", "unexpected '&'"));
    CHECK(error_contains("(a | b", "misses a ')'"));
    CHECK(error_contains("a | b)", "unexpected ')' at position 6"));
    CHECK(error_contains("NOT a", "unexpected 'a'"));
    CHECK(error_contains("!a", "unexpected '!'"));
    CHECK(error_contains("a b", "unexpected 'b'"));
    CHECK(error_contains("\"open", "unterminated quoted name"));
    CHECK(error_contains("\"\"", "empty quoted name"));
    CHECK(error_contains(std::string(81, 'n'), "longer than 80"));
    CHECK(canon(std::string(80, 'n')) == std::string(80, 'n'));
    // length: 64,999 accepted, 65,000 rejected (the parameter may have been cut)
    std::string ok = "a" + std::string(Expression::MAX_LENGTH - 1, ' ');
    CHECK(Expression::parse(ok).to_string() == "a");
    CHECK(error_contains(ok + " ", "limit is 64999"));
    // nesting: 200 parentheses accepted, 201 rejected
    CHECK(canon(std::string(200, '(') + "a" + std::string(200, ')')) == "a");
    CHECK(error_contains(std::string(201, '(') + "a" + std::string(201, ')'), "deeper than 200"));
    // a long chain is fine (balanced tree)
    std::string chain = "t0";
    for (int i = 1; i < 4000; ++i) chain += " | t" + std::to_string(i);
    CHECK(Expression::parse(chain).names().size() == 4000);
    std::string many = "t0";
    for (size_t i = 1; i <= Expression::MAX_NAMES; ++i) many += "|t" + std::to_string(i);
    CHECK(error_contains(many, "more than 4096 distinct names"));
}

static void exclusion()
{
    const Expression q = Expression::parse("country_IL & age_25_54 & (topic_sports | topic_finance)");
    CHECK(q.without_prefix("topic_").to_string() == "(country_IL & age_25_54)");
    CHECK(q.without_prefix("").to_string() == q.to_string());
    CHECK(q.without_prefix("zzz").to_string() == q.to_string());
    CHECK(Expression::parse("a - topic_x").without_prefix("topic_").to_string() == "a");
    CHECK(Expression::parse("(topic_a | b) & c").without_prefix("topic_").to_string() == "(b & c)");
    CHECK(Expression::parse("topic_a - b | c").without_prefix("topic_").to_string() == "c");
    bool thrown = false;
    try {
        Expression::parse("topic_a | topic_b").without_prefix("topic_");
    } catch (const UsageError &) {
        thrown = true;
    }
    CHECK(thrown);
    const Expression w = q.without_prefix("topic_");
    CHECK(w.names().size() == 2 && w.slot_of("topic_sports") == -1);
}

// ---- random expressions against the reference ---------------------------------------------

struct RNode {
    char op;   // 0 for a name
    int name;
    std::unique_ptr<RNode> l, r;
};

static std::unique_ptr<RNode> random_tree(int depth, int nnames)
{
    auto n = std::make_unique<RNode>();
    std::uniform_int_distribution<int> pick(0, 9), name(0, nnames - 1), op(0, 3);
    if (depth == 0 || pick(test::rng()) < 3) {
        n->op = 0;
        n->name = name(test::rng());
        return n;
    }
    n->op = "&|^-"[op(test::rng())];
    n->l = random_tree(depth - 1, nnames);
    n->r = random_tree(depth - 1, nnames);
    return n;
}

static std::string tree_text(const RNode &n)
{
    if (!n.op) return "p" + std::to_string(n.name);
    return "(" + tree_text(*n.l) + " " + n.op + " " + tree_text(*n.r) + ")";
}

static RefSet tree_eval(const RNode &n, const std::vector<const RefSet *> &sets)
{
    if (!n.op) return sets[static_cast<size_t>(n.name)] ? *sets[static_cast<size_t>(n.name)] : RefSet{};
    const RefSet a = tree_eval(*n.l, sets), b = tree_eval(*n.r, sets);
    RefSet r;
    switch (n.op) {
    case '&': std::set_intersection(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end())); break;
    case '|': std::set_union(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end())); break;
    case '^': std::set_symmetric_difference(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end())); break;
    default: std::set_difference(a.begin(), a.end(), b.begin(), b.end(), std::inserter(r, r.end())); break;
    }
    return r;
}

static void evaluation()
{
    const int cb = 12, nnames = 6;
    std::vector<RefSet> pool;
    for (int i = 0; i < nnames; ++i) pool.push_back(i % 2 ? test::random_ref(cb, 0.3) : test::random_runs(cb, 5, 300));
    std::vector<Bitmap> bitmaps;
    for (const RefSet &s : pool) bitmaps.push_back(test::to_bitmap(s, cb));
    std::bernoulli_distribution present(0.8);
    int skipped = 0, nonempty = 0;
    for (int round = 0; round < 3000; ++round) {
        const auto tree = random_tree(5, nnames);
        const Expression e = Expression::parse(tree_text(*tree));
        // operands: by the expression's slot order; some names have no payload in this chunk
        std::vector<const RefSet *> ref_sets(nnames, nullptr);
        std::vector<const Bitmap *> ops(e.names().size(), nullptr);
        std::vector<bool> is_present(e.names().size(), false);
        for (size_t s = 0; s < e.names().size(); ++s) {
            const int idx = std::stoi(e.names()[s].substr(1));
            if (present(test::rng())) {
                ref_sets[static_cast<size_t>(idx)] = &pool[static_cast<size_t>(idx)];
                ops[s] = &bitmaps[static_cast<size_t>(idx)];
                is_present[s] = true;
            }
        }
        const RefSet want = tree_eval(*tree, ref_sets);
        if (!e.can_be_nonempty(is_present)) {
            ++skipped;
            CHECK(want.empty());   // skipping must never lose a member
            continue;
        }
        Bitmap out(cb);
        e.evaluate(ops, cb, out);
        CHECK(test::to_ref(out) == want);
        if (!want.empty()) ++nonempty;
        // canonical text evaluates the same
        Bitmap again(cb);
        Expression::parse(e.to_string()).evaluate(ops, cb, again);
        CHECK(again == out);
    }
    CHECK(skipped > 100 && nonempty > 1000);   // both paths exercised
    // operand of the wrong width
    Bitmap wide(16);
    const Expression e = Expression::parse("p0 & p1");
    std::vector<const Bitmap *> ops = {&bitmaps[0], &wide};
    Bitmap out(cb);
    CHECK_THROWS(UsageError, e.evaluate(ops, cb, out));
}

int main()
{
    grammar();
    errors();
    exclusion();
    evaluation();
    return test::finish("test_expr");
}
