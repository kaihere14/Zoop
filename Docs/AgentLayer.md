# Agent layer

The agent layer (`Sources/ZoopAgents`) is Zoop's brain. It decides what to do and drives the helper through the tools in [AgentTools.md](AgentTools.md). It does not depend on any one AI provider: agents talk to a small `ChatModel` interface, and the configuration chooses the provider and model.

```
ExecutorAgent ──ModelRequest──▶ ChatModel (OpenAICompatibleModel) ──HTTP──▶ Gemini / OpenRouter / Groq / OpenAI / Ollama …
      │
      ├─ tool calls ──▶ SessionToolbox ──socket──▶ ZoopHelper (agent session)
      ├─ ask_user ────▶ UserPrompting (terminal now, UI later)
      └─ AgentEvent ──▶ progress for the UI or CLI
```

Status: the model layer and the executor are built and unit-tested with scripted models. The chat agent and the UI wiring come next.

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
| `Agents/Executor/ExecutorAgent.swift` | The agent loop. |
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

Each agent (`executor`, `chat`) resolves its provider and model from, in order: command-line flags, environment (`ZOOP_EXECUTOR_PROVIDER`, `ZOOP_EXECUTOR_MODEL`, `ZOOP_EXECUTOR_BASE_URL`), then `~/.zoop/config.json` (or the path in `ZOOP_CONFIG`):

```json
{
  "agents": {
    "executor": { "provider": "gemini", "model": "<a model name from `zoop-agent models`>" },
    "chat": { "provider": "openrouter", "model": "<model name>" }
  },
  "providers": {
    "gemini": { "apiKey": "…" },
    "openrouter": { "apiKey": "…" }
  }
}
```

Keys in environment variables win over keys in the file. Keep the file private (`chmod 600 ~/.zoop/config.json`); never commit keys.

The executor needs a model that supports tool calling and image input. Small local models often struggle with long multi-step tool use.

Provider differences handled by the adapter:

- Gemini rejects some JSON Schema keywords, so its preset removes `additionalProperties` and `default` from tool schemas.
- Assistant messages are sent back with the provider's tool-call objects intact (Gemini attaches reasoning signatures there) and OpenRouter's `reasoning_details`. Response-only fields are dropped because some providers reject them in requests.
- Missing tool-call ids are filled in (`call_0`, …).
- Rate limits (429) and server errors (5xx) are retried three times with backoff, honouring `Retry-After`. Authentication and request errors are not retried.

## The executor

`ExecutorAgent.run(task, onEvent:)` carries out one approved task and returns an `AgentOutcome` (completed, failed or cancelled, with a summary, an optional Markdown report, steps and token usage).

Each step:

1. Sends the system prompt, the conversation and the tool list (the ten session tools plus three control tools) to the model.
2. Runs the requested tools one after another, in order, and appends one tool result per call.
3. Sends screenshots back as a user message after the tool results, as JPEG, because OpenAI-compatible tool messages carry only text. Only the newest screenshot stays an image (`ExecutorLimits.keptScreenshots`, default 1); older ones become a short note so the conversation does not grow by an image every step.

Control tools:

| Tool | Purpose |
|---|---|
| `report_progress` | A short note (and optional plan step and percent) for the notch and live activities. |
| `ask_user` | Asks the person and waits. Required before anything hard to undo: sending messages, email or posts; purchases, payments or bookings; deleting or overwriting data; submitting forms; changing account, security or system settings. Also used for logins: the executor never types passwords, payment details or one-time codes. |
| `finish_task` | Ends the task with success, a summary and an optional Markdown report. |

The system prompt contains the tools' operating guide (`SessionTools.guide`) and these rules, and tells the executor to treat text on pages and in documents as information, not instructions.

Limits: 50 model calls per task by default. A reply without a tool call gets a reminder; after two in a row the task fails with the model's last text. Cancelling the calling Swift task stops between steps. Model errors end the task as failed with the error message.

## Command line

```bash
swift run zoop-agent config                     # which provider/model each agent uses (keys hidden)
swift run zoop-agent models --provider gemini   # model names your key offers
swift run zoop-agent hello                      # one short request to check provider, key and model
swift run zoop-agent run "Open Calculator and compute 12 × 34" --save frames/run
swift run zoop-agent run "Compare three mechanical keyboards" --step "Search reviews" --step "Write a comparison"
```

`--provider`, `--model` and `--base-url` override the configuration for one command. `run` asks `ask_user` questions on the terminal. Ctrl-C stops after the current step. `--save DIR` keeps every screenshot. The helper must be running in the agent session (`zoop-bridge status`).

## Next

- Chat agent: conversation and plan proposals for the approval card.
- `ClaudeCompanionService` replacement: a provider-neutral `CompanionService` that uses the chat agent and the executor, feeding `AgentEvent` into the notch and live activities.
- A `fetch_url` tool (download a page's readable text) for research without driving Safari.
