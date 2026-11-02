# Loom Desktop

A native SwiftUI client and mission control for [`loomd`](https://github.com/roasbeef/loom),
including sessions whose brain, hands and subagents run on different machines. It
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

`LOOM_STATE_DIR` points the binary at another daemon's state root, and the Machines
page connects daemons on other machines.

## Test it

```bash
swift test
```
