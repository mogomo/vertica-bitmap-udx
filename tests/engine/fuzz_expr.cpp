// libFuzzer target for the expression parser (make fuzz FUZZ_TARGET=fuzz_expr). Any input either
// raises UsageError or parses; a parsed expression must print to a canonical text that parses
// to the same canonical text, and must evaluate without fault on small sets.
#include "expr.h"

#include <cstdlib>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    const std::string text(reinterpret_cast<const char *>(data), size);
    vbitmap::Expression e;
    try {
        e = vbitmap::Expression::parse(text);
    } catch (const vbitmap::UsageError &) {
        return 0;
    }
    const std::string canon = e.to_string();
    if (vbitmap::Expression::parse(canon).to_string() != canon) std::abort();

    static vbitmap::Bitmap a(8), b(8), out(8);
    a.clear();
    b.clear();
    for (uint32_t i = 0; i < 256; i += 3) a.add(i);
    for (uint32_t i = 0; i < 256; i += 5) b.add(i);
    std::vector<const vbitmap::Bitmap *> ops(e.names().size());
    std::vector<bool> present(e.names().size());
    for (size_t i = 0; i < ops.size(); ++i) {
        ops[i] = (i % 3 == 2) ? nullptr : (i % 2 ? &a : &b);
        present[i] = ops[i] != nullptr;
    }
    e.evaluate(ops, 8, out);
    if (!e.can_be_nonempty(present) && !out.empty()) std::abort();
    if (data[0] == 't') {
        try {
            const vbitmap::Expression w = e.without_prefix("t");
            if (vbitmap::Expression::parse(w.to_string()).to_string() != w.to_string()) std::abort();
        } catch (const vbitmap::UsageError &) {
        }
    }
    return 0;
}
