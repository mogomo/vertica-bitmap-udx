// Block-wise access to the rows the SDK hands to a function.
//
// The SDK's row cursors (BlockReader::next, BlockWriter::next, PartitionWriter::next) re-derive
// and validate every column on each call. For hot loops over plain columns that costs several
// times the work itself: a membership test of 10 million IDs spends most of its time in next().
// The functions below step the cursor directly when the block is a plain array of rows, and tell
// the caller to use the SDK cursor otherwise (skip-list blocks, blocks with a reverse data area).
//
// The cursor fields are protected members of VerticaBlock; they are read through pointers to
// members, which C++ allows for a derived class. Nothing is assumed about the block layout beyond
// what the SDK's own next() does with the same fields.
#pragma once

#include "Vertica.h"

namespace vbitmap_udx {

struct BlockCursor : public Vertica::VerticaBlock {
    // Rows from the cursor to the end of the block if the block has no skip list, else -1.
    static int dense_rows(const Vertica::VerticaBlock &b)
    {
        if (b.*(&BlockCursor::indices) != nullptr) return -1;
        return b.*(&BlockCursor::count) - b.*(&BlockCursor::index);
    }

    // Marks every row of the block as read (input) or written (output).
    static void finish(Vertica::VerticaBlock &b) { b.*(&BlockCursor::index) = b.*(&BlockCursor::count); }

    // After one output row was written: moves to the next row of the same block. Returns false
    // when the caller must call next() instead (last row of the block, or a block this shortcut
    // does not cover). Skips the per-row validation of next(): the caller writes valid values.
    static bool step(Vertica::VerticaBlock &b)
    {
        int &i = b.*(&BlockCursor::index);
        if (i + 1 >= b.*(&BlockCursor::count) || b.*(&BlockCursor::indices) != nullptr) return false;
        const EE::DataArea *d = b.*(&BlockCursor::da);
        if (d != nullptr && d->isReverseDA()) return false;
        std::vector<char *> &c = b.*(&BlockCursor::cols);
        const std::vector<int> &s = b.*(&BlockCursor::colstrides);
        ++i;
        for (size_t k = 0; k < c.size(); ++k)
            if (c[k]) c[k] += s[k];
        return true;
    }
};

}  // namespace vbitmap_udx
