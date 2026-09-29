# Technical guide

Build, installation, monitoring semantics, and development details for [Codex Heartbeat](../README.md).

## Build and run

Requirements: macOS 13 or later, a Swift 5.9-or-later toolchain, and an installed Codex CLI on `PATH`. Full Xcode is recommended for XCTest. The initial protocol audit used Codex 0.156.1; installed CLI updates can change compatibility. There are no third-party runtime dependencies; Python 3 is needed only for the optional schema audit.

From this repository:

```sh
# Select full Xcode for this shell, without changing the system selection.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --scratch-path .build-xcode
sh scripts/build-app.sh
open "dist/Codex Heartbeat.app"
```

The build creates an ad-hoc-signed app and launcher at:

```text
dist/Codex Heartbeat.app
dist/bin/codex-heartbeat
```

The app has a heart icon in the menu bar and no Dock icon. If a previous build is running, quit it from the heart menu and reopen the new bundle.

Optional per-user installation:

```sh
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
ditto "dist/Codex Heartbeat.app" "$HOME/Applications/Codex Heartbeat.app"
install -m 755 dist/bin/codex-heartbeat "$HOME/.local/bin/codex-heartbeat"
export PATH="$HOME/.local/bin:$PATH"
open "$HOME/Applications/Codex Heartbeat.app"
```

Add the PATH line to your shell profile if desired. The build does not install files or change your shell configuration automatically.

## Start a managed session

Sign in with `codex login` if you have not already. Then run the launcher in your project’s terminal. Before installation, use the absolute path to this repository’s `dist/bin/codex-heartbeat`.

```sh
cd /path/to/project
codex-heartbeat

# Resume or fork an existing conversation.
codex-heartbeat resume --last
codex-heartbeat resume SESSION_ID
codex-heartbeat fork --last

# Name a new managed session and choose its directory.
codex-heartbeat --heartbeat-name "Website" --cd /path/to/website --no-alt-screen
```

Codex options belong before any `--` separator. Arguments after `--` are positional prompt text; for example, `-- --no-alt-screen` would submit that text as a prompt rather than set an option.

Each managed terminal gets its own loopback App Server and private registration. Start another launcher in another terminal to monitor another session. Existing plain `codex` sessions are not adopted. Exit with `/quit` to clean up the registration and dedicated server.

New interactive sessions, `resume`, and `fork` are managed. Other subcommands, including `login`, `mcp`, `exec`, `review`, and `app-server`, pass through unchanged without monitoring. Explicit `--remote` or `--no-daemon`, help/version requests, and unrecognized options also pass through. Known arguments are preserved literally without shell interpolation; the wrapper does not override your model, sandbox, approvals, or saved-directory choice on resume.

Wrapper help and registry inspection:

```sh
codex-heartbeat --heartbeat-help
codex-heartbeat --list
codex-heartbeat --prune
```

Both registry commands remove valid stale records and list live registrations without starting a model turn or signalling processes.

## Understand the numbers

**Idle** means the thread is open but not currently processing a turn. It does not mean the cache has expired. The app cannot inspect backend cache residency.

Usage arrives through App Server `thread/tokenUsage/updated` notifications. If it is unavailable, the dashboard says “Waiting for token usage from the next completed turn.” Send a normal prompt in that managed terminal and let it finish while the app is monitoring. Even “Reply only OK” can provide telemetry. Refresh rescans sessions and reads thread summaries; it never generates a model turn to obtain usage, and older usage may not be replayed after reconnect.

```text
estimated used fraction = latest turn total tokens / reported context window
estimated remaining %   = 100 × (1 − estimated used fraction)
```

The fraction is clamped to 0–1. Cumulative thread total is displayed separately and never used as context occupancy. Cached input is already part of input usage; it is not added a second time. Context pressure turns orange above 60% used and red above 80%. After compaction, the estimate is marked stale until fresh usage arrives.

A fresh thread can consume several percent before much user text is added: instructions, tool definitions, project guidance, and history contribute to the request. A 95% reading means approximately 5% of the **reported window** was used by the latest request, not that 5% of your subscription allowance is gone. The app does not break down harness overhead or assume a universal window size across models.

“Estimated context cache” is the latest reported cached-input count. It describes reuse on that request, not tokens guaranteed to remain cached now. A missing cache-write field defaults to zero for protocol compatibility; this is not evidence that no cache write occurred or that cache writes are free.

## Keep Warm during a break

Enable Keep Warm only on an idle, connected, attached thread. The first heartbeat is due about 25 minutes after enabling it; a second is due about 25 minutes after the first is sent. There is no immediate-heartbeat button or indefinite loop.

```mermaid
sequenceDiagram
    participant You
    participant App as Codex Heartbeat
    participant Thread as Existing Codex thread
    You->>App: Enable Keep Warm before lunch
    Note over App: Wait approximately 25 minutes
    App->>Thread: Do nothing; reply only OK (1/2)
    Note over App: Wait approximately 25 more minutes
    App->>Thread: Do nothing; reply only OK (2/2)
    Note over App: Schedule ends after completion
    You->>Thread: Resume work
```

For a roughly one-hour lunch, successful requests around minutes 25 and 50 may bridge the idle period. The app must remain running and the Mac awake enough to send them. After sleep it does not send a burst of missed heartbeats. A longer absence can outlast this two-heartbeat schedule.

A submitted user turn cancels Keep Warm, including if you return before the first pulse. You must explicitly enable it again for another break. Unsubmitted terminal typing is not observable. Disconnection, errors, compaction, thread unload, disabling the toggle, or quitting the app also stop the schedule. Reconnect and app restart restore no automatic opt-in state. Reactivation cannot send pulses less than 25 minutes apart.

The exact prompt is:

> Do nothing. Do not call tools, inspect files, or change anything. Reply only OK.

The heartbeat uses the existing thread and its model/configuration, with no sticky model, effort, sandbox, or approval overrides. It adds real prompt/response history and may update usage estimates.

**The no-tools instruction is best effort.** The audited Codex 0.156.1 protocol had no per-turn deny-all-tools control. A read-only sandbox is not a tool prohibition. If a tool item begins, the monitor stops the schedule and attempts to interrupt its own heartbeat; it cannot undo an action already started. Disabling or user activity also attempts to interrupt an owned heartbeat.

## Architecture and privacy

```text
Managed terminal → native launcher → dedicated loopback Codex App Server
                          ↓                         ↑
                    private registry → menu app monitoring connection
```

The menu app lists loaded root threads, reads summaries, and rejoins existing threads with `thread/resume` and `excludeTurns: true` to receive notifications. It ignores subagent threads and never handles approval requests. New threads without materialized history can remain in a waiting state until their first user turn. Decoding failures appear as session warnings instead of silently hiding the thread.

Registration records live in `~/Library/Application Support/Codex Heartbeat/Sessions/`, with directory mode 0700 and file mode 0600. They contain discovery metadata: names, directories, endpoints, process identities, timestamps, and CLI version. The app validates process start identities and listener ownership before connecting and accepts only canonical `ws://127.0.0.1:PORT` endpoints.

This project stores no chat content, credentials, or App Server logs and adds no analytics. Codex still communicates with its normal backend and retains its own session data. Heartbeats send model requests through that same service.

The launcher and supervisor clean up their owned children. Registry scans never kill processes. Malformed registrations are retained with a warning; valid stale records are pruned. Force-killing the supervisor itself can leave its server behind. Normal termination is tested; the full terminal-close/forced-kill matrix is not exhaustively verified.

## Verification and development

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --scratch-path .build-xcode

# Local App Server lifecycle, discovery, reconnect, and scheduling checks.
# No model turn unless HEARTBEAT_LIVE_TURN is also enabled.
HEARTBEAT_INTEGRATION=1 swift test --scratch-path .build-xcode --filter IntegrationTests

# Opt into one real minimal turn; consumes Codex allowance.
HEARTBEAT_INTEGRATION=1 HEARTBEAT_LIVE_TURN=1 \
  swift test --scratch-path .build-xcode --filter IntegrationTests

# Audit the installed CLI’s stable and experimental schemas.
sh scripts/generate-schemas.sh
```

Unit tests cover token math, unknown fields, scheduling, cancellation, CLI routing, literal arguments, endpoint validation, process identity, registry permissions, and decoding-warning recovery. Hosted SwiftUI layout tests check empty/single/multiple sessions, positive viewport height, scrolling, and light/dark appearance; the README figure comes from those fixtures.

Local integration tests exercise production `SessionMonitor` root-thread discovery, initial opt-out, a roughly 1,500-second deadline, reconnect cancellation, passive notifications, and supervisor cleanup. Tests use a disposable history item to materialize the test thread and archive it afterward; the archived history remains in Codex storage. The optional live test verifies usage delivery and no observed tool items for that turn, not a general tool-denial guarantee.

Release packaging and signature verification passed. A real managed CLI returned `OK` for a dummy prompt, and `/quit` cleanup was verified. The user subsequently confirmed that the packaged app displays a session and updates to approximately 95% remaining. Automated inspection of the menu-only popover timed out, so direct packaged-popover countdown interaction and elapsed 25-minute delivery have not been visually/wall-clock verified. Hosted-view and production scheduling checks are separate evidence.

See [verification record](verification.md) for detailed results, protocol evidence, and limitations. If XCTest cannot be found under Command Line Tools, use full Xcode through `DEVELOPER_DIR`; no system-wide toolchain switch is needed.
