#!/bin/sh
# Line coverage of Sources/LoomCore under the simulations alone, with the functions at 0%.
# The unit tests of the other targets are excluded on purpose: the figure answers what the
# simulation reaches, which is what the audit's target (85%) was about.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$root" --enable-code-coverage --filter 'LoomCoreTests.*ModelTests' > /dev/null 2>&1
out="$(swift build --package-path "$root" --show-bin-path)"
exe="$out/LoomCoreTests.xctest/Contents/MacOS/LoomCoreTests"
profdata="$out/codecov/default.profdata"
xcrun llvm-cov report "$exe" -instr-profile="$profdata" "$root"/Sources/LoomCore/*.swift "$root/Sources/LoomKit/ControlLane.swift"
echo
echo "Functions at 0%:"
xcrun llvm-cov report "$exe" -instr-profile="$profdata" -show-functions "$root"/Sources/LoomCore/*.swift "$root/Sources/LoomKit/ControlLane.swift" 2>/dev/null | awk '$2 ~ /^[0-9]+$/ && $3 == 0 {print "  " $1}' | xcrun swift-demangle --simplified | head -40
