# Bssist

Minimalist native macOS 13+ Bilibili video downloader built with SwiftUI.

## Features
- **Monochrome Shadowrocket-style UI**: Grouped inset cards, minimal text, zero visual clutter.
- **Up to 8K / Dolby Vision / HDR / 4K / 1080P60**: WBI-signed stream resolution with in-app QR code login and `SESSDATA` support.
- **Multi-Connection Parallel Range Engine**: 10-way concurrent HTTP `Range` slicing with multi-CDN mirror striping (`upos-*` prioritized) and lock-free POSIX `pwrite`.
- **Pause & Checkpoint Resume**: Segment-level checkpointing (`2 MB` slices) for instant pause and resume without losing progress.
- **Zero External Dependencies**: Lossless native `AVFoundation` fMP4 muxing (including `hev1` to `hvc1` header patching for 4K/8K HEVC streams).

## Build

```bash
./build_app.sh
open Bssist.app
```
