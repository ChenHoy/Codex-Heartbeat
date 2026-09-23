#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
codex --version
codex app-server generate-json-schema --out work/app-server-schema
codex app-server generate-json-schema --experimental --out work/app-server-schema/experimental
python3 scripts/audit-protocol.py work/app-server-schema
