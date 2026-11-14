// Boolean set expressions over named predicates, evaluated one chunk at a time.
//
// Grammar (whitespace is ignored):
//     expr    := xor ( '|' xor )*          union                      lowest precedence
//     xor     := diff ( '^' diff )*        symmetric difference
//     diff    := and ( '-' and )*          difference (ANDNOT), left-associative
//     and     := primary ( '&' primary )*  intersection               highest precedence
//     primary := NAME | QUOTED | '(' expr ')'
//     NAME    := one or more of  A-Z a-z 0-9 _ . : #
//     QUOTED  := '"' any characters, "" for a quote '"'
// There is no unary NOT: a complement must name its universe (all - suspended_true), so that
// unknown (NULL) attributes are never counted by accident.
//
// Chains of &, | and ^ are built as balanced trees; a - b - c is evaluated as a - (b | c).
//
// A name that has no payload in a chunk is the empty set there. If a name that the result
// cannot do without (a "required" name, e.g. any operand of a top-level &) is missing, the
// chunk is skipped without decoding anything.
#pragma once

#include "vbitmap.h"

#include <functional>
#include <string>
#include <vector>

namespace vbitmap {

class Expression {
public:
    // A VARCHAR(65000) UDx parameter holds at most 65,000 characters, so an expression of exactly
    // that length may be incomplete: the longest accepted expression has 64,999 characters.
    static constexpr size_t MAX_LENGTH = 64999;
    static constexpr int MAX_DEPTH = 200;          // nesting of parentheses
    static constexpr size_t MAX_NAMES = 4096;
    static constexpr size_t MAX_NAME_LENGTH = 80;  // predicate column is VARCHAR(80)

    // UsageError with the position of the problem if the text is not a valid expression.
    static Expression parse(const std::string &text);

    // Distinct operand names, in order of first appearance. Slot i is names()[i].
    const std::vector<std::string> &names() const { return names_; }
    int slot_of(const std::string &name) const;   // -1 if not an operand

    // False if a required name is missing: the result is empty without evaluation.
    bool can_be_nonempty(const std::vector<bool> &present) const;

    // out = value of the expression; operands[i] is the set of names()[i], or nullptr when the
    // chunk has no payload for it (empty set). Every non-null operand must have chunk_bits.
    void evaluate(const std::vector<const Bitmap *> &operands, int chunk_bits, Bitmap &out) const;

    // The expression with every operand whose name starts with prefix removed (for disjunctive
    // facets): A op removed = A, removed - B = removed. UsageError if nothing is left.
    Expression without_prefix(const std::string &prefix) const;

    // Canonical text: binary operations fully parenthesized, names quoted only when needed.
    std::string to_string() const;

    // Generic rendering: leaf(name) for every operand, binary(op, left, right) for every
    // operation, op one of '&', '|', '^', '-'. Used for the canonical text and for SQL.
    std::string render(const std::function<std::string(const std::string &)> &leaf,
                       const std::function<std::string(char, const std::string &, const std::string &)> &binary) const;

private:
    enum class Kind { Name, And, Or, Xor, AndNot };
    struct Node {
        Kind kind;
        int left, right;   // child nodes (binary)
        int slot;          // operand (Name)
    };
    std::vector<Node> nodes_;
    int root_ = -1;
    std::vector<std::string> names_;
    std::vector<int> required_;   // slots the result cannot do without
    std::vector<int> program_;    // postfix order of nodes
    int stack_depth_ = 0;

    friend class ExprParser;
    void finish();
    int copy_without(const Expression &src, int node, const std::string &prefix);
    std::string render_node(int node, const std::function<std::string(const std::string &)> &leaf,
                            const std::function<std::string(char, const std::string &, const std::string &)> &binary) const;
    mutable std::vector<Bitmap> stack_;
};

// Bare names may contain these characters; other names need quotes.
bool is_bare_name_char(char c);

}  // namespace vbitmap
