# Input spike: procedure and findings

Status: implementation and automated socket tests complete. Calculator app launching, AX inspection and AXPress digit/operator clicks passed in the real background session. The user confirmed TextEdit focus and basic unicode typing work; subsequent output establishes PID-targeted Cmd+A replacement and Return delivery with all isolation checks passing. Typed text was transformed by the app, so exact-text verification remains unknown. Point-targeted and focused-element AX text writing passed exact readback and isolation checks. The scroll window-selection fix passed live retesting, but PID wheel scrolling still produced no visible movement in TextEdit. Other shortcuts and PID mouse events remain pending. The final input API will be settled after these experiments.

## Setup

The client now speaks protocol v3 for the explicit AX page-scroll spike. Build and sign with `Scripts/bundle-helper.sh`, then run the install yourself in Warp; the installed v2 helper must be replaced before testing:

```bash
cd /Applications/Coding/Hackathon/Zoop
sudo Scripts/install-helper.sh sbagent
build/zoop-bridge status
```

Check that `on console` is **no**, the helper user is `sbagent`, and all three permissions are granted. Stay in your main user session for these experiments. If TCC needs reapproval, switch to sbagent, approve ZoopHelper, then switch back.

Every command that changes the agent session below uses `--verify`. Keep your hands off the mouse and keyboard from Return until the verification report prints. If any check fails, record it and stop further input experiments until the cause is understood. A failure may be your own input; do not call it a proven leak without reproducing it with hands still.

Read-only inspection and screenshots do not need `--verify`. `elements` emits one line per element, including role, quoted name/value, center point, actions and PID. `--all` includes result labels and other noninteractive elements. The list is bounded; raise `--limit` up to 1,000 if needed.

## Calculator: AX click and readback

```bash
build/zoop-bridge open com.apple.calculator --verify
build/zoop-bridge capture --max-width 1280
build/zoop-bridge elements com.apple.calculator --all
```

Find the center coordinates for clear, 7, +, 2 and = in that list. Run `build/zoop-bridge click X Y --verify` for each, substituting its coordinates. Re-list the elements and capture the screen to confirm that the result is 9. Record each report's method and AXError. AXPress may report an error even when the display changed; never resend solely because AXError is nonzero.

Use `build/zoop-bridge inspect X Y` if the innermost element is a label: the ancestor list should identify its actionable button. AX results alone do not test the PID mouse fallback.

## TextEdit: focus, typing, shortcuts and direct value writes

```bash
build/zoop-bridge open com.apple.TextEdit --verify
build/zoop-bridge elements com.apple.TextEdit --all
build/zoop-bridge capture --max-width 1280
```

If TextEdit opens a file chooser, inspect it and use AX clicks to choose New Document, each with `--verify`. If an empty app is running without a document, try `build/zoop-bridge key cmd+n --verify` only when AX inspection finds a focused element; record failure to find one as a spike result. Do not assume a document exists merely because the app launched.

Find the document text area's center. Substitute its coordinates below:

```bash
build/zoop-bridge click X Y --verify
build/zoop-bridge type 'hello from Zoop 🌍' --verify
build/zoop-bridge elements com.apple.TextEdit --all
build/zoop-bridge capture --max-width 1280
build/zoop-bridge key cmd+a --verify
build/zoop-bridge type 'replacement through keys' --verify
build/zoop-bridge set-text 'replacement through AX' --at X Y --verify
build/zoop-bridge elements com.apple.TextEdit --all
build/zoop-bridge capture --max-width 1280
```

Also try `set-text` without `--at` to test the focused-element path, and `type $'first line\nsecond line' --verify` for Return. A plain document may insert Tab; a form may move focus. Use screenshots and AX values to judge the effect of `key tab --verify` and `key return --verify`.

Record whether the focus click used `axFocus`, whether key typing changed AXValue, whether Cmd+A selected the document text, and whether set-text is supported. If typing stays unknown or unchanged after AX focus/window-main/app-frontmost requests, record that outcome; do not silently switch typing strategies.

## Scroll, right/double click and non-AppKit controls

Create a long document with `set-text` using a quoted multiline string (with `--verify`). Capture it, then run `scroll X Y --dy 8 --verify` over its body and capture again. A pidScroll report only confirms posting; compare visible text to establish movement. Repeat with `--dy -8` to test the reverse direction.

The PID wheel strategy produced identical frames in TextEdit after its target selection was corrected. The next explicit strategy is AX page scrolling, approved by the user and implemented in protocol v3. With the existing 80-line document, reinstall the rebuilt helper and test:

```bash
build/zoop-bridge key cmd+up --verify &&
build/zoop-bridge capture --max-width 1280 --out frames/page-before &&
build/zoop-bridge scroll-page 439 359 --direction down --verify &&
build/zoop-bridge capture --max-width 1280 --out frames/page-after
```

Expect axScrollPage targeting TextEdit's AXScrollArea and detail naming AXScrollDownByPage. The accepted count and AXError describe the AX call, not proof of viewport movement. Compare the captures, then test `scroll-page 439 359 --direction up --verify` followed by another capture. `--pages N` requests 1–10 pages, default 1. Stop on error without retry or wheel fallback. The old line-based `scroll` command remains available for comparisons.

Try `click X Y --right --verify` on the document and record whether AXShowMenu or pidMouse was used and whether a context menu appeared. Test double-click on an item that advertises AXOpen, or record the pidMouse fallback when no ancestor does. Check the resulting selection/open action visually.

A second round should use an existing browser's web content and a SwiftUI control, located with screenshots and `inspect`. Record whether events fall back to pidMouse/pidScroll, whether they affect the intended view, and whether all primary-session checks pass. Test Cmd+L in a browser with `key cmd+l --verify`, then inspect whether its address field gained focus. These cases are pending and may determine the final API.

## Results

| Case | Method / AXError | Agent-side evidence | Primary-session verification | Status |
|---|---|---|---|---|
| Calculator launch | NSWorkspace / n/a | Calculator pid 48720; helper uid 502, off console | Cursor drift 0.00 pt over 320 samples; frontmost pid unchanged; all input counter deltas 0 | Passed, 2026-10-31 |
| Calculator AX inspection | Read-only AX tree | Keypad buttons advertise AXPress; display AXStaticText value is `0` | Read-only command | Passed, 2026-10-31 |
| Calculator digit/operator clicks | axPress / 0 for all five presses | All Clear, 7, Add, 2, Equals; AX readback expression `7 + 2`, result `9` | All five checks passed: cursor drift 0.00 pt, frontmost pid 37857 unchanged, every key/mouse-down delta 0 | Passed, 2026-10-31 |
| TextEdit launch | NSWorkspace / n/a | TextEdit pid 50879; empty Untitled document with AXTextArea at (439, 359) | Cursor drift 0.00 pt over 333 samples; frontmost pid 37857 unchanged; all input counter deltas 0 | Passed, 2026-10-31 |
| TextEdit focus click | User confirmed; raw report not supplied | User confirmed the click-and-type sequence worked | Sequence included --verify; raw verification output not supplied | User-confirmed, 2026-10-31 |
| TextEdit basic unicode typing | User confirmed; raw report not supplied | Requested text: `hello from Zoop 🌍`; user reported working | Sequence included --verify; raw verification output not supplied | User-confirmed, 2026-10-31 |
| TextEdit newline typing | pidKeys / n/a | Requested `first line\nsecond line`; AX readback `first line\nSecond line`; Return delivered, exact text differed, landed omitted (unknown) | Cursor drift 0.00 pt over 227 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Delivery passed; exact-text mismatch, 2026-10-31 |
| TextEdit Cmd+A / replacement | pidKeys / n/a | Prior `Hello from Zoom 🌍` entirely replaced by the two-line text above | Cmd+A: cursor drift 0.00 pt over 104 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Passed, 2026-10-31 |
| TextEdit set-text at point | axSetValue / 0; landed true | Exact `zoop exact\nsecond line` confirmed by action readback, separate AX query and saved screenshot | Cursor drift 0.00 pt over 107 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Passed, 2026-10-31 |
| TextEdit set-text on focused element | axSetValue / 0; landed true | Exact 80-line value written without --at; before-scroll screenshot displays the numbered document | Cursor drift 0.00 pt over 112 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Passed, 2026-10-31 |
| TextEdit Cmd+Up | pidKeys / n/a | Before-scroll screenshot shows Line 001 at the top after posting Cmd+Up | Cursor drift 0.00 pt over 114 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Start-of-document viewport confirmed, 2026-10-31 |
| Initial long-document scroll | pidScroll / n/a; wrongly targeted Notification Center pid 39682, window 41825 | Before/after screenshots both show Line 001 at the top; no document movement | Cursor drift 0.00 pt over 104 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Wrong-app selection fixed |
| PID scroll after target-selection fix | pidScroll / n/a; TextEdit pid 50879, window 43591 | AX target is First Text View; before/after PNGs are byte-identical | Scroll: cursor drift 0.00 pt over 105 samples; primary frontmost pid 37857 unchanged; all input counter deltas 0 | Routing correct; no observed scrolling in this run |
| Explicit AX page scroll | axScrollPage; implementation ready | AXScrollArea advertises directional page actions; real execution not tested yet | — | Pending protocol v3 installation and real-session test |
| Right/double click | — | — | — | Pending |
| Browser/SwiftUI PID mouse and scroll | — | — | — | Pending |
| Browser Cmd+L | — | — | — | Pending |

The first real-session output was supplied by the user on 2026-10-31. All three helper permissions were granted. The brief missing-socket errors immediately after installation recovered on the third connection attempt. Calculator's `isActive: true` describes activation inside the agent session; the helper remained off console and the main user's frontmost app stayed unchanged.

The supplied element list gave these point coordinates: All Clear `(373, 596)`, 7 `(319, 650)`, Add `(481, 758)`, 2 `(373, 758)`, Equals `(481, 812)`. Re-inspect if the window moves. The user's follow-up ran that sequence with `--verify`: every report identified the intended Calculator AXButton in pid 48720, used axPress and returned AXError 0. Final AXStaticText values were `Last Expression = 7 + 2` and `Edit field = 9`. Cursor sampling counts were 131, 123, 109, 107 and 124; all five runs reported zero drift, unchanged primary frontmost PID and zero primary key/mouse-down deltas. This establishes AXPress delivery for those controls in this background-session run. PID mouse fallback remains untested.

TextEdit subsequently opened an empty Untitled document, with all launch isolation checks passing. After being given a sequence to click `(439, 359)`, type `hello from Zoop 🌍` with `--verify`, and read back AXTextArea, the user replied “yup working”. Record focus and basic typing as user-confirmed; the exact action methods, AX errors, landed field and isolation measurements for those initial input actions were not supplied.

The next supplied output shows `key cmd+a` followed by `type` with `first line\nsecond line`, both using pidKeys against TextEdit pid 50879 and its First Text View AXTextArea. The old value `Hello from Zoom 🌍` was replaced completely by `first line\nSecond line`, corroborated by a separate element query. All primary-session checks passed for both actions. This proves Cmd+A replacement and Return delivery in this run, while also exposing text transformations. Automatic text correction/capitalization is a plausible cause, but the relevant TextEdit settings have not been inspected. The initial requested `hello from Zoop 🌍` also differed from the later observed `Hello from Zoom 🌍`; intervening edits cannot be ruled out for that earlier change. The type report correctly omitted landed because readback did not match the exact expected string. Do not weaken exact-text verification to turn this into a true result; test direct AX writes separately.

The subsequent `set-text` at `(439, 359)` wrote `zoop exact\nsecond line` to the same TextEdit AXTextArea. The report used axSetValue, returned AXError 0 and landed true, and a separate AX query confirmed the exact string. All primary-session verification checks passed. Inspection of `frames/frame-1793441719642.png` also confirmed the two lowercase lines were rendered in the document. The capture was 1280x832 pixels for a 1470x956 point display, consistent with the CLI's reported pixel-to-point scale.

The focused-element variant then wrote 80 numbered lines with axSetValue, AXError 0 and landed true. Cmd+Up used pidKeys, and `frames/scroll-before/frame-1793441829337.png` shows Line 001 at the top. Both actions passed every isolation check. The following scroll at `(439, 359)` used pidScroll but selected com.apple.notificationcenterui pid 39682, window 41825. `frames/scroll-after/frame-1793441829674.png` shows the document unchanged. Isolation passed, but delivery to TextEdit was not tested by that attempt.

Read-only investigation hit-tested `(439, 359)` through AX and found TextEdit's First Text View, its AXScrollArea and its window, all pid 50879. Notification Center's AX tree also exposes a screen-sized window centered at `(735, 478)`. The old window selector chose the first containing CG window by rectangular bounds, so that window could win despite TextEdit being the actual AX hit. Both scroll and mouse-event fallback now constrain the CG window list to the AX-hit owner when available, preserving front-to-back order within that app. If no containing window for the AX owner exists, they return notFound rather than redirecting to another app. Without an AX hit, the existing window-list fallback remains. Regression tests cover the screen-sized overlay, a missing AX owner window, containment/order and the no-AX fallback.

The user's live retest after reinstalling targeted TextEdit pid 50879, window 43591 and First Text View, confirming the selection fix. Cmd+Up and scroll isolation checks passed (116 and 105 cursor samples respectively). Nevertheless, `frames/scroll-fixed-before/frame-1793442041336.png` and `frames/scroll-fixed-after/frame-1793442041675.png` have the identical SHA-256 `7e62963596b3dd8c200ddd7f93fb2ac58df03c067475ee5d5dbf6b3eabf725c4`. Thus correctly addressing the PID/window was insufficient for this line-wheel event to produce visible scrolling. The exact failure inside event delivery/handling has not been isolated. Do not claim all PID scrolling is impossible from this one strategy. The AXScrollArea advertises AXScrollUpByPage/AXScrollDownByPage, making an explicit AX page-scroll strategy a candidate for the next spike; pages must not silently replace the existing line-delta semantics.

A local construction-only diagnostic (no events posted) then created the same line-wheel event and a mouse-down event, set both mouse-window hint fields to 43591 and read them back before converting through NSEvent. They remained `43591/43591` on the mouse event but returned `0/0` on the scroll event. The converted scroll had deltaY -8 and windowNumber 0; the converted mouse also had windowNumber 0 in this diagnostic, so conversion alone does not establish how the remote app routes either event. The concrete finding is that these mouse-specific fields do not retain the requested window hints on the constructed wheel event. The report's window number describes the selected CG window, not proof that the wheel event carries an effective window association. This is a useful lead, not a proven complete explanation of TextEdit's handling. No input behavior was changed after this diagnostic; an explicit AX page-scroll experiment has been proposed for the user's design choice.

The output also exposed multiline custom AX action names splitting CLI element records. The CLI now JSON-quotes the action list so each element stays on one physical line. This changes only the developer tool; the helper does not need reinstalling for this formatting fix.

Automated checks cover protocol round trips, key parsing/mapping, pixel-to-point conversion, routing through real sockets, and a helper restart during a slow fake click. The restart test requires `interrupted(command: "click")` and exactly one backend execution. They do not exercise real AX apps, TCC or cross-session event delivery.
