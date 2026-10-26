.PHONY: all core project build build-clt register auval test smoke clean

all: build

# App to register/validate; for the Command Line Tools build pass
# APP=plugin/build/clt/KeyFinder.app
APP ?= plugin/build/Build/Products/Release/KeyFinder.app
APPEX = $(abspath $(APP))/Contents/PlugIns/KeyFinderAU.appex
AU_ID = com.ryanrusson.keyfinder.audiounit
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Rust core -> core/build/KeyFinderCore.xcframework (macOS only)
core:
	./scripts/build-core.sh

# Xcode project from plugin/project.yml (brew install xcodegen)
project:
	cd plugin && xcodegen generate

build: core project
	xcodebuild -project plugin/KeyFinder.xcodeproj -scheme KeyFinder -configuration Release \
		-derivedDataPath plugin/build build

# Same app built with only the Command Line Tools (no Xcode or XcodeGen)
build-clt:
	./scripts/build-plugin-clt.sh

# Register $(APP)'s extension (what launching the app does), unregistering
# any other copy first: both builds share a bundle identifier.
register:
	pluginkit -m -A -D -v -i $(AU_ID) | awk -F'\t' 'NF > 1 { print $$NF }' | while IFS= read -r p; do \
		[ "$$p" = "$(APPEX)" ] || { pluginkit -r "$$p"; $(LSREGISTER) -u "$${p%/Contents/PlugIns/KeyFinderAU.appex}"; }; done
	$(LSREGISTER) -f "$(abspath $(APP))"
	pluginkit -a "$(APPEX)"
	pluginkit -m -v -i $(AU_ID)
	@# The AudioComponent registrar picks the change up a few seconds later.
	@for i in 1 2 3 4 5 6 7 8 9 10; do auval -a 2>/dev/null | grep -q 'kyDt KyFn' && exit 0; sleep 1; done; \
		echo "The AU isn't visible to auval yet; run make auval again in a moment." >&2

auval: register
	auval -strict -v aufx kyDt KyFn

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
