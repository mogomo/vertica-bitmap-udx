// Shared helpers of the vbitmap UDx layer: payload widths, reading and writing payloads,
// error reporting. Every SQL-facing function catches engine exceptions and reports them
// through vt_report_error, so that no exception crosses the SDK boundary.
#pragma once

#include "Vertica.h"
#include "vbitmap.h"

#include <string>
#include <vector>

namespace vbitmap_udx {

using namespace Vertica;

// Declared width of payload columns: VARBINARY(16384) up to 16 chunk bits (largest payload 8,208
// bytes), VARBINARY(65000) above (largest payload 32,784 bytes at 18 bits).
inline constexpr int32 NARROW_WIDTH = 16384;
inline constexpr int32 WIDE_WIDTH = 65000;

inline int32 width_for_chunk_bits(int chunk_bits) { return chunk_bits <= 16 ? NARROW_WIDTH : WIDE_WIDTH; }

// Output width for a function whose payload arguments have the given declared widths.
inline int32 width_for_inputs(const SizedColumnTypes &types)
{
    int32 w = NARROW_WIDTH;
    for (size_t i = 0; i < types.getColumnCount(); ++i) {
        const VerticaType &t = types.getColumnType(i);
        if ((t.isVarbinary() || t.isBinary()) && t.getStringLength() > NARROW_WIDTH) w = WIDE_WIDTH;
    }
    return w;
}

inline int chunk_bits_param(ServerInterface &srv)
{
    ParamReader p = srv.getParamReader();
    const int cb = p.containsParameter("chunk_bits") ? static_cast<int>(p.getIntRef("chunk_bits"))
                                                     : vbitmap::DEFAULT_CHUNK_BITS;
    vbitmap::check_chunk_bits(cb);
    return cb;
}

inline void decode(vbitmap::PayloadCodec &codec, const VString &v, vbitmap::Bitmap &out)
{
    codec.decode(v.data(), static_cast<size_t>(v.length()), out);
}

// Writes an encoded payload into a VARBINARY output, checking it fits the declared width.
inline void put_payload(VString &dst, const std::vector<uint8_t> &p, int32 max_width)
{
    if (p.size() > static_cast<size_t>(max_width))
        throw vbitmap::UsageError("payload of " + std::to_string(p.size()) + " bytes exceeds the output width " +
                                  std::to_string(max_width) +
                                  "; store chunks wider than 16 bits in VARBINARY(65000) columns");
    dst.copy(reinterpret_cast<const char *>(p.data()), static_cast<vsize>(p.size()));
}

#define VBITMAP_TRY try {
#define VBITMAP_CATCH(fn)                                                  \
    }                                                                      \
    catch (const vbitmap::FormatError &e) {                                \
        vt_report_error(1, "%s: %s", fn, e.what());                        \
    }                                                                      \
    catch (const vbitmap::UsageError &e) {                                 \
        vt_report_error(2, "%s: %s", fn, e.what());                        \
    }                                                                      \
    catch (const std::bad_alloc &) {                                       \
        vt_report_error(3, "%s: out of memory", fn);                       \
    }                                                                      \
    catch (const std::exception &e) {                                      \
        vt_report_error(4, "%s: %s", fn, e.what());                        \
    }

// Checks every 2^16 rows whether the query was cancelled.
#define VBITMAP_CANCEL_POINT(counter)                         \
    if ((++(counter) & 0xFFFF) == 0 && isCanceled()) return;

}  // namespace vbitmap_udx
