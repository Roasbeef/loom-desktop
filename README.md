# Loom Desktop

A native SwiftUI client and mission control for [`loomd`](https://github.com/roasbeef/loom),
with optional [Substrate](https://github.com/roasbeef/substrate) integration. It
uses the same daemon as the terminal client and changes nothing about it.

This is an early exploration. [docs/design.md](docs/design.md) has the
architecture, the packaging plan and the known gaps.

## Run it

You need macOS 14 or later, a Swift 6 toolchain and a running `loomd`. The app
reads `~/.loom`.

```bash
CONFIG=debug scripts/bundle.sh
```

```bash
open build/Loom.app
```

Substrate appears when a current `substrated` serves `localhost:8080`.
`SUBSTRATE_URL` and `LOOM_STATE_DIR` point the binary at other instances.

## Test it

```bash
swift test
```
