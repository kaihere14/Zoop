# Zoop

> Hand it a task. Keep working.

Zoop is a native macOS AI companion. You give it a task in chat, and it does the work inside a **separate macOS user session** while you keep using your own desktop. A floating pixel companion and a notch dock show progress. Finished files arrive in a shared folder.

We build Zoop step by step. Implemented so far: the **session bridge** (step 2), covering `ZoopShared/Protocol`, `ZoopShared/Transport`, `ZoopHelper/Server` and screen capture. See [Docs/SessionBridge.md](Docs/SessionBridge.md). Folders that still hold only a `.gitkeep` come later.

---

## Architecture

```
┌───────────────────────── Main user session ─────────────────────────┐
│                                                                     │
│   ZoopApp  (Swift · SwiftUI · AppKit)                               │
│   ├── Floating pixel companion                                      │
│   ├── Notch dock (status, progress, Stop)                           │
│   ├── Chat panel + live preview (1–2 FPS)                           │
│   └── Notifications                                                 │
│                │                                                    │
│   ZoopAgents  (orchestration + abstraction layer)                   │
│   ├── run(.chat, task:)  ──► Chat agent (small model)               │
│   │                            └─ decides to delegate ─┐            │
│   └── run(.executor, task:) ◄──────────────────────────┘            │
│                                Executor agent (main model)          │
│                                └─ drives the helper ─┐              │
└──────────────────────────────────────────────────────┼──────────────┘
                                                       │ Unix socket
                                                       │ (/Users/Shared/Zoop/run/helper.sock)
┌──────────────────────── Agent user session ──────────┼──────────────┐
│                                                      ▼              │
│   ZoopHelper  (headless Swift daemon, LaunchAgent)                  │
│   ├── Screen capture (ScreenCaptureKit)                             │
│   ├── Mouse + keyboard input (Core Graphics events)                 │
│   ├── Accessibility tree inspection                                 │
│   ├── App / URL launching                                           │
│   ├── Shell commands (as the non-admin agent user)                  │
│   └── Shared-folder file writes                                     │
└─────────────────────────────────────────────────────────────────────┘

           Shared folder: /Users/Shared/Zoop/{run, tasks, artifacts}
```

### The three parts

1. **Core app (`ZoopApp`)** runs in the main user's session. It contains the floating window, the notch dock and the chat UI.
2. **Helper (`ZoopHelper`)** runs entirely inside the agent's session. It holds the capabilities that act on that session: screen, input, accessibility, apps, shell and files.
3. **Agent orchestration (`ZoopAgents`)**:
   - **Chat agent**: uses the small model. It talks with the user and interprets requests.
   - **Executor agent**: uses the main model. It controls the helper and runs commands in the agent session.
   - **Abstraction layer**: one simple entry point, such as `run(agent, task)`. Each agent can choose to delegate to a sub-agent. For example, the chat agent hands a task to the executor.

---

## Folder structure

```
Zoop/
├── README.md
├── .gitignore
├── .env.example                    # Config template (API key, model overrides, paths)
│
├── Sources/
│   ├── ZoopApp/                    # PART 1: native app, main user session
│   │   ├── App/                    # App entry point, app delegate, lifecycle, menu bar
│   │   ├── Companion/              # Floating pixel character window (NSPanel)
│   │   ├── NotchDock/              # Notch-anchored dock: status, progress, Stop
│   │   ├── Chat/                   # Chat panel UI + view model
│   │   ├── Preview/                # Live 1–2 FPS preview of the agent desktop
│   │   ├── Notifications/          # Task done / error / approval notifications
│   │   └── State/                  # Shared observable app state
│   │
│   ├── ZoopHelper/                 # PART 2: daemon, agent user session
│   │   ├── Server/                 # Socket listener, peer-UID check, command dispatch
│   │   ├── Permissions/            # Screen Recording + Accessibility checks
│   │   └── Capabilities/
│   │       ├── Screen/             # ScreenCaptureKit screenshots
│   │       ├── Input/              # Mouse/keyboard events, key map
│   │       ├── Accessibility/      # AX tree inspection
│   │       ├── Apps/               # Open apps and URLs
│   │       ├── Shell/              # Run commands as the agent user
│   │       └── Files/              # Writes into the shared folder
│   │
│   ├── ZoopAgents/                 # PART 3: agent orchestration
│   │   ├── Facade/                 # Abstraction layer: run(agent, task) / submit(...)
│   │   ├── Agents/
│   │   │   ├── Chat/               # Small model: conversation + intent
│   │   │   └── Executor/           # Main model: computer use via the helper
│   │   ├── Delegation/             # How one agent hands work to a sub-agent
│   │   ├── LLM/                    # Claude API client, model profiles
│   │   ├── Tools/                  # Tool definitions + the computer-use bridge
│   │   ├── Queue/                  # Task queue, states, cancellation
│   │   └── Events/                 # Event stream to the UI (progress, status)
│   │
│   ├── ZoopBridgeCLI/              # `zoop-bridge` dev tool: status, ping, info, capture, watch
│   │
│   └── ZoopShared/                 # Code linked by BOTH app and helper
│       ├── Protocol/               # Helper command/result types
│       ├── Transport/              # Unix socket + message framing, helper client
│       ├── SharedFolder/           # Shared-folder layout + atomic writes
│       └── Tasks/                  # Task record + status model
│
├── Resources/
│   ├── InfoPlists/                 # Info.plist for Zoop.app and ZoopHelper.app
│   └── LaunchAgents/               # LaunchAgent plist that starts the helper
│
├── Scripts/                        # Agent-user setup, app bundling, helper install
├── Docs/                           # Design notes, feasibility results
│
└── Tests/
    ├── ZoopSharedTests/
    ├── ZoopAgentsTests/
    └── ZoopHelperTests/
```

### Dependency rules

| Module        | May depend on            | Must not depend on      |
| ------------- | ------------------------ | ----------------------- |
| `ZoopShared`  | Foundation only          | AppKit, SwiftUI, agents |
| `ZoopHelper`  | `ZoopShared`             | `ZoopAgents`, `ZoopApp` |
| `ZoopAgents`  | `ZoopShared`             | `ZoopApp`, UI code      |
| `ZoopApp`     | `ZoopAgents`, `ZoopShared` | —                     |

The helper never contains AI logic. It only carries out commands. The agents never touch AppKit. This keeps each part testable on its own.

---

## Build plan (step by step)

| Step | Milestone                 | Done when                                                                         |
| ---- | ------------------------- | --------------------------------------------------------------------------------- |
| 1    | Session isolation         | A helper in the agent session captures its screen and clicks without moving your cursor |
| 2    | Session bridge            | The app sends a command over the socket and gets a screenshot back               |
| 3    | Shared-folder handoff     | Both users read and write `/Users/Shared/Zoop` safely                             |
| 4    | Agents + queue            | Submit a task, the executor runs it, a result comes back                          |
| 5    | Observation + automation  | A real task completes: navigate a site, fill a form, verify the result            |
| 6    | Companion UI              | Companion, notch dock, chat, preview, notifications and Stop, all working end to end |

Step 1 is the riskiest. We need to prove that input reaches a background session before we build anything on top of it.

---

## Tech stack

- **Language:** Swift (Swift Package Manager)
- **UI:** SwiftUI + AppKit (`NSPanel` for floating and notch windows)
- **Screen:** ScreenCaptureKit
- **Input:** Core Graphics events, Accessibility API
- **IPC:** Unix domain socket in the shared folder
- **AI:** Claude API. Chat uses a small model and the executor uses a stronger computer-use model. Models are set in config.
- **Requirements:** macOS 27+, Xcode 27 (Swift 6.4). Select Xcode with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, because Command Line Tools alone can't build the Swift Testing tests.

## Build and test

```bash
swift build                              # all targets
swift test                               # unit + end-to-end session bridge tests
Scripts/bundle-helper.sh                 # build/ZoopHelper.app (signed) + build/zoop-bridge
sudo Scripts/install-helper.sh sbagent   # install the helper as sbagent's LaunchAgent
build/zoop-bridge status                 # talk to it from your own account
```

## Configuration

Copy `.env.example` and fill in your values. **Never commit API keys**; `.gitignore` already excludes `.env*` (except the example) and `config.local.json`.
