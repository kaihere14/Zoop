# Session Bridge

The session bridge connects the Zoop app, which runs as the main user, to ZoopHelper, which runs inside the agent user's GUI session. It replaces the prototype's `bridge` / `SessionHelper` socket code (see `Session-Bridge-Prototype-Explained.md`). The prototype proved the bridge could work. This version is meant to stay up while the app runs.

```
 main user (uid 501)                                agent user (sbagent)
┌───────────────────────────┐                     ┌──────────────────────────────┐
│ ZoopApp / ZoopAgents      │                     │ ZoopHelper (LaunchAgent)     │
│   HelperConnection (actor)│  Unix socket        │   HelperServer               │
│   ├ retry + backoff       │  /Users/Shared/Zoop │   ├ getpeereid UID check     │
│   ├ heartbeat             │  /run/helper.sock   │   ├ hello handshake          │
│   ├ request ids           │ ◀────────────────▶  │   ├ one task per request     │
│   └ state stream ──▶ UI   │  length-prefixed    │   └ SystemBackend            │
└───────────────────────────┘  frames             │       ScreenCaptureKit, TCC  │
                                                  └──────────────────────────────┘
```

## Code map

| File | Role |
|---|---|
| `Sources/ZoopShared/Protocol/Messages.swift` | Typed requests, results, failures and envelopes. `ZoopProtocol.version`. |
| `Sources/ZoopShared/Transport/Frame.swift` | Wire framing (`FrameCodec`, `FrameDecoder`). |
| `Sources/ZoopShared/Transport/UnixSocket.swift` | POSIX socket calls: connect, listen, accept, `getpeereid`. |
| `Sources/ZoopShared/Transport/FramedSocket.swift` | A connected socket: reader thread, locked writes, clean close. |
| `Sources/ZoopShared/Transport/RetryPolicy.swift` | Backoff and jitter. |
| `Sources/ZoopShared/Transport/BridgeError.swift` | Error cases, `isRetryable`, user-facing messages. |
| `Sources/ZoopShared/Transport/HelperConnection.swift` | The client: state machine, retries, heartbeat, replay. |
| `Sources/ZoopHelper/Server/HelperServer.swift` | The server: accept loop, UID check, handshake, dispatch. |
| `Sources/ZoopHelper/Server/SystemBackend.swift` | Real session info, capture and input. Tests use a fake. |
| `Sources/ZoopShared/Protocol/Input.swift` | Point coordinates, input actions, element/app facts and action reports. |
| `Sources/ZoopHelper/Capabilities/Accessibility/AXElement.swift` | AX attributes, actions, hit testing, focused element and bounded tree walks. |
| `Sources/ZoopHelper/Capabilities/Input/SessionActions.swift` | Serializes input and app launching across connections; AX first, PID events when needed. |
| `Sources/ZoopHelper/Capabilities/Input/KeyMap.swift` | ANSI virtual key codes and modifiers. |
| `Sources/ZoopHelper/Capabilities/Apps/Apps.swift` | NSWorkspace app launching inside the agent session. |
| `Sources/ZoopBridgeCLI/IsolationVerification.swift` | Primary-session cursor, frontmost app and input-counter measurements. |
| `Sources/ZoopBridgeCLI/main.swift` | `zoop-bridge` developer tool. |

## Protocol v2

Build and reinstall the helper and client together: v1 and v2 refuse the handshake. The new requests are `inspect`, `elements`, `openApp` and `input`. Input includes click, type, setText, key and scroll. New results carry elements, app info or an `ActionReport`; new failure codes are `notFound` and `unsupported`.

Capture metadata includes image `width`/`height` in pixels and display `pointWidth`/`pointHeight`. Coordinates for every input action use global display points with a top-left origin. Call `metadata.point(fromPixelX:y:)` to convert a point from the captured image. Current capture covers the main display; its origin is (0, 0).

## Wire format

Each message is one frame:

```
[UInt32 headerLength][UInt32 payloadLength][header JSON][payload bytes]
```

Both lengths come first, so the reader knows the frame's size before reading it. It can refuse an absurd size (more than 1 MiB of header or 128 MiB of payload) before allocating any memory. Binary data such as a PNG goes in the payload, so it is never base64-encoded into the JSON.

Headers are `RequestEnvelope { id, request }` and `ResponseEnvelope { id, result | failure }`. Replies carry their request's `id`, so several requests can be in flight at once and their replies may arrive in any order. A slow capture never blocks a ping. A response with `id 0` is a connection-level failure, for example "your UID is not allowed".

## Connection lifecycle

```
disconnected ──▶ connecting(1/4) ──▶ connected ──(drop or missed heartbeats)──┐
                     │    ▲                                                   │
          retryable  ▼    │ after backoff                                     │
                waitingToRetry ◀──────────────────────────────────────────────┘
                     │ 4th attempt failed, or a non-retryable error
                     ▼
                  failed(error)  ── next command or connect() starts a fresh cycle
```

- **Lazy.** The first command connects. Callers never manage sockets.
- **One cycle at a time.** Every caller waiting for a connection awaits the same task, so ten callers still mean one cycle.
- **3 retries:** 4 attempts with delays of about 0.5 s, 1 s and 2 s, each ±20% jitter. Backoff gives launchd time to restart a crashed helper. Jitter stops several clients from reconnecting at the same moment.
- **Retry on demand.** After `failed`, nothing runs in the background. The next command, or a Retry button calling `connect()`, starts a fresh cycle.
- **The UI learns everything** from `stateUpdates()`, and `BridgeError.userMessage` gives it text to show.

### Retryable or not

| Error | Typical cause | Retried? |
|---|---|---|
| `helperUnavailable` | `ENOENT`: no socket file (agent session not logged in, helper not started). `ECONNREFUSED`: stale file, helper restarting. | yes |
| `handshakeFailed`, `connectionLost`, `timedOut` | Helper crashed or hung mid-exchange | yes |
| `unauthorized` | Our UID isn't on the helper's allow list, or `EACCES` on the socket | no |
| `versionMismatch` | App and helper built from different protocol versions | no |
| `invalidConfiguration` | Socket path over 104 bytes | no |
| `helperFailure(permissionDenied)` | Screen Recording not granted in the agent session | no, the message says what to enable |

Retrying an error that can't fix itself only makes the user wait about 4 seconds longer for the same message.

## Heartbeat

While connected, the client sends `ping` every 5 s. Two unanswered pings in a row (2 s timeout each) count as a dead connection: the client closes the socket and reconnects. This catches a helper that is hung while its socket stays open. A plain socket can't detect that, because the kernel keeps the connection alive.

## Replay after a drop

If the connection drops while a request is in flight:

- **Replayable** requests (read-only: `ping`, `info`, `capture`, `inspect`, `elements`) wait for the automatic reconnect and are sent once more.
- **Non-replayable** requests fail with `.interrupted`. `openApp` and every input action are in this group. The first copy may already have run before the drop, and replaying it could press a button twice. The executor decides what to do, for example take a screenshot and check.

Set this per command in `HelperRequest.isReplayable`.

## Security

- The socket file is `0666`, but every connection is checked with `getpeereid`, which returns the UID the kernel recorded for the connecting process and can't be faked by the client. Only the main user's UID (from `--allow-uid` / `ZOOP_ALLOWED_UIDS`) and the helper's own UID are accepted.
- The installed app bundle is owned by root, so the agent user can't change the code it runs.
- A stale socket file is removed at startup only if it is a socket and nothing answers on it. The helper never deletes a regular file, and never replaces a running helper.

## Running it

```bash
# once: use the full Xcode toolchain (Command Line Tools lack the Swift Testing macros)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

swift test                                    # unit + end-to-end bridge tests
Scripts/bundle-helper.sh                      # build/ZoopHelper.app + build/zoop-bridge
sudo Scripts/install-helper.sh sbagent        # install/restart the helper in sbagent's session

build/zoop-bridge status                      # connect, show session + permissions
build/zoop-bridge ping -n 5
build/zoop-bridge capture --max-width 1280    # saves frames/frame-<ms>.png
build/zoop-bridge watch                       # live state; restart the helper to watch it reconnect
cat /Users/Shared/Zoop/run/helper.log
```

To see the retry path, stop the helper (`sudo launchctl bootout gui/$(id -u sbagent)/com.zoop.helper`) and run `build/zoop-bridge status`.

The first time it runs in `sbagent`'s session, approve **Screen & System Audio Recording**, **Accessibility**, and **Send input events (PostEvent)** for ZoopHelper there. Permissions are per user and tied to the signature, which is why `bundle-helper.sh` signs with the "SessionBridge Dev" certificate.


## Input spike

```bash
build/zoop-bridge inspect 300 200
build/zoop-bridge elements com.apple.calculator --all --limit 300
build/zoop-bridge open com.apple.calculator --verify
build/zoop-bridge click 300 200 --verify
build/zoop-bridge click 300 200 --right --verify
build/zoop-bridge click 300 200 --double --verify
build/zoop-bridge type 'hello from Zoop' --verify
build/zoop-bridge set-text 'replacement' --at 300 200 --verify
build/zoop-bridge key cmd+a --verify
build/zoop-bridge scroll 300 200 --dy 5 --dx 0 --verify
```

Substitute coordinates from the agent's element tree or screenshot; these examples are placeholders. Quote text as one argument. Shell `$'line one\nline two\tend'` supplies actual Return/Tab characters. Use `--` before literal text that looks like an option, for example `type --verify -- '--help'`.

Clicks hit-test with AX and walk up at most five ancestors. Single clicks use AXPress or focus writable text controls; right clicks use AXShowMenu and double clicks use AXOpen when advertised. Focus requests also try window-main and app-frontmost attributes inside the agent session. Once an AX action is attempted, its result is returned even on error; there is no event fallback that could click twice. If no AX strategy is available, mouse events go to the PID of a containing CG window, with both window-number fields set. When AX hit-testing identifies an owner, window selection is constrained to that PID so a screen-sized transparent window from another app cannot capture the event. Selection preserves front-to-back order within the matching app and fails if no matching containing window exists. Without an AX hit, including when Accessibility is missing, clicks use the window-list fallback with PostEvent permission.

`type` and `key` use the system-wide AX focused element to find a PID. They require Accessibility and PostEvent. Typing sends a unicode key pair for each character, maps newline/Tab to real keys, and reads AXValue before and after. When a readable selection and the resulting value prove the exact insertion, `landed` is true. Otherwise it is unknown. `set-text` uses AXValue directly, requires Accessibility, and reports whether readback matches. Neither typing path falls back to the other. Scroll uses a PID-targeted wheel event and the same AX-owner-aware window selection as mouse-event fallback; positive deltas mean down/right. Scroll reports include the hit element when AX finds one.

The helper uses only `postToPid` for events, including while on console. It contains no HID injection path. Input and app launching share a gate so they cannot overlap across clients, including while an app launch suspends. AX reads have a 2 s [AX messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout) and retry a read once on `apiDisabled`; writes/actions are never retried. Tree queries return up to 1,000 results, scan at most 2,000 nodes and stop starting new nodes after 7 s. Individual AX calls can extend that elapsed time. Query results may therefore be partial.

Every input action returns its method, target when available, PID/app, optional raw AXError, optional `landed`, and detail. An AX success means the request was accepted, not proof of the visual result. PID mouse/key/scroll delivery remains unknown without readback; use the next screenshot. Optional fields are omitted from JSON when unknown. A request timeout or interrupted connection does not cancel a queued or running action; inspect the result before sending another action.

`--verify` observes the CLI's console session and refuses to run against the same user or an on-console helper. It samples the cursor and frontmost PID about every 2 ms and compares session keyDown and left/right/other mouseDown counters around the action plus a 200 ms settling period. A failed measurement exits nonzero, including when the action itself reports an error. Keep your own mouse and keyboard still during this measurement: your input also changes these counters. Sampling is evidence, not a guarantee that every transient event was observable. It does not prove that input landed in the agent app.

See [InputFindings.md](InputFindings.md) for the real-session procedure and pending results.
