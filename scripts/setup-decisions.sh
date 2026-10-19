#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64 || { echo "Clef requires Apple Silicon." >&2; exit 1; }
root="$PWD"
scratch="$root/.build/decisions"
model="$scratch/model"
revision=92a850bc10a355a69799e63fe87aa7545c551c74
mkdir -p "$model"

# The checkpoint is pinned; these hashes come from its export.json manifest.
cat > "$model/SHA256SUMS" <<'EOF'
bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a  LICENSE
e63a01251540c346a9bd8b293d0b110b5687e0fe5efadd76439e60e9e3028736  config.json
19cdcec8c81dc9212be320fff47462ab342fbc1278be4368fb3da71241cf5ba0  joint_head.safetensors
77efe959a38b5b17b241543e129e695f3c77465ece55a25985279bd8176279a0  joint_head_config.json
37e900124c3e53e859b8c10dcf52e5c7691dec2831c096cfdb54cc21c98645bd  model.safetensors
a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f  tokenizer.json
c8b09e9f680aada75db4e53c5eca3d4a10b205120069e92172528307dffcaab0  tokenizer_config.json
EOF
while read -r checksum file; do
    if test -f "$model/$file" && test "$(shasum -a 256 "$model/$file" | cut -d ' ' -f1)" = "$checksum"; then
        echo "Verified $file"
        continue
    fi
    echo "Downloading $file"
    curl --fail --location --http1.1 --retry 3 --retry-all-errors --continue-at - \
        "https://huggingface.co/aufklarer/Clef-flash-9B-MLX-4bit/resolve/$revision/$file" \
        --output "$model/$file.partial"
    test "$(shasum -a 256 "$model/$file.partial" | cut -d ' ' -f1)" = "$checksum" || {
        echo "Checksum mismatch: $file; remove $model/$file.partial and retry." >&2; exit 1;
    }
    mv "$model/$file.partial" "$model/$file"
done < "$model/SHA256SUMS"
if test "${1:-}" = --download-only; then exit 0; fi

export CLANG_MODULE_CACHE_PATH="$scratch/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache"
swift build --package-path LocalDecision -c release --product BobDecision \
    --scratch-path "$scratch/runtime" --cache-path "$scratch/cache" \
    --config-path "$scratch/config" --security-path "$scratch/security" --disable-sandbox
BUILD_DIR="$scratch/runtime" bash "$scratch/runtime/checkouts/speech-swift/scripts/build_mlx_metallib.sh" release
echo "Clef-flash ready: $scratch/runtime/release/BobDecision"
