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
| `Sources/ZoopHelper/Server/SystemBackend.swift` | Real session info and capture. Tests use a fake. |
| `Sources/ZoopBridgeCLI/main.swift` | `zoop-bridge` developer tool. |

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

- **Replayable** requests (read-only: `ping`, `info`, `capture`) wait for the automatic reconnect and are sent once more.
- **Non-replayable** requests fail with `.interrupted`. Click and type will be in this group when they move over from the prototype. The first copy may already have run before the drop, and replaying it could press a button twice. The executor decides what to do, for example take a screenshot and check.

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

The first time it runs in `sbagent`'s session, approve **Screen & System Audio Recording** for ZoopHelper there. Permissions are per user and tied to the signature, which is why `bundle-helper.sh` signs with the "SessionBridge Dev" certificate.
