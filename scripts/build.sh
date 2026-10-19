#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c "$configuration" --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
binary_directory="$(swift build -c "$configuration" --show-bin-path --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox)"
app="$PWD/.build/Bob.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Bob" "$app/Contents/MacOS/Bob"
cp Resources/Info.plist "$app/Contents/Info.plist"
for bundle in "$binary_directory"/*.bundle; do
    if test -d "$bundle"; then
        rm -rf "$app/Contents/Resources/$(basename "$bundle")"
        cp -R "$bundle" "$app/Contents/Resources/"
    fi
done
decision_runtime="$PWD/.build/decisions/runtime/release"
if test -x "$decision_runtime/BobDecision" && test -f "$PWD/.build/decisions/model/model.safetensors"; then
    mkdir -p "$app/Contents/Helpers"
    cp "$decision_runtime/BobDecision" "$app/Contents/Helpers/BobDecision"
    cp "$decision_runtime/mlx.metallib" "$app/Contents/Helpers/mlx.metallib"
    for bundle in "$decision_runtime"/*.bundle; do
        if test -d "$bundle"; then
            # SwiftPM copies read-only license files; replace the old bundle
            # instead of trying to overwrite its individual resource files.
            rm -rf "$app/Contents/Resources/$(basename "$bundle")"
            cp -R "$bundle" "$app/Contents/Resources/"
        fi
    done
    # Encode the developer model location without interpreting shell content.
    rm -f "$app/Contents/Resources/DecisionModel.json"
    /usr/bin/plutil -create xml1 "$app/Contents/Resources/DecisionModel.json"
    /usr/bin/plutil -insert modelDirectory -string "$PWD/.build/decisions/model" "$app/Contents/Resources/DecisionModel.json"
    /usr/bin/plutil -convert json "$app/Contents/Resources/DecisionModel.json"
    codesign --force --sign - "$app/Contents/Helpers/BobDecision"
    codesign --force --sign - "$app/Contents/Helpers/mlx.metallib"
else
    rm -f "$app/Contents/Resources/DecisionModel.json"
fi
swift scripts/Icon.swift "$PWD/.build/Bob.iconset"
cp .build/Bob.icns "$app/Contents/Resources/Bob.icns"
codesign --force --sign - "$app"
echo "Built $app"
