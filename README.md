# Codex Heartbeat

A native macOS menu-bar companion for managed, interactive Codex CLI sessions. SwiftUI `MenuBarExtra`, a native launcher, dedicated loopback App Servers, local private registry, no cloud service or analytics. Uses your normal `codex login` / ChatGPT account; no API key is needed.

**Keep Warm is opt-in per thread.** It sends at most two real Codex turns, about 25 minutes apart, using a minimal “do nothing; reply OK” prompt. These turns consume your ChatGPT/Codex allowance. The inspected Codex 0.156.1 protocol cannot enforce no tool calls on an individual turn, so this is a best-effort instruction, not a security guarantee. Enable it only if that tradeoff is acceptable.

## Requirements and build

- macOS 13 or later; an Apple Swift toolchain supporting Swift 5.9 or later.
- Codex CLI on `PATH`, tested protocol: `codex-cli 0.156.1`.
- Sign in using `codex login` and choose your ChatGPT account. The wrapper inherits Codex's normal authentication/configuration; it does not copy or inspect credentials.
- No third-party runtime dependencies. Python 3 is only used by the optional schema audit script.

```sh
cd /Users/chen/code/CodexHeartbeat
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
sh scripts/build-app.sh
open "dist/Codex Heartbeat.app"
```

The release build creates `dist/Codex Heartbeat.app` and `dist/bin/codex-heartbeat`, signed locally with an ad-hoc signature. No administrator privileges, Xcode project, API key, or npm installation is required. The menu app has no Dock icon or settings window.

To install for your account:

```sh
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
ditto "dist/Codex Heartbeat.app" "$HOME/Applications/Codex Heartbeat.app"
install -m 755 dist/bin/codex-heartbeat "$HOME/.local/bin/codex-heartbeat"
export PATH="$HOME/.local/bin:$PATH"
open "$HOME/Applications/Codex Heartbeat.app"
```

Add that `export PATH` line to your shell profile if desired. These are installation instructions, not changes made automatically by the build.

## First managed session

Open a real terminal, change to your project, and run the launcher:

```sh
cd /path/to/your/project
/Users/chen/code/CodexHeartbeat/dist/bin/codex-heartbeat
```

Or name the session and select a directory/model:

```sh
codex-heartbeat --name "Website" --cd /path/to/website -- --model gpt-6-sol
```

Only `--model`/`-m`, `--no-alt-screen`, and one quoted initial prompt are passed through after `--`. Arbitrary Codex subcommands, configuration, remote endpoints, and cwd overrides are rejected. The working directory is passed as a literal argument, never through a shell. Existing Codex settings still apply normally; use the TUI for your ordinary permission/model choices.

Start another wrapper in another terminal to manage another session. Existing sessions launched with plain `codex` are not adopted or modified. Exit the normal TUI with `/quit`; the registration and dedicated server are cleaned up. Ctrl-C is delivered to the TUI, not treated as a request to kill its server. Closing the terminal or terminating the launcher also initiates cleanup.

Click the heart to see project/thread names, directories, active/idle/disconnected/failed state, last activity, latest input/cached/cache-write/output/reasoning/total tokens, lifetime thread total, model context window, and estimated context remaining. Finder buttons open directories through `NSWorkspace`, not shell commands.

The heart is outlined while no keep-warm schedule is enabled, filled while at least one is enabled, and slashed for a disconnected/error warning. Each row shows when a heartbeat was sent and when the next is due. Reconnect is manual after a transport error; there is no retry loop.

## Context and activity semantics

Telemetry comes from `thread/tokenUsage/updated`. The cache-write field defaults to zero if omitted, as specified by the generated schema. Unknown context-window values stay unknown, not zero-percent/full-context claims.

Estimated used fraction = `last.totalTokens / modelContextWindow`, clamped to 0…1. Remaining = `100 × (1 − used)`. Cached input is already included in input usage and is never added again. Cumulative `total.totalTokens` is displayed separately and is not used as context occupancy. This is an estimate of the latest reported request, not the exact next prompt after hidden/system overhead or compaction. At exactly 60% the color remains normal; above 60% orange; above 80% red. Compaction invalidates the displayed estimate until fresh usage arrives.

App Server activity is authoritative: turn/item events and active/idle status, not terminal text. Unsubmitted keystrokes are not exposed by the protocol, so drafting a prompt cannot be detected passively. Usage may remain unknown until the next real request if the server does not replay usage on subscription. No values are inferred from terminal rendering or local transcript files.

The monitor lists loaded threads, reads summaries, and rejoins existing loaded root threads with `thread/resume` (`excludeTurns: true`, no overrides) to subscribe. This does not start a model turn. Codex 0.156.1 creates saved history lazily: a new thread can return “no rollout found” until its first user turn. The dashboard waits for that turn instead of generating one. It ignores subagent threads and never handles approval requests. There is a narrow loaded-list/resume race if a thread unloads between those calls; Codex can rehydrate the same thread. Generic monitoring RPCs are read-only; only the typed, opt-in heartbeat path can call `turn/start` and interrupt a turn it started.

## Heartbeat protocol and safety limit

Regenerate the actual installed protocol, including experimental fields:

```sh
sh scripts/generate-schemas.sh
```

See `work/app-server-schema/v2/TurnStartParams.json`, `experimental/v2/TurnStartParams.json`, and `v2/ThreadTokenUsageUpdatedNotification.json`. The generated schema directory is ignored by Git because it is large and tied to the local binary. The initial requested temporary schema generation was also performed successfully.

Evidence from Codex 0.156.1:

- `turn/start` requires `threadId` and `input`, so an existing-thread turn is supported.
- No stable or experimental per-turn `tools`, `toolChoice`, tool allowlist, or equivalent deny-all control exists.
- A `readOnly` sandbox blocks writes, not tool calls or repository inspection. `approvalPolicy: never` means do not ask for approvals; it is not a blanket tool denial.
- Experimental `environments: []` disables environment access, not every tool class.
- `ThreadResumeResponse.disabledPluginIds` explicitly says it **“Does not yet filter plugin capabilities.”** Disabling plugins is therefore not a safe substitute.
- `effort` and `sandboxPolicy` explicitly override this **and subsequent turns**. A background heartbeat must not silently change the user's next turn.
- A shortest-acknowledgement prompt, output JSON schema, or interrupt-on-tool-event cannot enforce no tools: by the time an event is observed, execution may have begun.

At your explicit request, Keep Warm uses prompt-only best effort despite that limitation. It sends a documented `turn/start` on the already attached thread with only `threadId` and a text `input`: “Do nothing. Do not call tools, inspect files, or change anything. Reply only OK.” It sets no sticky model, effort, sandbox, or approval overrides and never adds invented fields. The monitor watches item events; if a tool item begins, it stops the schedule, attempts to interrupt its own turn, and warns. That reaction cannot undo an action already begun. See the [official App Server documentation](https://learn.chatgpt.com/docs/app-server) for the protocol overview; local generated schemas are authoritative for this binary.

Keep Warm starts off, can only be enabled on an idle connected thread, and sends its first turn after about 25 minutes. It sends at most two per activation and never less than 25 minutes apart, including across reactivation. User turn activity cancels the schedule; the user must re-enable it. Compaction, error, disconnect, thread unload, app quit, and disabling the toggle also stop it. Disabling or activity attempts to interrupt an in-flight heartbeat. Monotonic deadlines avoid rapid catch-up pulses after sleep or clock changes. No preferences/timing controls or retries are exposed. The schedule is in memory, so app restart clears opt-in state.

Real turns consume ChatGPT/Codex allowance. Cache retention and billing are server-owned; a 25-minute cadence cannot guarantee cache residency or extend account limits.

## Registry and process safety

Records live in `~/Library/Application Support/Codex Heartbeat/Sessions/`: directory mode 0700, files 0600, atomic writes. Only discovery data is stored: UUID, project name/cwd, strict loopback endpoint, process IDs plus start timestamps and executable paths, Codex version, start time. No chat content, credentials, auth tokens, or App Server logs are persisted by this project. Codex itself retains its normal session data according to its configuration.

Before connecting, validate owner/server/TUI process identities (same-user PID, start timestamp, executable path) and inspect the server's actual listening socket with macOS `libproc`. Only canonical `ws://127.0.0.1:PORT` endpoints on unprivileged ports are accepted. No wildcard/network listeners, credentials in URLs, symlinks, oversized records, or untrusted registry files are accepted. A free-port race is handled by verifying the actual server owns the socket before registration; startup fails if it does not.

The launcher supervises its own TUI. A separate supervisor watches the launcher's process identity and terminates its own App Server if the launcher disappears, including a launcher crash. Normal cleanup signals only owned, identity-checked children. If the supervisor itself is forcibly killed, its server may remain until manually stopped; the dashboard will never kill a process from stale registry data.

The menu app removes valid stale records when any required process is gone/replaced. Records whose processes are alive but whose socket is unavailable stay visible as disconnected, so the error is not silently hidden. Malformed records are ignored with a warning and retained for inspection. Scanning/cleanup never signals a process. Keep-warm state and telemetry are in memory, so restarting the app always resets opt-in state.

```sh
codex-heartbeat --list
codex-heartbeat --prune
```

Both commands prune valid stale records and list live registrations without creating a model turn.

## Verification

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
HEARTBEAT_INTEGRATION=1 swift test --filter IntegrationTests
sh scripts/generate-schemas.sh
plutil -lint Resources/Info.plist
```

Unit tests cover context math, threshold boundaries, nullable windows, cache-write defaults, all usage fields, activity/compaction/error cancellation, minimum interval, two-pulse limit, independent opt-in state, safe arguments, hostile endpoints, PID reuse, registry permissions/round-trip/stale handling/symlinks, and the monitoring mutation denylist.

The opt-in integration test starts a dedicated loopback App Server, opens a persistent test thread, injects one harmless test-history message to materialize its history, joins with a separate monitor connection, and checks live notification delivery without calling `turn/start`. It archives the test thread afterward; the archived test history remains in Codex's own storage. This default integration test does not consume model allowance.

A second integration test starts the native supervisor, verifies its owned loopback listener, terminates the supervisor, and verifies App Server exits. See [VERIFICATION.md](VERIFICATION.md) for the observed results and remaining verification limits.

To additionally verify the production heartbeat sender and actual token delivery, explicitly opt into ONE minimal model turn (uses your Codex allowance):

```sh
HEARTBEAT_INTEGRATION=1 HEARTBEAT_LIVE_TURN=1 swift test --filter IntegrationTests
```

This isolated test asks for `OK` in a newly created empty directory with a read-only thread sandbox, checks `thread/tokenUsage/updated` and completion, and asserts that no tool items occurred. It tests the production sender, but is not a 25-minute timer test or proof that prompts can enforce tool denial. There is a 90-second test deadline and no model retry.

## Apple toolchain diagnosis

This machine currently selects `/Library/Developer/CommandLineTools`, Swift `6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, and the macOS 27 SDK. Full Xcode also exists at `/Applications/Xcode.app` and reports the same compiler version.

An initial sandboxed build could not write `…/C/clang/ModuleCache/…SwiftShims….pcm`, followed by an SDK-mismatch diagnostic mentioning SDK Swift `6.4.0.31.4` vs compiler `6.4.0.34.1`. Foundation compilation with a writable module cache succeeded. Diagnose the first error: cache denial is not an application source failure and can cascade into a misleading mismatch report. Allow normal Swift compiler/cache access and retry before replacing toolchains.

The ordinary CLT debug and release builds subsequently succeeded. CLT's test build failed to resolve `XCTest` and emitted missing developer-framework path warnings. Using the installed full Xcode via `DEVELOPER_DIR` fixed that failure; no compiler/SDK reinstall was necessary. The primary instructions above select Xcode only in the current shell.

If a mismatch remains in an ordinary Terminal, select a complete local Xcode toolchain for that command only:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --show-sdk-path
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --scratch-path .build-xcode
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-xcode
```

If both installations fail, install a matching full Xcode release via the App Store/Apple Developer downloads, launch Xcode once to finish component installation, and use that `DEVELOPER_DIR`. Alternatively install the matching Command Line Tools package from Apple Developer Downloads (`xcode-select --install` when no CLT installation exists). Do not mix a compiler from one release with an SDK copied from another. No system-wide `xcode-select --switch` or SDK replacement is performed by this project.
