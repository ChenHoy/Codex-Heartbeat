# Verification record — 2026-09-23

Created a new project at `/Users/chen/code/CodexHeartbeat` after the existing scaffold could not be located and the user explicitly authorized starting a new project through Spokenly. No unrelated project files were changed. No global Xcode selection or Codex settings were changed.

## Git and CLI compatibility update

Initialized this directory as its own Git repository and committed the pre-compatibility project as `fa6b262` (`Initial Codex Heartbeat app and managed CLI`). The compatibility work is subsequent to that baseline. Git used the machine's automatically inferred author identity; no global Git configuration was changed.

The launcher now routes new interactive sessions, `resume`, and `fork` through its own loopback App Server with the original Codex arguments preserved. Other CLI commands are executed directly, unchanged and unmonitored. Explicit `--remote`/`--no-daemon` is also passed through. Unit tests cover routing, relative `--cd`, resume construction without an injected `--cd`, and literal metacharacters. A debug build's `--version` and `resume --help` matched the installed Codex CLI.

After the routing change, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-xcode` passed 24 unit tests (2 opt-in integration tests skipped). Running the integration suite with `HEARTBEAT_INTEGRATION=1` passed both tests. The release build, app packaging, and `codesign --verify --deep --strict` passed. `dist/bin/codex-heartbeat login --help` showed the installed Codex login help via direct pass-through.

A no-prompt PTY smoke run of `codex-heartbeat resume --last --no-alt-screen` started the managed server and reached Codex's resume screen. Codex reported that the chosen conversation was already open in another app; it was not unlocked or used. Exiting cleaned up the new registration. This verifies resume routing and startup, but not a completed interactive resumed chat. The separate pre-existing managed registration was untouched. No model turn was submitted in this smoke run.

## Build and tests

| Command/check | Observed result |
| --- | --- |
| `codex --version` | `codex-cli 0.156.1` |
| `codex app-server generate-json-schema --out /private/tmp/codex-heartbeat-schema.hmhhKa` | Passed; stable schemas generated from installed binary |
| Experimental generation plus `sh scripts/generate-schemas.sh` | Passed; usage fields verified, no per-turn deny-all tool control |
| `swift -module-cache-path /private/tmp/codex-heartbeat-module-cache -e 'import Foundation; print("Swift Foundation OK")'` | Passed |
| Initial sandboxed `swift build` | Failed on denied compiler-cache writes; cascading SDK mismatch diagnostic |
| Ordinary `swift build` with normal cache access | Passed using selected Command Line Tools |
| `swift build -c release` | Passed; nonfatal missing CLT developer-framework search-path warnings |
| Bare `swift test` under Command Line Tools | Failed to resolve `XCTest`; environment/toolchain packaging issue |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-xcode` | 22 unit tests passed; 2 opt-in integration tests skipped in the default run |
| `HEARTBEAT_INTEGRATION=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-xcode --filter IntegrationTests` | Both local integration tests passed: passive subscription and supervisor cleanup |
| Same integration command with `HEARTBEAT_LIVE_TURN=1` (one explicitly approved test turn) | Real telemetry and completion received; no tool items observed |
| `HEARTBEAT_INTEGRATION=1 HEARTBEAT_LIVE_TURN=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-xcode --filter IntegrationTests` after adding the heartbeat sender | 2 integration tests passed; production `AppServerClient.startHeartbeat` received real usage and completion, no tool items observed. Input 13,930, cached 8,064, cache-write 0, total 13,935, window 258,400. Consumed one Codex turn. |
| `plutil -lint Resources/Info.plist` | Passed |
| `sh -n scripts/build-app.sh scripts/generate-schemas.sh` | Passed |
| `sh scripts/build-app.sh --skip-build` after release compilation | Native `.app` and launcher packaged and ad-hoc signed |
| `codesign --verify --deep --strict 'dist/Codex Heartbeat.app'` | Passed |

## Real telemetry

The one ordinary test turn used the normal local Codex authentication and requested only `OK` in a fresh, empty temporary directory with read-only sandboxing. A second connection subscribed using the same client implementation as the dashboard and received `thread/tokenUsage/updated`:

| Field | Value |
| --- | ---: |
| Latest input tokens | 14,831 |
| Cached-input tokens | 7,040 |
| Cache-write input tokens | 0 |
| Latest total tokens | 14,836 |
| Model context window | 258,400 |
| Estimated context remaining | 94.3% |

This was the earlier ordinary test turn, not a scheduled heartbeat. The later test used the production heartbeat sender (without waiting 25 minutes), likewise consumed normal Codex allowance, and observed no tool items. Test threads were archived afterward and their local test directories removed; Codex retains the archived history. No access tokens were printed or stored by this project.

## Launcher and native application

Ran `dist/bin/codex-heartbeat --name 'Heartbeat smoke test' --cd /private/tmp -- --no-alt-screen` in a PTY. It started its own loopback App Server, registered a mode-0600 record, opened the real Codex 0.156.1 TUI, and displayed Codex's ordinary folder-trust flow. Broad temporary-directory trust was not accepted. Exited the TUI without submitting a prompt; wrapper exit code was 0. A subsequent `dist/bin/codex-heartbeat --list` showed zero sessions and the registry directory was empty.

The packaged app was opened successfully via Launch Services; `open … -W` remained waiting, confirming it stayed running. Computer-use inspection repeatedly timed out for this menu-only app. Therefore the popover's final visual layout and actual menu-bar interaction have **not** been independently visually verified. No claim of visual QA is made.

If an earlier build is already running, quit it from the heart popover and reopen the final bundle before testing the latest changes.

## Protocol evidence and honest limits

The schema audit produced these `TurnStartParams.json` hashes:

- Stable SHA-256: `2dfcf68705896fadc344ccfeb2e9fe5a6bcbbb8b9a90cf449ce232b636daf05a`
- Experimental SHA-256: `07771223642e1b61bd9aac0069fc0f98143a1c047724ca02c7ceb13653442738`

`threadId`/`input` support starting an existing-thread turn. There is no deny-all tool control. Read-only is not tool-free, experimental environment disabling is not global tool disabling, and `disabledPluginIds` explicitly does not yet filter capabilities. Effort/sandbox overrides persist into subsequent turns. The user explicitly accepted prompt-only best effort, so opt-in automatic turns are now implemented without sticky overrides. A tool-start event stops the schedule and triggers an interrupt attempt, but cannot undo an action already started. The 25-minute timer itself has unit coverage, not an elapsed-wall-clock integration run.

The live experiment also demonstrated that `thread/resume` rejects a newly created empty thread with “no rollout found.” Injecting a harmless history item in the test (without model generation) materialized it, after which passive subscription and notification delivery passed. Production monitoring never injects history; it waits for the user's first turn.

Remaining limits: no hard no-tools guarantee; no observation of unsubmitted terminal keystrokes; no guarantee of backend cache residency; no visual popover QA; force-killing the supervisor itself can leave its App Server orphaned. Normal supervisor termination is tested, but a full launcher-SIGKILL/terminal-close matrix and multiple simultaneous interactive terminals have not been exhaustively exercised. No unrelated processes are killed as stale-record cleanup.

## Files introduced

- `Package.swift`, `.gitignore`
- `Sources/CodexHeartbeat/CodexHeartbeatApp.swift` — native menu/popover
- `Sources/HeartbeatLauncher/main.swift` — native wrapper and crash supervisor
- `Sources/HeartbeatCore/{Models,Registry,LaunchPlan,AppServerClient,SessionMonitor}.swift`
- `Sources/HeartbeatSystem/system.c`, `include/HeartbeatSystem.h` — process identity, listener ownership, terminal spawn
- `Tests/HeartbeatCoreTests/{CoreTests,IntegrationTests}.swift`
- `Resources/Info.plist`
- `scripts/{build-app.sh,generate-schemas.sh,audit-protocol.py}`
- `README.md`, `VERIFICATION.md`
- Generated, ignored artifacts: `dist/`, `.build/`, `.build-xcode/`, `work/app-server-schema/`

## Separate hook issue

The enabled Superwhisper plugin's six hooks all invoke `${SUPERWHISPER_CODEX_HOOK:-/Applications/superwhisper.app/Contents/Resources/agent-hook} codex`. The override was unset and that executable was absent. This explains shell exit 127. Disable `superwhisper@superwhisper` in Codex or set `enabled = false` in its existing `~/.codex/config.toml` plugin section and restart Codex; alternatively reinstall Superwhisper. Spokenly is independent. No hook/plugin configuration was modified during this work.
