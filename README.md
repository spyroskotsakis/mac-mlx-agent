# Mac Local AI Setup with Xcode Support

Run a fully **local** agentic AI stack on an Apple Silicon Mac — no cloud, no API
keys — and use it as the model behind your coding agents and Xcode itself.

It works with:

- **Xcode** (its "Add an ACP Agent" flow, through OpenCode's `acp` server)
- **Claude Code** (the CLI, pointed at the local model through a bridge)
- **OpenCode** (the open-source coding agent)

Everything runs on your own hardware. Your code never leaves your Mac.

> **Just want it to work?** Download the **MLX Server** menu-bar app from the
> [latest release](https://github.com/spyroskotsakis/mac-mlx-agent/releases/latest)
> and run it — it installs `mlx-lm`, downloads the model, and sets up OpenCode
> and Claude Code automatically, so you can skip the manual steps below. See
> [Use the menu-bar app](#use-the-menu-bar-app-recommended).

---

## What is MLX — and why this is interesting

### MLX, in a paragraph

**MLX** is Apple's open-source machine-learning framework for Apple Silicon
(M1/M2/M3/M4 Macs). It runs models on the GPU and Neural Engine through Metal,
and — critically — it uses the Mac's **unified memory**: the CPU and GPU share
one pool of RAM instead of copying data back and forth over a bus. That single
feature is what makes running a ~19 GB, 35-billion-parameter model on a laptop
practical at all.

**MLX-LM** is the LLM toolkit built on top of MLX (`pip install mlx-lm`). It can
load, run, quantize, and fine-tune models, and it ships **`mlx_lm.server`** — a
small HTTP server that loads a model and exposes it behind the same
**OpenAI chat-completions API** (`POST /v1/chat/completions`) that ChatGPT and
most AI libraries already speak, including tool calling.

### The MLX server, concretely

In this repo, `mlx_lm.server` loads `Qwen3.5-35B-A3B-4bit` into memory and
listens on `http://127.0.0.1:8080/v1`, where your model is reachable as
`default_model`. Because the API is OpenAI-compatible, **anything that can point
at an OpenAI-compatible URL can use it** — Xcode, Claude Code, OpenCode, a bare
`curl`, or your own app.

### Why this setup is interesting (the pitch)

| If someone cares about… | The point |
|-------------------------|-----------|
| **Privacy** | Your source code and prompts never leave the Mac — no cloud upload, no training on your code. |
| **Cost** | After the hardware, inference is unlimited with no per-token meter. |
| **Offline use** | Flights, bad Wi-Fi, or air-gapped machines — it still works. |
| **Control** | You own the model: swap it, quantize it, fine-tune it, pin a version. No vendor ToS changes or deprecations. |
| **"Is it a toy?"** | No — tool calling + reasoning drive a real agent that edits files, runs builds, and writes apps. |

In short: **one local model becomes the engine behind your whole dev toolchain.**
The same `127.0.0.1:8080/v1` endpoint powers Xcode's in-editor assistant, Claude
Code's CLI, and OpenCode, with nothing round-tripping to a cloud provider.

The honest tradeoff: a local 35B MoE is not a frontier cloud model — for the
hardest problems a hosted model can still win. But for most day-to-day coding,
"private, free, offline, and yours" is a strong offer. See
[Performance notes](#performance-notes) and
[Caveats](#caveats-be-realistic) for the realistic picture.

---

## The stack (4 layers)

```
┌─────────────────────────────────────────────────────┐
│  Agent   — Xcode, Claude Code, OpenCode, any tool   │
│            that speaks the OpenAI chat-completions  │
│            protocol                                 │
├─────────────────────────────────────────────────────┤
│  MLX-LM server  — OpenAI-compatible HTTP server      │
│            (tool calling + reasoning support)        │
├─────────────────────────────────────────────────────┤
│  MLX-LM  — load / run / quantize / fine-tune LLMs    │
│            (CLI + Python API)                        │
├─────────────────────────────────────────────────────┤
│  MLX  — Apple's array framework for Apple Silicon    │
│            (Metal acceleration, memory management)   │
└─────────────────────────────────────────────────────┘
```

The one detail that makes everything connect: **the MLX-LM server exposes your
model under the name `default_model`** and serves a standard OpenAI API on
`http://127.0.0.1:8080/v1`. Any tool that can point at an OpenAI-compatible URL
can use it.

---

## Prerequisites

- **Apple Silicon Mac** (M1 or newer). This was set up on an **M4 Max, 36 GB RAM**,
  macOS 26.5.
- **Xcode 26** or newer (for the Xcode integration; Xcode 26.2+ recommended).
- **Python 3.10+** with `pip` (`mlx-lm` needs it).
- ~19 GB free disk for the default Qwen3.5-35B-A3B MoE (4-bit).

---

## Step 1 — Install MLX-LM

```bash
pip install mlx-lm
```

This pulls in `mlx`, `mlx-metal`, `mlx-lm`, and its CLI tools.

> **Note:** `mlx-lm` upgrades `transformers`/`tokenizers` to recent versions.
> If you share a Python env with `litellm`, `sentence-transformers`, or
> `langchain-openai`, double-check those still work afterwards.

---

## Step 2 — Pick and download a model

The model must be **MLX format** (from HuggingFace `mlx-community/…`) and
**support tool calling** so agents can invoke tools. Pick one that fits your
RAM; 4-bit weights ≈ (parameters in billions) × 0.55 GB.

| Model | Size (4-bit) | Notes |
|-------|-------------|-------|
| `mlx-community/Qwen3.5-35B-A3B-4bit` | ~19 GB | **Default.** MoE coder (3B active → fast); its tool calls parse reliably. |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | ~20 GB | MoE coder (3B active), newer sibling of the default. |
| `mlx-community/Qwen3.8-27B-4bit` | ~16 GB | 27B mid-size option. |
| `mlx-community/Qwen3-14B-4bit` | ~8.3 GB | **Smallest option.** Qwen3 instruct — less RAM, and the natural pick for "concurrent requests" mode. |

> **Avoid for agent use:** `Qwen3-Coder-30B-A3B` (drops the `<tool_call>` wrapper)
> and `Qwen2.5-Coder-14B` (wraps its call in `<tools>` instead of `<tool_call>`)
> both emit tool calls mlx_lm.server can't parse, which stalls the OpenCode/Xcode
> loop.

Download (or skip this — the server auto-downloads on first launch):

```bash
hf download mlx-community/Qwen3.5-35B-A3B-4bit
```

---

## Step 3 — Start the server

This repo ships `start_server.sh`, which launches the server and applies the
**KV-cache quantization** the larger models need:

```bash
./start_server.sh                                      # default: Qwen3.5-35B-A3B
```

It runs:

```bash
mlx_lm.server --model "$MODEL" --port "$PORT" \
  --kv-bits "$KV_BITS" --max-tokens "$MAX_TOKENS" \
  --temp "$TEMP" --top-p "$TOP_P" --top-k "$TOP_K" \
  --chat-template-args '{"enable_thinking":false}'
```

The server loads the model and listens on `http://127.0.0.1:8080` (port `8080`
by default). Useful flags: `--host`, `--port`, `--max-tokens`, `--temp`,
`--kv-bits`, and `--chat-template-args` (thinking mode).

> **35B-A3B MoE on a 36 GB Mac — KV-cache fix.** The MoE's ~19 GB weights fit in
> RAM, but its full-precision (16-bit) KV cache overflows Metal GPU memory during
> long agent prompts — the server dies with `[METAL] … Insufficient Memory` →
> `generation thread died`. `start_server.sh` sets `--kv-bits 4` (and
> `--max-tokens 8192`) to stay in budget. If output quality suffers, try
> `KV_BITS=8 ./start_server.sh …`, but that doubles KV memory and may re-trigger
> the OOM on long prompts.

**Smoke-test it** in another terminal:

```bash
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "default_model", "messages": [{"role": "user", "content": "Hello!"}]}'
```

Endpoints exposed:
- `POST /v1/chat/completions` — OpenAI chat completions (with tool calling)
- `GET /v1/models` — lists every locally cached model by its HF id, not just the
  loaded one; the loaded model is still served to clients as `default_model`

---

## Use the menu-bar app (recommended)

This repo also ships a native macOS **menu-bar app** (`MLXServer/`) that
**installs itself** — it replaces all the manual steps below with one download:

1. Download `MLXServer-<version>.zip` from the
   [latest release](https://github.com/spyroskotsakis/mac-mlx-agent/releases/latest).
2. Unzip and drop `MLXServer.app` into `/Applications`.
3. Run it. The app then **installs `mlx-lm`** for you (one click when it's
   missing), **downloads the selected model** into the HuggingFace cache (with a
   live progress bar — or auto-downloads on first Start), **sets up OpenCode**
   automatically (writes `~/.config/opencode/opencode.jsonc` pointing at the
   server, with the right per-model `limit.context`), and **sets up Claude Code**
   with a separate env profile (`~/.config/mlx-local/claude-code.env`) pointing at
   the LiteLLM bridge on port 4001 — or shows you the exact config to write by
   hand.

So **Steps 1–3 below are optional** — they're kept to explain what the app does
under the hood and for people who prefer the terminal. The app defaults to the
same flags as `start_server.sh` — `--kv-bits 4 --max-tokens 8192 --temp 0.2
--top-p 0.8 --top-k 20` — all editable in its **Model settings** section, plus a
per-model **Thinking mode** toggle and a per-model **Max context** display.

> **First launch on a downloaded build:** the app is ad-hoc signed (not
> notarized), so macOS Gatekeeper may block it. Right-click `MLXServer.app` →
> **Open**, or run `xattr -dr com.apple.quarantine MLXServer.app` first.

- Click the **MLX Server** icon in the menu bar to open the control panel.
- **Start / Stop** the server, pick the model, and watch the live log.
- Add models later in `MLXServer/MLXServer/ServerController.swift`
  (`ServerController.availableModels`).

To build from source instead, open `MLXServer/MLXServer.xcodeproj` and press
**Run**, or:

```bash
xcodebuild -project MLXServer/MLXServer.xcodeproj -target MLXServer -configuration Release build
```

See `MLXServer/README.md` for details.

---

## How to use it day-to-day

### Chat from the terminal (no server)

```bash
mlx_lm chat --model mlx-community/Qwen3.5-35B-A3B-4bit
```

### Any OpenAI SDK / `curl`

Use `base_url = http://127.0.0.1:8080/v1` and model `"default_model"`:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="not-needed")
resp = client.chat.completions.create(
    model="default_model",
    messages=[{"role": "user", "content": "Write a Swift function to reverse a string."}],
)
print(resp.choices[0].message.content)
```

---

## Use it in Xcode (create Xcode apps)

Xcode 26 exposes external coding agents through the **Agent Client Protocol
(ACP)**. The **"Add an ACP Agent"** dialog (in Xcode's agent/settings area) is
the current path — the older "Intelligence → Add Sub Provider → Locally Hosted
Provider" flow is gone in recent Xcode builds.

### A. Register OpenCode as an ACP agent (in-editor assistant)

The ACP agent is OpenCode's `acp` server, so you need the MLX server and a
configured OpenCode first (both covered below).

1. Start the MLX-LM server (Step 3) and leave it running.
2. Configure OpenCode to use `mlx/default_model` (see "Use it in OpenCode").
3. In Xcode, open the **Add an ACP Agent** dialog and fill in:
   - **Executable**: `/Users/spyroskotsakis/.opencode/bin/opencode` (your OpenCode
     binary — find it with `which opencode`)
   - **Arguments**: `acp`
   - **Interpreter**: (empty)
   - **Environment variables**: (empty)
4. Save it. Xcode's chat now runs through OpenCode on your local model.

### B. Agent-driven development (build the app for you)

An **agent** writes the code and runs `xcodebuild` to compile and fix it, while
the project is open in Xcode.

1. Open (or create) your Xcode project.
2. Launch the agent on the local model — OpenCode (`opencode run`) pointed at
   `mlx/default_model`, or `./claude-local.sh` (see the Claude Code section).
3. Ask it to build a feature; it writes files, runs `xcodebuild`, reads the
   errors, and iterates until it compiles.

Both paths keep your code entirely on your Mac — nothing is sent to the cloud.

---

## Use it in OpenCode

[OpenCode](https://opencode.ai) is an open-source terminal coding agent. Point it
at the local server with a config file — `~/.config/opencode/opencode.jsonc`
(global, note the `.jsonc` extension) or an `opencode.json` in the project root:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "mlx/default_model",
  "provider": {
    "mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "MLX (local)",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1",
        "chunkTimeout": false,
        "headerTimeout": false
      },
      "models": {
        "default_model": {
          "name": "Qwen3.5-35B-A3B (local)",
          "limit": { "context": 262144, "output": 8192 }
        }
      }
    }
  }
}
```

`mlx/default_model` means "provider `mlx`, model `default_model`" — matching the
name the MLX-LM server serves. Start OpenCode and every interaction now runs
through your local model.

> **The `"name"` is just a label.** `default_model` is the alias the server
> serves, pointing at *whatever model you launched* — the `"name"` field in the
> config is only cosmetic picker text. If you switch models, update that `name`
> too, or OpenCode keeps showing the old label.
>
> **`limit.output` is load-bearing.** OpenCode hard-codes `max_tokens=32000` for
> custom providers, which overrides the server's `--max-tokens 8192` and makes
> the model generate a huge response that hangs the server when a client
> disconnects mid-generation. Setting `limit.output: 8192` caps OpenCode's
> requests to match the server. Without it, the agent can wedge the single
> generation thread and the server stops responding until restarted.
>
> **`limit.context` should match the model.** Set it to the model's maximum
> context length (262144 for the Qwen3.5/3.6/3.8 models, 40960 for Qwen3-14B) so
> OpenCode knows how much it can send. The menu-bar app writes this for you from
> each model's profile; this sample shows the Qwen3.5 value.

---

## Use it in Claude Code

> **Important:** Claude Code speaks the **Anthropic Messages API**
> (`POST /v1/messages`); the MLX-LM server speaks **OpenAI chat-completions**
> (`POST /v1/chat/completions`). Claude Code has *no* native OpenAI mode, so you
> must run a translating proxy in front of MLX-LM. The standard bridge is
> [LiteLLM](https://docs.litellm.ai).

### 1. Install LiteLLM (isolated venv)

LiteLLM's proxy pins older `click`/`tokenizers` versions that conflict with
`mlx-lm`, so install it in its own virtualenv rather than the same env as MLX:

```bash
python3 -m venv .venv-litellm
.venv-litellm/bin/pip install 'litellm[proxy]'
```

The repo ships `litellm-mlx.yaml`:

```yaml
model_list:
  - model_name: default_model              # id Claude Code will request
    litellm_params:
      model: custom_openai/default_model   # "custom_openai/" = OpenAI-compatible backend;
                                           # routes /v1/messages -> /v1/chat/completions
      api_base: http://127.0.0.1:8080/v1   # must end in /v1
      api_key: sk-no-key-needed            # LiteLLM requires a value; MLX ignores it
      use_chat_completions_api: true       # force /chat/completions (not /responses)

litellm_settings:
  drop_params: true

general_settings:
  master_key: sk-local-claude              # credential Claude Code must present
```

### 2. Start the bridge

```bash
# (MLX-LM server already running on 8080)
.venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port 4001
```

> **Why port 4001, not 4000?** Port 4000 is used by a separate LiteLLM instance
> (`~/Coding-Agent-Infra/litellm`). Keeping this bridge on 4001 avoids a
> bind collision, so the two can run at the same time.

### 3. Verify the bridge before touching Claude Code

```bash
curl -sS -X POST http://127.0.0.1:4001/v1/messages \
  -H "Authorization: Bearer sk-local-claude" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"default_model","max_tokens":32,"messages":[{"role":"user","content":"Say hi"}]}'
```

Success is a body starting with `{"id":"msg_…"` containing a `content` array.

### 4. Point Claude Code at the bridge

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:4001
export ANTHROPIC_AUTH_TOKEN=sk-local-claude      # -> Authorization: Bearer
export ANTHROPIC_MODEL=default_model
export ANTHROPIC_DEFAULT_HAIKU_MODEL=default_model
export ANTHROPIC_DEFAULT_SONNET_MODEL=default_model
export ANTHROPIC_DEFAULT_OPUS_MODEL=default_model
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
export MAX_THINKING_TOKENS=0
claude
```

Header mapping: `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer`,
`ANTHROPIC_API_KEY` → `x-api-key`. A non-empty credential is **mandatory**
(otherwise Claude Code shows the login screen), and the model id must match
`model_name` in the LiteLLM config.

To make it persistent, put the `env` block in `~/.claude/settings.json` (not a
committed project settings file):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4001",
    "ANTHROPIC_AUTH_TOKEN": "sk-local-claude",
    "ANTHROPIC_MODEL": "default_model",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "default_model",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

### 5. One-command launcher (script)

The repo ships `claude-local.sh`, which sets the same env vars and launches
Claude Code pointed at the bridge. With both servers running:

```bash
./claude-local.sh              # launches Claude Code on the local model
./claude-local.sh -p "…"       # extra args are passed through to `claude`
```

The script exports `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_MODEL` (plus the `ANTHROPIC_DEFAULT_*_MODEL` aliases),
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`, and `MAX_THINKING_TOKENS=0`, then
`exec`s `claude "$@"`.

Because the env vars live in the script's process rather than your shell profile
or `~/.claude/settings.json`, your normal Claude Code login is left untouched.

### Caveats (be realistic)

- Anthropic does **not** support routing Claude Code to non-Claude models; this
  runs "best-effort" through the gateway.
- Tool calling is translated by LiteLLM, but the agent loop (many tools, long
  multi-turn context) is where a local model breaks first — test with a
  single-tool prompt before relying on it.
- Keep `CLAUDE_CODE_MAX_OUTPUT_TOKENS` below the backend limit, and expect the
  local model to be slower than cloud Claude.
- **Speed (the real one):** Claude Code sends an ~85k-token system prompt (its
  tools + your MCP servers) on *every* message, and a local model must prefill
  all of it before answering — minutes per message even for a fast MoE.
  **OpenCode sends a far smaller prompt and is the recommended agent for local
  models.**

---

## Performance notes

- **Neural accelerators** (M5): MLX targets them automatically — ~4× faster
  matrix multiplication vs M4, which translates almost 1:1 to faster prompt
  processing (important for agents reading large codebases). No code changes.
- **Continuous batching**: the server batches concurrent requests on the GPU, so
  parallel sub-agents don't queue — they're served concurrently.
- **Distributed inference** (advanced): MLX can spread a model across multiple
  Macs over Thunderbolt/Ethernet to run models too large for one machine.

---

## Troubleshooting

- **Port already in use** — pass `--port 8081` and update every client's URL.
- **Server says model not found** — make sure the model was downloaded to the
  default HuggingFace cache, or pass the local path instead of the HF id.
- **Slow first token** — first request compiles kernels; subsequent requests are
  faster.
- **`generation thread died` / `[METAL] Insufficient Memory`** — the model's KV
  cache overflowed GPU memory during a long prompt (common with the 35B-A3B MoE
  on a 36 GB Mac). Relaunch with `--kv-bits 4` (or `8`) — `start_server.sh`
  already does this. Reduce the client's context/`max_tokens` if it persists.
- **Tool calls malformed** — use a model whose tool-call format mlx_lm.server
  actually parses. The default Qwen3.5-35B-A3B emits `<tool_call>\n<function=…>`
  (the `qwen3_coder` parser). The older Qwen3-Coder-30B drops the `<tool_call>`
  wrapper and Qwen2.5-Coder-14B wraps its call in `<tools>` instead — both come
  back as plain text and stall the agent loop.
- **`Failed to parse tool call … No function provided`** — the model hit its
  `max_tokens` cap mid tool-call (these Qwen coder models spend output tokens on
  reasoning first). Raise `MAX_TOKENS` (`start_server.sh` defaults to 8192).
- **Model repeats the same phrase/sentence in a loop** — `mlx_lm.server` ignores
  the model's `generation_config.json` and defaults to **greedy** decoding
  (`temp 0.0`, `top_p 1.0`, `top_k 0`) with **no repetition penalty**, which
  causes these Qwen models to degenerate into a fixed-point loop.
  `start_server.sh` sets deterministic sampling (`--temp 0.2 --top-p 0.8
  --top-k 20`),
  which breaks the loop. (The server has no `--repetition-penalty` flag; it only
  reads `repetition_penalty` from the request body, which most OpenAI-compatible
  clients don't send. The sampling params are the real fix.)
- **Agent narrates instead of acting (tool call shows up as raw text)** — the
  model is emitting its tool call in a format mlx_lm.server doesn't recognize as
  a structured `tool_calls` block (e.g. `<function=read>` without a `<tool_call>`
  wrapper, or `<tools>…</tools>`), so OpenCode ignores it and the loop ends
  without doing anything. This is a **model choice** issue, not a sampling issue:
  switch to a model whose chat template matches mlx_lm.server's parser (the
  default Qwen3.5-35B-A3B works; see the model table above).

---

## Related files in this repo

- `start_server.sh` — launches the MLX-LM server with the KV-cache + sampling fixes.
- `litellm-mlx.yaml` — LiteLLM config for the Anthropic→OpenAI bridge.
- `claude-local.sh` — launches Claude Code pointed at the local bridge.
- `MLXServer/` — native menu-bar app to start/stop the server and switch models.
- `CHANGELOG.md` — release history (versions, features, and fixes).
