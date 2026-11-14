# CRoaring (vendored)

| Item | Value |
|---|---|
| Project | https://github.com/RoaringBitmap/CRoaring |
| Release | v5.5.5 (2026-11-04), single-file amalgamation from the release assets |
| License | dual Apache-2.0 / MIT (see LICENSE); used here under the MIT license |
| roaring.c SHA-256 | 190216f349ac5aad430b58ed9b9d5b1966a2462a14ce045b0ca59d8507a9cee8 |
| roaring.h SHA-256 | 1a336307c3b5a732045941d1bd33232aa4b45661366ac9643c583e6d67513a34 |

The files are unchanged. Release v5.5.0 fixed bitset_container_maximum skipping word 0, which the
payload validation relies on; this is why a release from November 2026 is pinned.
Compiled as C11 without -march flags: the library selects its AVX2 / AVX-512 kernels at run time,
so one binary runs on every x86-64 node.

To check: `shasum -a 256 roaring.c roaring.h` (macOS) or `sha256sum roaring.c roaring.h` (Linux).
