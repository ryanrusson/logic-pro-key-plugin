#!/usr/bin/env bash
# Builds KeyFinder.app and its AUv3 extension with only the Xcode Command Line
# Tools (swiftc, lipo, codesign): no Xcode, no XcodeGen. Info.plists and
# entitlements are generated from plugin/project.yml, so the spec stays the
# single source of truth. Signed ad hoc ("Sign to Run Locally").
#
#   CONFIG=debug ARCHS=arm64 scripts/build-plugin-clt.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
read -r -a ARCHS <<< "${ARCHS:-arm64 x86_64}"
OUT=plugin/build/clt
GEN=$OUT/gen
SDK=$(xcrun --sdk macosx --show-sdk-path)

[ -f core/build/universal/libkeyfinder_core.a ] && [ "${SKIP_CORE:-0}" = 1 ] || ./scripts/build-core.sh

rm -rf "$OUT" && mkdir -p "$GEN"

# One line per target: name, type, product, deployment target, source dirs.
TARGETS=$(/usr/bin/ruby -ryaml -rjson - "$GEN" <<'RUBY'
spec = YAML.load_file("plugin/project.yml")
base = spec.dig("settings", "base") || {}
macos = spec.dig("options", "deploymentTarget", "macOS")
spec["targets"].each do |name, t|
  s = base.merge(t.dig("settings", "base") || {})
  product = s["PRODUCT_NAME"] || name
  appex = t["type"] == "app-extension"
  info = {
    "CFBundleDevelopmentRegion" => "en",
    "CFBundleExecutable" => product,
    "CFBundleIdentifier" => s["PRODUCT_BUNDLE_IDENTIFIER"],
    "CFBundleInfoDictionaryVersion" => "6.0",
    "CFBundleName" => product,
    "CFBundlePackageType" => appex ? "XPC!" : "APPL",
    "CFBundleShortVersionString" => s["MARKETING_VERSION"].to_s,
    "CFBundleVersion" => s["CURRENT_PROJECT_VERSION"].to_s,
    "CFBundleSupportedPlatforms" => ["MacOSX"],
    "LSMinimumSystemVersion" => macos,
  }
  info["NSPrincipalClass"] = "NSApplication" unless appex
  info.merge!(t.dig("info", "properties") || {})
  vars = s.merge("PRODUCT_NAME" => product, "PRODUCT_MODULE_NAME" => product)
  json = JSON.generate(info).gsub(/\$\((\w+)\)/) { vars.fetch($1) { abort "#{name}: unknown build setting $(#{$1})" }.to_s }
  File.write("#{ARGV[0]}/#{product}-Info.json", json)
  File.write("#{ARGV[0]}/#{product}.entitlements.json", JSON.generate(t.dig("entitlements", "properties") || {}))
  puts [name, t["type"], product, macos, t["sources"].join(",")].join("\t")
end
RUBY
)

# compile <product> <deployment target> <source dirs> [swiftc flags...]
compile() {
    local product=$1 macos=$2 dirs=$3; shift 3
    local srcs=() slices=() d arch
    for d in ${dirs//,/ }; do srcs+=(plugin/"$d"/*.swift); done
    local opt=(-O -wmo)
    [ "$CONFIG" = debug ] && opt=(-Onone -g)
    for arch in "${ARCHS[@]}"; do
        echo "swiftc $product ($arch)"
        xcrun swiftc "${opt[@]}" -swift-version 5 -parse-as-library \
            -target "$arch-apple-macos$macos" -sdk "$SDK" -module-name "$product" \
            -I core/include -L core/build/universal -lkeyfinder_core -Xlinker -dead_strip \
            "$@" "${srcs[@]}" -o "$GEN/$product-$arch"
        slices+=("$GEN/$product-$arch")
    done
    lipo -create "${slices[@]}" -output "$GEN/$product"
}

# bundle <product> <bundle path>
bundle() {
    mkdir -p "$2/Contents/MacOS"
    cp "$GEN/$1" "$2/Contents/MacOS/$1"
    plutil -convert xml1 -o "$2/Contents/Info.plist" "$GEN/$1-Info.json"
    plutil -convert xml1 -o "$GEN/$1.entitlements" "$GEN/$1.entitlements.json"
}

sign() { codesign --force --sign - --options runtime --timestamp=none --entitlements "$GEN/$1.entitlements" "$2"; }

APP= APPEX=
while IFS=$'\t' read -r name type product macos dirs; do
    case $type in
        app-extension)
            compile "$product" "$macos" "$dirs" -application-extension \
                -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain
            APPEX=$product ;;
        application)
            compile "$product" "$macos" "$dirs"
            APP=$product ;;
        *) echo "unsupported target type $type ($name)" >&2; exit 1 ;;
    esac
done <<< "$TARGETS"

app_path=$OUT/$APP.app
bundle "$APP" "$app_path"
bundle "$APPEX" "$app_path/Contents/PlugIns/$APPEX.appex"
sign "$APPEX" "$app_path/Contents/PlugIns/$APPEX.appex"
sign "$APP" "$app_path"
codesign --verify --strict --deep "$app_path"
echo "Built $app_path"
