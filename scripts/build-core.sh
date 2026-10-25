#!/usr/bin/env bash
# Builds the Rust core as a universal (arm64 + x86_64) static library and
# packages it, with its C header and Swift module map, as an XCFramework.
set -euo pipefail
cd "$(dirname "$0")/../core"

export MACOSX_DEPLOYMENT_TARGET=13.0
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
rustup target add "${TARGETS[@]}" >/dev/null
for t in "${TARGETS[@]}"; do
    cargo build --release --target "$t"
done

rm -rf build && mkdir -p build/universal build/headers
LIBS=()
for t in "${TARGETS[@]}"; do LIBS+=("target/$t/release/libkeyfinder_core.a"); done
lipo -create "${LIBS[@]}" -output build/universal/libkeyfinder_core.a
cp include/keyfinder.h include/module.modulemap build/headers/
xcodebuild -create-xcframework \
    -library build/universal/libkeyfinder_core.a -headers build/headers \
    -output build/KeyFinderCore.xcframework
echo "Built core/build/KeyFinderCore.xcframework"
