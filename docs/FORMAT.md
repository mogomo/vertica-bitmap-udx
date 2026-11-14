# Payload format, version 1 (frozen)

A payload is the set of entities of one chunk that satisfy one predicate. It is stored in a
`VARBINARY` column and is produced and checked only by the vbitmap engine (`src/engine`).

## Entity IDs and chunks

Entity IDs are nonnegative 64-bit integers, stable per tenant and domain. With `b` chunk bits
(16 by default, 8 to 18 allowed):

```
chunk_id = id >> b          local_id = id & (2^b - 1)          id = (chunk_id << b) | local_id
```

A chunk holds the local IDs `0 .. 2^b - 1`. ID 2^32 is chunk 65,536, local 0: it never collides with ID 0.

## Layout

All integers are little-endian. A 16-byte header, then the body.

| Offset | Bytes | Field | Rule |
|---:|---:|---|---|
| 0 | 4 | Magic | `VBM1` (0x56 0x42 0x4D 0x31) |
| 4 | 1 | Format version | 1 |
| 5 | 1 | Codec | 0 empty, 1 Roaring, 2 raw bitset |
| 6 | 1 | Chunk bits `b` | 8 to 18 |
| 7 | 1 | Reserved | 0 |
| 8 | 4 | Cardinality | number of local IDs in the set |
| 12 | 4 | Checksum | CRC-32C (Castagnoli) of bytes 0 to 11, followed by the body |

The checksum covers the header fields as well as the body, so that a damaged cardinality is
detected by the cheap check that reads only the header (`inspect`).

### Body by codec

| Codec | Body | Size |
|---|---|---|
| 0 empty | none | 0; cardinality 0 |
| 1 Roaring | the portable Roaring serialization (the format shared by CRoaring, Java and Go), values are local IDs | 1 to `2^b / 8 - 1` bytes; cardinality 1 to `2^b` |
| 2 raw bitset | `2^b` bits; local ID `i` is bit `i % 64` of the little-endian 64-bit word `i / 64` | exactly `2^b / 8` bytes (8,192 for b = 16, 32,768 for b = 18); cardinality 1 to `2^b` |

## Canonical form (writer)

- The empty set is the header alone, codec 0.
- Otherwise the writer builds the Roaring form with run containers where they are smaller
  (`run_optimize`) and keeps it only if its body is strictly smaller than the raw bitset;
  otherwise it writes the raw bitset.
- The same set therefore always gives the same bytes, and the largest payload is
  `16 + 2^b / 8` bytes: 8,208 for b = 16 (column `VARBINARY(16384)` leaves room), 32,784 for
  b = 18 (below the 65,000-byte limit of `VARBINARY`).

## Reader checks

A payload that fails any check raises an error. It is never read as an empty set.

1. At least 16 bytes; magic; version 1; codec 0, 1 or 2; chunk bits 8 to 18; reserved byte 0.
2. Length and cardinality consistent with the codec (table above); a Roaring body must be
   smaller than the raw body.
3. Checksum.
4. Full decode only:
   - raw: the population count equals the cardinality;
   - Roaring: the serialization is complete with no trailing bytes, deserializes with the
     bounded reader, passes CRoaring's internal validation, has the stated cardinality and no
     value at or above `2^b`.

`inspect` (used where only the header is needed, such as the cardinality) runs checks 1 to 3.
`decode` runs all four.

## Compatibility

- Version 1 is frozen. Any change of layout or rules gets a new version byte, and readers keep
  accepting version 1.
- Payloads from chunks of different widths are never combined; the engine raises an error.
- The engine assumes a little-endian CPU (x86-64 and ARM64 in practice), checked at compile time.

## Third-party code

The Roaring serialization is read and written by CRoaring 5.5.5 (vendored in
`third_party/croaring`, Apache-2.0 / MIT, checksums in `VERSION.md`).
