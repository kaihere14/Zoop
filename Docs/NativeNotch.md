# Native notch companion

The approved web interaction is implemented natively in `Sources/ZoopApp`. The application uses Swift 6, SwiftUI, and a borderless AppKit `NSPanel`. It has no web view, Electron runtime, or third-party Swift dependencies.

## Run on a Mac

Requirements: the repository’s macOS 27+ / Xcode 27 toolchain (Swift 6.4; the package manifest requires Swift tools 6.2 or newer). Run these commands from the repository root:

```sh
swift build
swift test
swift run Zoop
```

Zoop starts collapsed at the top center of the built-in notched display. If no notched display is attached, it uses the main display and draws a camera-shaped center. Click the companion or the sparkle menu-bar icon to expand it. A right-click on the menu-bar icon opens app options.

To produce a local application bundle:

```sh
./Scripts/bundle.sh
open build/Zoop.app
```

The script makes a release build and applies an ad-hoc signature for local use. Distribution signing and notarization are separate work.

## Interactions

- Idle and completed states say **idling**. The pixel mascot has closed eyes, a gentle breathing animation, and a floating pixel Z. The busy orb is absent.
- While preparing or executing work, a single consistent searching globe appears beside changing status words. Word changes use a scoped blur, fade, and spring transition.
- The glass surface changes dimensions independently of the conversation. Text is never scaled with the drawer.
- Opening chat, including reopening an existing conversation, starts at the latest message. Scrolling upward lets you read history without streaming constantly pulling you downward.
- Replies and plan steps stream progressively. **Start Process** appears only after the plan has finished streaming. Task state rejects execution until that explicit approval.
- Approval dispatches a paper ticket from the actual button bounds to **Live Activities**, plays the synthesized 880–1320 Hz chime, and pulses the counter when the ticket arrives. Closing during flight does not lose an approved task.
- Live Activities supports concurrent tasks, selection, pause, resume, and stop. Completed tabs show a checkmark briefly and animate away; historical completed tasks do not accumulate in the tab strip.
- The ghost pointer is drawn within the simulated browser and never controls the Mac’s mouse.
- Clicking outside or pressing Escape collapses Zoop. Unsent drafts and task progress remain in memory. **⌘ K** focuses chat while the panel has keyboard focus.
- Chat, full response sources, tasks, and the sound preference are persisted. Executing tasks restore as **paused**, and resume only when requested.
- Sample reports are saved to `~/Zoop/exports/` with unique filenames. **Save report** opens the standard save dialog. If automatic export fails, the report remains available for manual saving.

Reduced Motion disables mascot motion and orb animation, and simplifies word and tab transitions. The native controls have accessibility labels, and selectable chat text supports standard copy and paste.

## Source map

| Folder | Responsibility |
| --- | --- |
| `Sources/ZoopApp/App` | Entry point, app lifecycle, menu-bar icon, edit menu, app options |
| `Sources/ZoopApp/NotchDock` | Screen metrics, floating panel, outside-click/key monitors, glass, drawer, status and ticket animation, live activities |
| `Sources/ZoopApp/Companion` | Native Canvas pixel mascot and one searching-globe renderer |
| `Sources/ZoopApp/Chat` | Conversation, progressive plan, confirmation, input, scroll behavior |
| `Sources/ZoopApp/Preview` | Simulated browser, comparison table, autonomous ghost pointer |
| `Sources/ZoopApp/State` | Observable UI state, streaming, task lifecycle, persistence |
| `Sources/ZoopApp/Notifications` | Audio synthesis and file exports |
| `Sources/ZoopShared/Tasks` | Foundation-only Codable/Sendable messages, tasks, snapshots, and task transitions |
| `Sources/ZoopAgents/Facade` | Provider boundary and local demo service |
| `Sources/ZoopAgents/Agents/Chat` | Sample scenarios and Markdown report generation |

The panel uses actual `NSScreen` safe-area and auxiliary top-area measurements. It updates its frame when displays change. Its real window bounds shrink when collapsed, and it only becomes key when the user expands it. Background task progress does not activate or raise another app. The optional **Float above full-screen apps** setting switches from `.statusBar` to `.screenSaver` level.

## Current execution scope

This is a functional **native UI preview**. `DemoCompanionService` prepares deterministic plans and advances sample progress. The desk, listings, prices, and research are illustrative, clearly identified in the UI and exported reports. The UI is not yet connected to a model API, real browser automation, or the repository’s session helper. The persistent helper/session bridge is implemented separately and documented in [SessionBridge.md](SessionBridge.md).

To connect a real agent later, implement `CompanionService` and extend the execution event boundary. Keep desktop-session creation and input/capture capabilities in `ZoopHelper`; keep AppKit and SwiftUI in `ZoopApp`. Do not replace the explicit approval transition with automatic execution.

## Validation

The implementation was written on a Linux host without Xcode or the Swift compiler. Swift source syntax, the bundle plist, shell syntax, and whitespace were checked locally. These checks do **not** establish that the app compiles or renders correctly on macOS.

The included `Native Swift UI` GitHub Actions workflow builds, tests, and bundles on macOS after the changes are pushed, or when manually dispatched. Its results have not been run from this workspace. Run `swift build` and `swift test` on a Mac before treating the native implementation as verified.

Tests cover approval gating, dispatch arrival, pause/resume, cancellation, terminal completion, safe restoration, scenario selection, refinement context, unique export names, and report disclosure.

Manual Mac checks:

1. Launch on a notched Mac and on an external display. Check top alignment, camera clearance, sharp text, and transparent rounded corners.
2. Expand, type, close by clicking another app, and reopen. Confirm the draft and latest chat remain visible.
3. Approve a plan, close during the ticket flight, and verify the task still appears in Live Activities.
4. Run two tasks. Pause one, stop one, and verify neither advances while paused/stopped. Resume a task restored after relaunch.
5. Let a task complete. Confirm its tab retires, the counter decreases, the mascot sleeps, and the report is present in Finder.
6. Verify normal typing, clicking, app switching, Spaces, and full-screen behavior while a task runs.
7. Test Reduced Motion, VoiceOver labels, sound toggling, and a save location that is not writable.

Apple references: [NSPanel](https://developer.apple.com/documentation/appkit/nspanel), [notch-aware screen geometry](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc), [NSHostingView sizing](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions), [scroll geometry](https://developer.apple.com/documentation/swiftui/scrollgeometry).
