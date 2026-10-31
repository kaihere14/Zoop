# Input findings

Summary of the input spike run on 2026-10-31 in `sbagent`'s session while it was in the background (not on console), on macOS 27.2. Helper protocol versions 2–4 were tested. The results decided the tool set in protocol v5 and [the agent tools](AgentTools.md).

## What works

| Capability | Method | Tested in | Evidence |
|---|---|---|---|
| Launch or bring forward an app | NSWorkspace | Calculator, TextEdit, Safari, System Settings | App pid returned; window visible in the next screenshot |
| Press controls | AXPress | Calculator keypad, Safari links, System Settings sidebar, TextEdit window buttons | Calculator `7 + 2 =` read back `9`; link opened its page; sidebar opened the Appearance pane |
| Focus a text field | AX focus, or AXPress on web fields | TextEdit document, Safari/Wikipedia search field | Focus confirmed by AX; caret visible |
| Context menu | AXShowMenu | TextEdit document | Menu opened; `escape` closed it |
| Type text | Unicode key events posted to the app's pid | TextEdit, Safari address bar | Exact URL read back from AXValue; `\n` pressed Return and loaded the page |
| Keys and shortcuts | Key events posted to the app's pid | TextEdit Cmd+A, Cmd+Up, Page Down/Up, Escape; Safari Cmd+L | Cmd+A replaced the selection; Page Down moved the scroll bar 0 → 0.542; Cmd+L focused Safari's address field |
| Set exact text | AXValue write | TextEdit (focused element and element at a point) | Read back exactly, including newlines |
| Scroll to a position | Scroll bar AXValue write | TextEdit document, Safari web page, System Settings sidebar | Read back within 0.0001 of the request; screenshots showed the expected content |
| Read state | AX tree queries | Calculator display, element lists of every app above | Values and element centers matched the screenshots |

## What does not work

These were removed from the helper in protocol v5.

| Approach | Result |
|---|---|
| Mouse events posted to the app's pid | Ignored in TextEdit and Safari. A double click selected nothing. Apps in a background session do not act on synthetic mouse events. |
| Mouse-wheel events posted to the app's pid | Ignored in TextEdit, Safari and System Settings, even when sent to the correct window. |
| AX page-scroll actions (`AXScrollDownByPage`) | TextEdit's scroll area advertised them but returned -25205 (`kAXErrorAttributeUnsupported`). |

Not possible with the remaining methods: double click on elements without AXOpen (for example selecting a word), drag and drop, and hover.

## Things the agent must know

These are part of the operating guide in `SessionTools.guide`.

- An AX success means the app accepted the request, not that it had the intended effect. Use readback (`verified`) or a screenshot.
- An advertised AX action is not proof that the action works (see the page-scroll result).
- Typed text can be changed by the app: `first line\nsecond line` became `first line\nSecond line` in TextEdit. Use `set_text` when the exact value matters.
- AXShowMenu opens the menu at the element's caret, not at the clicked point, and about a second after the call: a screenshot taken immediately showed no menu.
- After a page navigation, Safari reported no system-wide focused element, even with a caret in a field. `type_text` and `press_key` now ask the focused or frontmost app instead, and `press_key` can target the app itself.
- Web content nests deeply. `scroll_to` searches up to 30 containers for the scroll area; clicks search up to 6 elements.
- Overlay scroll bars cannot be hit-tested. The helper reaches them through the scroll area's `AXVerticalScrollBar` and `AXHorizontalScrollBar` attributes.
- A newly opened app needs a moment before its window can be used. Take a screenshot first.
- WebKit builds its accessibility tree lazily. Right after a page load, hit-testing Safari's web content failed with -25208 (`kAXErrorNotImplemented`) until something walked the tree. The helper now walks part of the tree of the app under the point and retries once.
- Safari applies a scroll position asynchronously: a readback after 50 ms still showed the old position although the page moved. `scroll_to` now polls the readback for up to 0.5 s before reporting `verified: false`.

## Isolation

The helper posts events only to a target app's pid and has no HID-level injection path, so nothing it does reaches the main user's session. While the main user kept still, early runs measured this around every kind of action: their cursor did not move, their frontmost app did not change, and their session's key-down and mouse-down counters did not increase. That measurement (`--verify`) was then removed: Zoop is meant to run while the person keeps working, and their own activity made the checks fail for reasons unrelated to the helper.

## Not tested yet

- Checkboxes, pop-up buttons, tabs, sheets and file dialogs.
- Double click on items that advertise AXOpen.
- Chromium and Electron apps, and browsers other than Safari.
- `set_text` on web forms whose page script keeps its own state.
- More than one display.
- Long runs: many actions in a row, helper restarts in the middle of a task.
