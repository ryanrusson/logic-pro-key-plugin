.PHONY: all core project build test smoke clean

all: build

# Rust core -> core/build/KeyFinderCore.xcframework (macOS only)
core:
	./scripts/build-core.sh

# Xcode project from plugin/project.yml (brew install xcodegen)
project:
	cd plugin && xcodegen generate

build: core project
	xcodebuild -project plugin/KeyFinder.xcodeproj -scheme KeyFinder -configuration Release \
		-derivedDataPath plugin/build build

# Rust unit + accuracy tests, and the C ABI smoke test (any platform)
test:
	cd core && cargo test --release
	$(MAKE) smoke

smoke:
	cd core && cargo build --release && \
	cc -O2 -Wall -Wextra -Iinclude tests/ffi_smoke.c target/release/libkeyfinder_core.a \
		-lm -lpthread $(if $(filter Linux,$(shell uname)),-ldl,) -o target/ffi_smoke && ./target/ffi_smoke

clean:
	rm -rf core/target core/build plugin/build plugin/KeyFinder.xcodeproj plugin/Generated
