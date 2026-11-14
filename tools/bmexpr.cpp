// bmexpr: the expression parser of the engine on the command line (used by scripts/bmq).
//
//   bmexpr names EXPR             operand names, one per line, in order of first appearance
//   bmexpr canon EXPR             canonical text
//   bmexpr sql EXPR TEMPLATE      native SQL for the set of IDs: every name N becomes TEMPLATE with
//                                 {name} replaced by the SQL string literal of N; & | - ^ become
//                                 INTERSECT, UNION, EXCEPT and a symmetric difference.
//                                 TEMPLATE must select one column named entity_id.
//
// Exit status 1 and the message on stderr for an invalid expression.
#include "expr.h"

#include <cstdio>
#include <iostream>

static std::string sql_literal(const std::string &s)
{
    std::string q = "'";
    for (char c : s) q += (c == '\'') ? std::string("''") : std::string(1, c);
    return q + "'";
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: bmexpr names|canon EXPR | bmexpr sql EXPR TEMPLATE\n");
        return 2;
    }
    const std::string cmd = argv[1];
    try {
        const vbitmap::Expression e = vbitmap::Expression::parse(argv[2]);
        if (cmd == "names") {
            for (const std::string &n : e.names()) std::cout << n << '\n';
        } else if (cmd == "canon") {
            std::cout << e.to_string() << '\n';
        } else if (cmd == "sql" && argc == 4) {
            const std::string tmpl = argv[3];
            int alias = 0;
            const std::string sql = e.render(
                [&](const std::string &name) {
                    std::string t = tmpl;
                    const std::string lit = sql_literal(name);
                    for (size_t p = t.find("{name}"); p != std::string::npos; p = t.find("{name}", p + lit.size()))
                        t.replace(p, 6, lit);
                    return "SELECT entity_id FROM (" + t + ") n" + std::to_string(alias++);
                },
                [&](char op, const std::string &l, const std::string &r) {
                    const std::string a = "s" + std::to_string(alias++);
                    if (op == '^')
                        return "SELECT entity_id FROM (((" + l + ") EXCEPT (" + r + ")) UNION ((" + r + ") EXCEPT (" + l + "))) " + a;
                    const char *kw = op == '&' ? "INTERSECT" : op == '|' ? "UNION" : "EXCEPT";
                    return "SELECT entity_id FROM ((" + l + ") " + kw + " (" + r + ")) " + a;
                });
            std::cout << sql << '\n';
        } else {
            std::fprintf(stderr, "bmexpr: unknown command or wrong arguments\n");
            return 2;
        }
    } catch (const std::exception &ex) {
        std::fprintf(stderr, "%s\n", ex.what());
        return 1;
    }
    return 0;
}
