# Native notch: base version

The native app now connects the notch to chat, planning and the session helper. It runs one task at a time:

1. Chat normally with the chat model. Normal replies do not touch the helper.
2. When the chat model calls plan_task, the planner observes the agent session read-only and proposes an executable plan.
3. Review the readable steps. Expand **Plan details** to inspect the tool calls.
4. Click **Execute the plan**. Until that click, no task actions run.
5. The Swift runner executes known calls directly. The executor model handles decision points, repairs and final verification.
6. Live Activities shows real progress notes and the latest observed screenshot. The actual summary/report returns to chat and is saved under `~/Zoop/exports/`.

New requests are disabled while a task is dispatching or executing. There is no task queue or pause/resume/stop interface in this base version. Missing model/session setup produces an error instead of simulated work. Desktop observations occur at agent checkpoints; this is not a continuous video stream.

## Configure and run

Use the repository's macOS 27+/Xcode 27 toolchain. The app reads `~/.zoop/config.json` (or `ZOOP_CONFIG`). Finder-launched apps do not inherit settings exported in a separate terminal, so use the config file for the built app:

```json
{
  "agents": {
    "chat": {"provider": "gemini", "model": "<chat model with tool calling>"},
    "planner": {"provider": "gemini", "model": "<stronger model with tools and image input>"},
    "executor": {"provider": "gemini", "model": "<execution model with tools and image input>"}
  },
  "providers": {
    "gemini": {"apiKey": "<your key>"}
  }
}
```

Use actual model identifiers your provider offers. Other supported providers and configuration precedence are documented in [AgentLayer.md](AgentLayer.md). Keep credentials outside the repository and protect the configuration file with `chmod 600 ~/.zoop/config.json`.

```sh
build/zoop-bridge status   # helper must be reachable with its permissions granted
swift run zoop-agent config
swift test
Scripts/bundle.sh          # builds and ad-hoc signs build/Zoop.app
open build/Zoop.app
```

The helper retains its separate certificate-signed bundle and LaunchAgent installation described in [SessionBridge.md](SessionBridge.md). UI/agent changes do not require reinstalling the helper unless its protocol/capabilities also change.

## UI behavior

The existing notch shape, mascot, expansion animation, plan streaming presentation, approval ticket animation, completion sound and result card remain. Chat smoothly follows new messages, streamed text and growing plan cards while at the bottom. Scrolling up manually pauses follow mode; returning to the bottom resumes it. Content growth and programmatic scroll animations do not turn follow mode off, and Reduce Motion disables the scroll animation. Clicking outside or pressing Escape collapses the notch while execution continues. Expand it to read progress or answer an executor question. Additional approvals or questions appear inside Live Activities and wait for your answer; declining does not imply approval.

The base version uses actual outcomes to mark completion. Progress estimates are capped below 100 until a successful outcome arrives. Failed tasks display the failure and do not export a fabricated report. **Save result** saves the agent's Markdown report, or its actual summary when no report was requested.

Chat, plans, task outcomes and sound preference are persisted. Old UI-preview snapshots remain readable. The first subsequent save preserves the previous state as `companion-state.pre-live.json` beside `companion-state.json` in Application Support/Zoop. Keep this backup if rolling back to the preview build. Tasks interrupted by quitting are marked failed after relaunch and require a new request; the app never restarts the original action sequence automatically. Screenshots and pending user answers are not persisted.

## Code map

- `ZoopAgents/Agents/Chat/ChatAgent.swift`: conversation and plan_task handoff; no desktop tools.
- `ZoopAgents/Agents/Planner/`: read-only planner and approved plan execution/repair.
- `ZoopAgents/Facade/CompanionService.swift`: chat → planner and explicit execution entry points.
- `ZoopShared/Tasks/TaskPlan.swift`: Codable executable plan shared with UI persistence.
- `ZoopApp/State/CompanionStore.swift`: one-task gate, button approval, events and actual results.
- `ZoopApp/State/CompanionPrompter.swift`: in-app questions and cancellation-safe answers.
- `ZoopApp/Chat/ChatView.swift`: conversation, plan details and Execute the plan.
- `ZoopApp/NotchDock/LiveActivitiesView.swift`: real screenshots, progress, questions and results.

The older simulated desk and sample research fixtures remain in source for reference/tests; the live app does not select them.

## Validation

Automated tests cover ordinary chat without helper use, concrete-task planning without execution, rejecting chat-side desktop calls, explicit button approval, a second task blocked during execution, progress versus completion, real report exports, failure states, snapshot compatibility/backup, interrupted-task restoration and answering/cancelling in-app questions. Planner, runner, transport and model adapter tests also run with the same package.

The native executable and application bundle are built on the project's macOS toolchain. Live model/provider use and visual acceptance on the user's configured desktop remain manual checks. A quick manual check is: greet Zoop, request a Calculator calculation, inspect the plan, click Execute the plan, watch the observed screen and read the returned result. Verify that no task actions occur before approval and no new request can start until it finishes.

## Approval modes, questions and retries

Each plan card has a mode picker next to Execute the plan. **Ask first** (the default for every new plan) stops before each step the planner marked as risky and lets the executor ask before anything hard to undo. **Auto** treats every action the plan lists as approved: planned confirmations are skipped and the executor is told not to ask about them. It still asks before a hard-to-undo action the plan does not list (a different recipient, an extra purchase, anything a web page asks for), and still asks for information only the person has. It never types passwords, payment details or one-time codes.

Questions use `ask_user` with a `kind`: `confirm` shows Allow and Deny, `info` shows a reply field. While the notch is closed, each question is also posted as a macOS notification with the same choices (Reply opens a text field). Clicking the notification opens the question in the notch; answering in either place removes the notification. macOS asks for notification permission the first time.

When an action fails, the executor must find out why and try a different method. After 3 failed actions in a row (a successful action resets the count) further actions are refused and it must call `finish_task` with `success: false`, what it tried and `next_step`; the suggested next step is shown with the result. If it keeps trying to act, the run stops with the list of failed attempts.

## System permission cards

During a live task, recognized macOS consent dialogs pause desktop tools and show a permission card. The message identifies the requesting app using the system's own text; buttons retain the exact labels, including distinctions such as Allow Once versus Always Allow. If the notch is closed, the notification carries the same choices (up to four; open the notch for all choices).

The selected choice goes directly to the session helper, without asking the executor model to interpret approval or find coordinates. The helper revalidates the request, attempts the button once, and checks dismissal. Auto mode never supplies consent. “Leave unchanged and end task” dismisses the Zoop card without touching the system prompt. If the dialog changed, it must be reviewed again. If macOS refuses the press, the task reports that direct interaction is needed. This version handles known system dialog hosts, not arbitrary web-page prompts, protected authentication screens, or a general remote-control surface.

## Expanded session preview

The expand icon beside the task title in Agent workspace opens one separate floating preview window. It starts centered on the screen containing the pointer at about half the screen's available width and height. Drag the standard title bar to move it and any edge or corner to resize its width and height independently. Closing it leaves the task running; reopening reuses its last size and position during the app session. The zoom/full-screen button is hidden.

The window observes the same task-scoped screenshots as the notch, so updates arrive when the agent observes its workspace. It does not add continuous capture or remote input. The screenshot scales to fit without distortion, and a removed/reset task cannot display another task's screenshot. Closing the notch does not close the floating preview.

## Help with a stuck app dialog

For ordinary in-app sheets (Save/Cancel, notification onboarding, Continue), the executor first tries Accessibility and then a screenshot-based mouse click. If both fail, `request_dialog_help` opens the same human-choice card and notification used for system permissions, labelled with the app's name and its exact observed choices. Save cards include current field values such as the filename. Longer cards scroll so all offered choices remain reachable. The runtime does not let the model use this as its first click strategy.

After a user chooses a button, the helper validates the current dialog and performs the exact button once. A screenshot checkpoint follows before later actions or task completion. Cancel and Don't Save must be respected, and closing a Save sheet must not be reported as proof that the intended file exists. Missing controls, stale dialogs, unreadable trees and unconfirmed presses fail without an automatic second press. Native execution and CLI execution share this path; the CLI asks for an exact label or choice number rather than posting a notification.
