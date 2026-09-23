#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--skip-build" ]; then
    swift build -c release
fi
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/dist/Codex Heartbeat.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$PWD/dist/bin"
cp "$bin_dir/CodexHeartbeat" "$app_dir/Contents/MacOS/.CodexHeartbeat.new"
mv "$app_dir/Contents/MacOS/.CodexHeartbeat.new" "$app_dir/Contents/MacOS/CodexHeartbeat"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp "$bin_dir/codex-heartbeat" "$PWD/dist/bin/.codex-heartbeat.new"
mv "$PWD/dist/bin/.codex-heartbeat.new" "$PWD/dist/bin/codex-heartbeat"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --force --sign - "$PWD/dist/bin/codex-heartbeat"
printf 'Built %s\nLauncher: %s/dist/bin/codex-heartbeat\n' "$app_dir" "$PWD"
