#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/bob-simulator.XXXXXX")"
test_device=""
cleanup() {
    if [[ -n "$test_device" ]]; then
        xcrun simctl shutdown "$test_device" >/dev/null 2>&1 || true
        xcrun simctl delete "$test_device" >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture_directory"
}
trap cleanup EXIT
app="$fixture_directory/SimulatorFixture.app"
mkdir -p "$app"
xcrun --sdk iphonesimulator swiftc Tests/SimulatorFixture/main.swift -parse-as-library \
    -target "$(uname -m)-apple-ios17.0-simulator" -module-cache-path "$PWD/.build/module-cache" \
    -o "$app/SimulatorFixture"
cp Tests/SimulatorFixture/Info.plist "$app/Info.plist"
test_device="$(xcrun simctl create "Bob Integration Test" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)"
BOB_SIMULATOR_TEST_UDID="$test_device" BOB_SIMULATOR_FIXTURE_APP="$app" \
    bash scripts/test.sh --filter SimulatorTests
