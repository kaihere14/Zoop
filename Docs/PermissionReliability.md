# Permission and dialog reliability on macOS

ZoopHelper now uses [Vercel Labs agent-desktop](https://github.com/vercel-labs/agent-desktop) for dialog button delivery when bundled or installed. Detection and human approval remain in Zoop's session bridge. This integration handles the exact permission or app-dialog choice the person selected; it does not expose unrestricted desktop tools to the model.

## What was causing intermittent failures

These are findings from the code and existing session notes, not a diagnosis of a particular live failure log:

| Problem | Effect | Change |
| --- | --- | --- |
| The helper checked dismissal five times, 100 ms apart. | A working button could be reported as unconfirmed if dismissal took longer than half a second. | Observe dismissal for up to four seconds without repeating the click. |
| Accessibility child-read failures became empty child lists. | A busy app could make a nested dialog appear absent. | Dismissal traversal preserves unreadable or truncated child lists as unknown. |
| `consent_pending` caused another task attempt even when no permission was answered. | A late or undetected prompt could trigger another request while consent was pending. | Poll for a human answer; leave the task paused if none was answered. |
| Only one post-consent task retry was supported. | Saving could request Automation, then Documents access, and still end as pending after both were approved. | Resolve up to four consent prerequisites. Only `consent_pending`, which means the task action did not run, permits another attempt. |
| App-dialog query errors were discarded with `try?`. | A bridge/permission failure looked like there was no dialog, allowing input to continue. | Propagate the error and stop input. |
| The original click used one AXPress without agent-desktop's actionability checks. | A changing or temporarily unavailable control could reject delivery. | Match a fresh qualified ref, revalidate the human-reviewed dialog, and check the live target before semantic delivery. |

There are also platform and setup constraints:

- System consent often belongs to another process. Maps location consent, for example, belongs to `CoreLocationAgent`; scanning only Maps misses it. Zoop scans a fixed set of known system hosts. Unknown hosts, password dialogs, and trees exceeding its time/node limits still need direct review.
- Save panels can have fields hosted in another process. Prior session testing found that synthetic keystrokes missed those fields and AX value writes could leave Save disabled. `save_document` remains the alternative for scriptable apps; a button library does not fix every file-panel field.
- Accessibility, Automation, Screen Recording, and Files & Folders are separate permissions. Grants must exist for the responsible processes in the **agent user's GUI session**. A grant to Terminal in the main session does not establish access for ZoopHelper or its child in another session.
- Ad-hoc signing changes code identity on rebuild and can invalidate privacy grants. `bundle-helper.sh` uses the configured stable signing certificate when available, including for nested executables.
- An accepted AX action does not prove task completion. Protected controls can reject synthetic interaction. Closing consent does not independently prove a grant; closing a Save sheet does not prove a file was written.

See [prior input findings](InputFindings.md), [session bridge notes](SessionBridge.md), and [agent-desktop's macOS requirements](https://agent-browser.dev/desktop/platforms/macos).

## How the integration works

1. Zoop detects a dialog and presents its actual text, enabled states, and opaque choice IDs to the person.
2. Inside the agent session, the helper takes an agent-desktop snapshot of the owning app's sheet, alert, or window. When available, the exact CoreGraphics window ID scopes the read. An unsupported overlay search can widen to a window **read**.
3. A complete snapshot must uniquely match the reviewed button's label and bounds, plus its native identifier when present. The app name must identify the original process. Missing, disabled, ambiguous, and truncated targets stop without a click.
4. After the external read, the helper rescans the original dialog and verifies both the choice token and native button. A changed request returns to human review.
5. The helper consumes the token and sends one headless `agent-desktop click` with a snapshot-qualified reference. It never switches to physical input or sends a fallback AXPress after starting that click.
6. An AX read must observe dismissal before `landed` becomes true. Read failures remain unknown. Failed or uncertain delivery is not automatically repeated; only a proven undelivered stale reference returns to human review.

Subprocesses have bounded output, an eight-second deadline per command, cancellation handling, and no shell interpolation. A separate 35-second bridge response budget accommodates snapshot, revalidation, delivery, and dismissal. The wire protocol and `axPress` report method are unchanged; details identify the actual backend and delivery disposition.

## Install and verify on a Mac

```bash
bash Scripts/bundle-helper.sh
sudo bash Scripts/install-helper.sh sbagent
swift test
```

Bundling downloads the pinned **agent-desktop 1.1.0** native release for the Mac's architecture, checks its published SHA-256, validates archive contents, and includes both `agent-desktop` and its required `agent-desktop-macos-helper`, plus the Apache license. The installed session needs no Node runtime. The adapter expects JSON contract `2.6`.

Log into the agent user's GUI session. In System Settings > Privacy & Security > Accessibility, grant ZoopHelper access; if macOS lists agent-desktop or its helper separately, grant the listed process too. Screen Recording is still needed for ZoopHelper's preview. The startup log at `/Users/Shared/Zoop/run/helper.log` names the selected dialog backend. Permission-denied reports identify the CLI failure instead of silently trying another click.

For unbundled development, set `ZOOP_AGENT_DESKTOP_BIN` to the absolute path of the native macOS CLI in the **helper's** environment, with its upstream companion beside it. Setting it in the main app's shell does not configure an existing LaunchAgent. If no CLI is found, unbundled development retains native AXPress and logs that fact. The normal bundle includes the CLI automatically.

Manually verify Allow and Don't Allow on a system prompt; OK and Cancel on an app dialog; Automation followed by Documents consent on a save; a disabled Save button; a dialog replaced while its card is open; and a slowly dismissing dialog. Repeat with the agent session in the background and confirm the main user's cursor and focus stay unchanged. Unsupported or protected prompts must remain unconfirmed and report that direct interaction is needed.

Regression coverage includes ref matching, ambiguous/truncated/disabled targets, delivery disposition, subprocess cancellation, missing consent, sequential consent, unreadable dialog queries, and the bridge timeout. Live privacy/session behavior still needs these Mac checks; it cannot be verified from a Windows host.
