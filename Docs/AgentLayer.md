# Agent layer

The agent layer (`Sources/ZoopAgents`) is Zoop's brain. It decides what to do and drives the helper through the tools in [AgentTools.md](AgentTools.md). It does not depend on any one AI provider: agents talk to a small `ChatModel` interface, and the configuration chooses the provider and model.

```
ExecutorAgent ──ModelRequest──▶ ChatModel (OpenAICompatibleModel) ──HTTP──▶ Gemini / OpenRouter / Groq / OpenAI / Ollama …
      │
      ├─ tool calls ──▶ SessionToolbox ──socket──▶ ZoopHelper (agent session)
      ├─ ask_user ────▶ UserPrompting (terminal now, UI later)
      └─ AgentEvent ──▶ progress for the UI or CLI
```

Status: the model layer, grounded planner, direct plan runner and free-form executor are built and tested with scripted models. The CLI can propose a plan for approval, run known tool calls without a model, and ask the executor model to repair or decide. Normal chat and the single-task native approval/result flow are connected through LiveCompanionService; see [NativeNotch.md](NativeNotch.md).

First live run (2026-10-31, Gemini `gemini-3.5-flash` through the OpenAI-compatible endpoint): "Open Calculator and compute 12 × 34" completed in 17 model calls. The executor checked the session, took a screenshot, opened Calculator, read the buttons with `list_elements`, pressed AC 1 2 × 3 4 = with Accessibility, confirmed `408` in a screenshot and finished with a summary. It used 132,506 input and 389 output tokens, because it sent one click per model call and every call resends the conversation. Asking for several tool calls per response did not change this, so two tools were added: `batch` (several actions in one call, checked first, stopped at the first failure) and clicks by element name (`bundle_id` + `element`), so the model no longer copies coordinates.

| Run | Model | Model calls | Input tokens | Result |
|---|---|---|---|---|
| 12 × 34, one action per call | `gemini-3.5-flash` | 17 | 132,506 | 408, correct |
| 56 × 78, coordinates only | `gemini-3.5-flash-lite` | 25 (limit) | 200,875 | Failed: pressed wrong keys (57×92) |
| 56 × 78, `batch` + clicks by name | `gemini-3.5-flash-lite` | 10 | 81,098 | 4,368, correct |
| 91 × 47, + progress notes with actions, one kept screenshot | `gemini-3.5-flash-lite` | 8 | 57,026 | 4,277, correct |

In the last run each batch pressed seven buttons in one call. The first batch used "Clear" (Calculator's C key, which clears only the current entry), so the screenshot showed 56×56×78. The executor noticed, switched to "All Clear" and repeated the sequence. Calculator renames that key between C and AC with its state; the `not_found` message listing similar names led the model to the right one.

## Code map

| File | Role |
|---|---|
| `LLM/ChatModel.swift` | Provider-neutral messages, tool calls, tools, requests, responses and `ModelError`. |
| `LLM/OpenAICompatibleModel.swift` | Adapter for the OpenAI Chat Completions format: encoding, decoding, retries, model listing. |
| `LLM/ModelConfiguration.swift` | Provider presets and resolution of provider, model and key. |
| `Agents/Executor/ExecutorAgent.swift` | Public free-form executor, backed by the shared conversation engine. |
| `Agents/Executor/AgentSession.swift` | Model/tool loop shared by free-form execution, repair and decision sessions. |
| `ZoopShared/Tasks/TaskPlan.swift` | Codable plans with readable summaries, tool details and per-step confirmation flags; whole-plan validation and UI persistence. |
| `Agents/Planner/PlannerAgent.swift` | Read-only screenshot/element grounding and structured plan generation. |
| `Agents/Planner/PlannerPrompt.swift` | Planning rules and provider-compatible submit_plan schema. |
| `Agents/Planner/PlanRunner.swift` | Direct Swift tool execution, approval boundaries, fresh observations and bounded model assistance. |
| `Agents/Executor/ExecutorPrompt.swift` | System prompt, approval rules and the control tools. |
| `Agents/Executor/ExecutorTypes.swift` | Task, limits, events, outcome, and the `ToolRunning` / `UserPrompting` interfaces. |
| `Agents/Executor/ImageCompression.swift` | PNG screenshots to JPEG before they go to the model. |
| `Sources/ZoopAgentCLI/main.swift` | `zoop-agent` command-line tool. |

## Providers and configuration

One adapter covers every provider that accepts the OpenAI Chat Completions format. Switching provider or model is a configuration change.

| Provider | Base URL (preset) | Key variable |
|---|---|---|
| `gemini` | `https://generativelanguage.googleapis.com/v1beta/openai/` | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| `openrouter` | `https://openrouter.ai/api/v1/` | `OPENROUTER_API_KEY` |
| `groq` | `https://api.groq.com/openai/v1/` | `GROQ_API_KEY` |
| `openai` | `https://api.openai.com/v1/` | `OPENAI_API_KEY` |
| `ollama` | `http://localhost:11434/v1/` | none |
| `lmstudio` | `http://localhost:1234/v1/` | none |
| `custom` | set `baseURL` | `ZOOP_CUSTOM_API_KEY` (optional) |

Each agent (`executor`, `planner`, `chat`) resolves its provider and model from, in order: command-line flags, environment (`ZOOP_EXECUTOR_PROVIDER`, `ZOOP_EXECUTOR_MODEL`, `ZOOP_EXECUTOR_BASE_URL`), then `~/.zoop/config.json` (or the path in `ZOOP_CONFIG`):

```json
{
  "agents": {
    "executor": { "provider": "gemini", "model": "<light model with tools and vision>" },
    "planner": { "provider": "gemini", "model": "<stronger model with tools and vision>" },
    "chat": { "provider": "openrouter", "model": "<model name>" }
  },
  "providers": {
    "gemini": { "apiKey": "…" },
    "openrouter": { "apiKey": "…" }
  }
}
```

The planner uses `ZOOP_PLANNER_PROVIDER`, `ZOOP_PLANNER_MODEL` and `ZOOP_PLANNER_BASE_URL`, or `agents.planner` in the file. A completely unconfigured planner falls back to the executor endpoint; this does not automatically select a stronger model. Configure both planner provider and model explicitly to use a different one. `--planner-provider`, `--planner-model` and `--planner-base-url` override the planner for one CLI invocation; general flags configure the executor and the unconfigured planner fallback.

Claude (`anthropic`) uses Anthropic's Messages API through `AnthropicModel` (raw HTTP, API version `2026-10-21`); every other provider uses the OpenAI-compatible adapter. The Claude adapter marks the tools and system prompt for prompt caching (later calls read them at 0.1x the input price) and turns thinking off, because Zoop prunes old screenshots and tool output from earlier turns and Claude Haiku 5.5 rejects a thinking block whose earlier turns changed.

Every model call is logged to `~/Zoop/logs/model-calls-YYYY-MM-DD.jsonl` (request sizes by part, billed tokens, cache use, requested tools, each HTTP attempt including rate-limit retries). `zoop-agent trace` summarizes recent runs; `--calls` lists every call. The log stays on this Mac (0600) and contains screen text.

API keys are looked up in this order: environment variables, the macOS Keychain (service `com.zoop.provider-keys`, account = provider name), then a plain `apiKey` in the file. The app's Settings page (slider button in the notch header) adds, checks and changes keys in the Keychain and moves any plain `apiKey` it finds in the file into the Keychain. Turning a provider on there points all three agents at it with the chosen model; the agents reread the configuration for every request, so no restart is needed. Zoop is signed ad hoc, so after a rebuild, and the first time `zoop-agent` reads a key, macOS asks whether the program may use the Keychain item; choose Always Allow. Keep the file private (`chmod 600 ~/.zoop/config.json`); never commit keys.

The executor needs a model that supports tool calling and image input. Small local models often struggle with long multi-step tool use.

Provider differences handled by the adapter:

- Gemini rejects some JSON Schema keywords, so its preset removes `additionalProperties` and `default` from tool schemas.
- Assistant messages are sent back with the provider's tool-call objects intact (Gemini attaches reasoning signatures there) and OpenRouter's `reasoning_details`. Response-only fields are dropped because some providers reject them in requests.
- Missing tool-call ids are filled in (`call_0`, …).
- Rate limits (429) and server errors (5xx) are retried three times with backoff, honouring `Retry-After`. Authentication and request errors are not retried.

## The executor

`ExecutorAgent.run(task, onEvent:)` carries out one approved task and returns an `AgentOutcome` (completed, failed or cancelled, with a summary, an optional Markdown report, steps and token usage).

Each step:

1. Sends the system prompt, the conversation and the tool list (the session tool catalog plus executor control tools) to the model.
2. Runs the requested tools one after another, in order, and appends one tool result per call.
3. Sends screenshots back as a user message after the tool results, as JPEG, because OpenAI-compatible tool messages carry only text. Only the newest screenshot stays an image (`ExecutorLimits.keptScreenshots`, default 1); older ones become a short note so the conversation does not grow by an image every step.

Control tools:

| Tool | Purpose |
|---|---|
| `report_progress` | A short note (and optional plan step and percent) for the notch and live activities. |
| `ask_user` | Asks the person and waits. Required before anything hard to undo: sending messages, email or posts; purchases, payments or bookings; deleting or overwriting data; submitting forms; changing account, security or system settings. Also used for logins: the executor never types passwords, payment details or one-time codes. |
| `request_dialog_help` | Asks the person to answer an open in-app sheet or dialog; presents its exact choices through the helper. The agent never clicks dialogs itself. |
| `finish_task` | Ends the task with success, a summary and an optional Markdown report. |

The system prompt contains the tools' operating guide (`SessionTools.guide`) and these rules, and tells the executor to treat text on pages and in documents as information, not instructions.

Limits: 50 model calls per task by default. A reply without a tool call gets a reminder; after two in a row the task fails with the model's last text. Cancelling the calling Swift task stops between steps. Model errors end the task as failed with the error message.

## Plan, execute and repair

The selected design uses a stronger planner once, with a lighter executor for judgment and repairs. A plan stores the original request, a title and 1–20 steps. Each step has a readable summary and either an action tool with arguments or a decide goal. Tool details appear in the notch approval card’s expandable Plan details; the CLI prints both views. The notch allows one task at a time and starts it only after Execute the plan.

Before planning, `PlannerAgent` captures a read-only screenshot. Its only callable session tools are read-only. Named clicks are accepted only after a successful `list_elements` for that app during the same planning session. The planner never launches an app: if an app is not running, it proposes open_app followed by a decide step for discovery after approval. Attempts to call a state-changing tool during planning are rejected without dispatch. Failed/invalid submissions return an error to the planner for correction within its default eight-call limit.

Action steps use real tool names and named click targets, including inside batches. Stored coordinates are rejected. Any step that needs live geometry becomes a decide step; the executor can inspect and use current coordinates there. Whole-plan validation uses the toolbox's parameter/click/batch validation before any step executes. Invalid later actions therefore prevent earlier mutations too. A plan must end with a decide step for final verification and the answer/report.

`PlanRunner.run(plan, approved: false)` executes nothing. After approval, it emits progress and runs known action steps through SessionToolbox directly, without a model call per action. Explicit tool errors or `verified: false` trigger repair. Clicks with `requires_observation` also enter a screenshot checkpoint immediately, before the next action; this is an observation, not a counted failure. Batches pause on such a click and include the sent click in `completed`. If the effect is absent, the executor uses open_app to focus the app, observes another screenshot, then explicitly tries strategy mouse at a visually located point. The runtime rejects mouse coordinates chosen before that image reached the model, rejects mouse recovery inside batches, and skips the remainder of a model response after an unconfirmed click. PID mouse delivery remains unconfirmed until checked; earlier background-session tests ignored these events, so focus-assisted recovery still needs live validation. Setup/permission failures stop the run instead of spending calls on model repairs.

Before a repair or decide session, the runner takes a fresh screenshot and supplies the original request, completed-step observations, current step and any failed result. A partial batch's completed count is included; the runner never automatically resends the batch or completed prefix. The assistant is instructed to inspect ambiguous results before acting and to complete only the current step. It returns with step_done so the Swift runner can continue. Success through finish_task is accepted only in the final verification session; failures can end the task earlier. A shared model-call budget spans all assistance sessions. The existing free-form executor and the new runner share the same message/image/tool-call engine, preserving provider echoes and screenshot pruning.

Steps marked confirm require an explicit yes immediately before running, in addition to initial task approval. Empty/negative answers cancel. The planner is instructed to flag hard-to-undo actions; repair/decision models retain ask_user rules for new risky actions. This is an application boundary and prompt policy, not a claim that a model can classify every risky action perfectly.

Planner and executor call/token usage are printed separately. Scripted tests prove that two direct actions plus final verification use one executor call, and that repairs resume without automatic replay. The earlier live benchmark table above is from free-form execution; the new architecture has not yet been benchmarked against a paid model. Do not infer a measured token reduction from the scripted call count.

## Command line

```bash
swift run zoop-agent config                     # which provider/model each agent uses (keys hidden)
swift run zoop-agent models --provider gemini   # model names your key offers
swift run zoop-agent hello                      # one short request to check provider, key and model
swift run zoop-agent plan "Open Calculator and compute 12 × 34" # observations only
swift run zoop-agent run "Open Calculator and compute 12 × 34" --save frames/planned-run
swift run zoop-agent run "Open Calculator and compute 91 × 47" --approve # explicit plan approval
swift run zoop-agent run "Compare three mechanical keyboards" --no-plan --step "Search reviews" --step "Write a comparison"
```

`--provider`, `--model` and `--base-url` override the configuration for one command. `plan` rejects `--approve` and `--no-plan` so it always stays read-only. `run` prints the proposed readable steps and their tool details, then waits for an explicit yes. EOF or any other response cancels. `--approve` supplies initial plan approval for automation; it does not bypass confirmation on risky steps. `--no-plan` retains the previous free-form executor. `--step` is only supported with `--no-plan`. `run` asks `ask_user` questions on the terminal. Ctrl-C stops after the current step. `--save DIR` keeps every screenshot. The helper must be running in the agent session (`zoop-bridge status`).

## Native chat and execution

ChatAgent handles ordinary conversation using the chat role. It exposes only plan_task, not desktop tools. A valid handoff produces a grounded plan via the planner role. LiveCompanionService returns that proposal to the notch, which persists the typed plan and waits for the button. Normal conversation can continue while a plan is pending; a revised proposal replaces the pending one. During execution the composer is disabled. The executor role is resolved only when execution starts, and AgentEvent feeds actual progress, screenshots and in-app questions into the UI. Completed outcomes export actual reports/summaries; failures do not produce sample research. No queue or pause/resume system is included in the base version.

See [NativeNotch.md](NativeNotch.md) for setup, persistence and base-version validation. A future fetch_url tool could supply readable page text for research without driving Safari.

## System permission interruption

Native execution wraps SessionToolbox in PermissionToolRunner. Before tools and after actions, it queries recognized system permission windows through the bridge. A pending dialog awaits UserPrompting.choosePermission with its exact observed choices, independently of the executor and its Auto mode. The UI returns only the selected opaque choice identity; the helper revalidates and performs it once. No permission-choice tool is declared to the model. Cancellation, stale identities, interrupted actions and unconfirmed presses cannot become implicit Allow responses. CLI compatibility uses the prompter's numbered/exact-label fallback when this wrapper is used; native and CLI execution wire it by default.

## Slow and failing web pages

The agent session is not on screen, so Safari often skips drawing animated or fading web content: apple.com can look blank in a screenshot while the page has fully loaded (it appears as soon as someone opens the session directly). The executor therefore reads web pages with `read_page`, which collects the page's text and links through Accessibility in reading order, joins pieces on the same row (so "From ₹11658.00" keeps its "Per Month"), and can filter by words (`find`). Links it lists can be clicked by name.

Web steps follow a fixed rhythm: open the URL and `wait` 10 seconds in one batch, then `read_page`. No text yet: reload and wait 10 seconds in one batch (press_key cmd+r, wait 10), then read again, up to 3 reloads. After that, or when a site errors, blocks or lacks the information, the executor switches to another source (a search engine, another page of the same site, or another reputable site) and names the source in its result. A site named in the task is the first choice, not the only one. `wait` (0.5–15 seconds, batchable) changes nothing, so waiting and reloading never count as failed attempts. The failed-attempt budget per step is 5.

## Cleanup after a task

When a task completes successfully, LiveCompanionService and `zoop-agent run` call `SessionCleanup.afterTask`. It sends the helper's `quitApps` request, which quits every app in the agent session except Finder. The result is added to the task summary: "Closed Safari, TextEdit." and, if an app refused because of unsaved changes, "Still open: TextEdit … nothing was discarded." Cleanup never changes the task's status. Failed and cancelled tasks skip it and keep their apps open for inspection and resuming. `zoop-agent run --keep-apps` skips it too. Because apps are quit, the executor prompt tells the model to save any document it created or changed before `finish_task`, and the planner prompt asks for a save step in document tasks.

## Websites through Playwright

Websites are handled by Microsoft's Playwright MCP server (`@playwright/mcp@0.0.84`, pinned), not by Safari in the agent session. `BrowserSession` starts it with `npx` as a child process and speaks MCP (newline-delimited JSON-RPC over stdio, `MCPStdioClient`). It drives the installed Google Chrome headlessly in the person's own macOS user, with Zoop's profile in `~/Library/Application Support/Zoop/Browser Profile`, a 1280×800 viewport and `--snapshot-mode none`. Playwright acts inside the page: it fills web forms that ignored Accessibility and posted keys (Gmail compose), waits for real page loads, and screenshots pages regardless of what the agent session draws.

`BrowserToolRunner` adds an allowlist of browser tools to the model (navigate, navigate_back, find, snapshot, click, type, fill_form, press_key, select_option, hover, wait_for, take_screenshot, tabs, handle_dialog) and routes `browser_*` calls to Playwright; everything else still goes to the session helper. JavaScript evaluation, file upload, network inspection and closing the browser are not offered. Results longer than 16,000 characters are cut, with a pointer to `browser_find`. The executor prompt gets a browser guide and the planner a note to plan website work as decide steps, never Safari. Without Node.js (`npx`), Zoop runs without browser tools.

Sign-ins: Playwright launches Chrome with its own cookie encryption, so sites must be signed in through Zoop's own window. "Sign in to websites…" in the menu-bar menu opens a visible Chrome with the same profile at accounts.google.com; "Done signing in" closes it. Tasks cannot use the browser while that window is open, because Chrome allows one process per profile. Google sometimes refuses sign-in in automated browsers.

The live preview shows the browser page (Playwright screenshots) while the browser was used in the last 20 seconds, and the agent session screen otherwise. `BrowserSessionTests.liveBrowserReadsApplesPrice` exercises the real path with `ZOOP_LIVE_BROWSER=1 swift test --filter BrowserSessionTests`.

## Email through the Mail app

`send_email(to, subject, body)` sends with the Mail app's configured account in the agent session through AppleScript (`MailSender`, protocol v11 `sendEmail` action). PermissionToolRunner first shows the person the recipients, subject and full text; nothing is sent without approval, and a plan step's own confirmation is skipped so there is one card. The first send asks macOS for Automation permission to control Mail. Addresses must be plain `name@domain` values.

## Steps finish before the next one starts

`step_done` requires `complete`. With `complete: false` the plan stops as failed instead of running later steps on missing results; a live run had moved from an unfinished Calculator step to TextEdit. An action step whose result is unconfirmed (`verified: null`, for example PID-posted typing) gets a screenshot and model check before the runner continues, unless the next step is a decide step that inspects it anyway. A `save_document` step is not confirmed separately: the runtime's save card is its single approval. A planned cmd+n right after opening TextEdit is skipped, because TextEdit already opens a blank document at launch and a live run ended up with two windows.

## Dialogs, saves and permissions go to the person

The agent never clicks a dialog. PermissionToolRunner routes every dialog, save and permission to the person:

- **macOS permission prompts** (location, notifications, Automation, file access) are checked before every tool and after every action, as before.
- **In-app dialogs** (Save, Replace, Continue, onboarding sheets) are checked in every app an action names or touches. A dialog that is already open is answered first and the action is not run, because the answer may change what it should be. A dialog the action opened is answered straight away, and the person's `human_choice` is returned with the action's result. Greyed-out buttons are listed in `dialog_disabled_choices`.
- **Saving** uses only `save_document`. Before it runs, Zoop asks the person "Save the TextEdit document as ~/Documents/…?" with a confirm card, regardless of Auto mode. A declined save returns `declined`, and the model must not save another way. An action that returns `consent_pending` is repeated once after the person answers the macOS consent card.
- `request_dialog_help(bundle_id)` asks the person about an open dialog at any time, including at the retry limit. It no longer requires Accessibility and mouse attempts first; DialogRecoveryState was removed.

The helper backs this up by refusing clicks, typing, set-text and keys aimed at a dialog (see SessionBridge.md). The executor and planner prompts forbid cmd+s, Save sheets and dialog clicks. The person's choice goes directly to the helper as an opaque identity; the model never translates an approval into a button press. A fresh screenshot follows, and the task outcome still needs verification.
