# Mac Local AI Setup with Xcode Support

Run a fully **local** agentic AI stack on an Apple Silicon Mac — no cloud, no API
keys — and use it as the model behind your coding agents and Xcode itself.

It works with:

- **Xcode** (its "Add an ACP Agent" flow, through OpenCode's `acp` server)
- **Claude Code** (the CLI, pointed at the local model through a bridge)
- **OpenCode** (the open-source coding agent)

Everything runs on your own hardware. Your code never leaves your Mac.

> ## ⚠️ Claude Code is crashing — use OpenCode instead
>
> **Claude Code is currently crashing on the local model** (its ~85k-token system
> prompt stalls or returns empty, and it can wedge the server's generation
> thread). **For now, use [OpenCode](#use-it-in-opencode) for local agent work** —
> it sends a far smaller prompt, caches reliably, and is the agent this project
> tests against. See [Which agent to use](#which-agent-to-use). This note will be
> removed when Claude Code is usable again.

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

### The MLX ecosystem — and where the models come from

All the models used here come from the **[`mlx-community`](https://huggingface.co/mlx-community)
organization on Hugging Face** — a community org hosting **pre-converted,
Apple-Silicon-ready model weights** (already quantized and in MLX format), so you
can run them straight from `mlx-lm` or integrate them into your own apps without
doing the conversion yourself.

MLX isn't just for chat — it's a small family of packages:

| Package | What it does |
|---------|--------------|
| **`mlx-lm`** | LLM text generation + fine-tuning (what this repo uses). |
| **`mlx-swift-examples`** | A Swift package to run MLX models in native apps. |
| **`mlx-vlm`** | Vision Language Models (inference + fine-tuning). |
| **`mlx-audio`** | Text-to-speech, speech-to-text, and speech-to-speech. |

**Quick start for LLMs** (from the `mlx-community` README):

```bash
pip install mlx-lm
mlx_lm.generate --model mlx-community/Qwen3-4B-Instruct-2507-4bit --prompt "hello"
mlx_lm.chat        # a chat REPL; context is preserved across turns
```

**Convert & quantize your own model** — and optionally upload it back to the
`mlx-community` org:

```bash
mlx_lm.convert --model Qwen/Qwen3-4B-Instruct-2507 -q
mlx_lm.convert --model Qwen/Qwen3-4B-Instruct-2507 -q \
  --upload-repo mlx-community/Qwen3-4B-Instruct-2507-4bit
```

For more (image generation with Flux/Stable Diffusion, LoRA fine-tuning, Whisper,
CLIP/LLaVA, and other examples), see the
[MLX Examples repo](https://github.com/ml-explore/mlx-examples).

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

Everything the stack needs, grouped by what's **manual** (you install once) vs
**auto-installed/detected** (the app's one-click buttons or `setup.sh` handle it).
Both the menu-bar app and `setup.sh` detect each item and tell you exactly what's
missing, so a fresh machine shows its gaps up front.

**Manual (install yourself):**

- **Apple Silicon Mac** (M1 or newer) with enough unified memory for the model
  you pick (see the RAM guidance in Step 2). The app adapts its warnings to your
  Mac's actual RAM.
- **macOS 14+** (Sonoma) — the app's minimum.
- **Python 3.10+** with `pip`. Everything runs on Python — `mlx-lm`, the `hf`
  download tool, and the server itself. Install with `xcode-select --install`
  (provides `/usr/bin/python3`), `brew install python@3.12`, or python.org.
- **Xcode 26** or newer (for the Xcode integration; Xcode 26.2+ recommended).
- **~19 GB free disk** for the default Qwen3.5-35B-A3B MoE (4-bit).

**Auto-installed / detected (each missing item shows a warning + a fix):**

| Dependency | Why it's needed | Missing → the app does |
|---|---|---|
| **Python 3** | base runtime for mlx-lm, `hf`, and the server | warning + "How to install Python" instructions |
| **mlx-lm** (`mlx_lm.server`) | the local server | one-click **Install** (`pip install mlx-lm uvicorn fastapi huggingface_hub 'brotli>=1.2.0'`) |
| **`hf` CLI** (`huggingface_hub`) | downloads models | one-click **Install** (`pip install huggingface_hub 'brotli>=1.2.0'`) |
| **Model files** | the weights to serve | one-click **Download** with a progress bar |
| **OpenCode** | recommended agent | "How to install OpenCode" fold-out (not pip — manual) |
| **OpenCode config** | points OpenCode at the server | one-click **Set up** |
| **Claude Code** | optional agent | "How to install Claude Code" fold-out |
| **Claude Code profile** | points Claude Code at the bridge | one-click **Set up** |
| **LiteLLM** | Anthropic→OpenAI bridge for Claude Code | one-click **Install** into its own venv |
| **LiteLLM config** | bridge config | one-click **Set up / Update** |

- **Node.js is not a direct requirement**, but OpenCode and Claude Code are Node
  CLIs, so Node gets installed by their installers (`npm`/`nvm`). The app detects
  those CLIs, not Node itself.
- **No Hugging Face account is needed.** All models are public `mlx-community`
  repos; `hf download` works anonymously, and the app never asks for a token.

When the app opens, a **"Missing prerequisites"** banner lists everything still
needed (Python included) so you know at a glance what to install and where.

---

## Quick start — one command (non-GUI)

Skip the manual steps below: `setup.sh` checks every prerequisite, installs
what's missing (`mlx-lm`, `hf`/`huggingface_hub`, `uvicorn`/`fastapi`, the
LiteLLM venv, and the OpenCode CLI), then downloads a model of your choice and
writes the OpenCode + Claude Code configs that point at it.

```bash
./setup.sh                                          # check + install + pick a model (interactive menu)
./setup.sh --check                                  # only report status, install nothing
./setup.sh --yes                                    # non-interactive: install everything + the default model
./setup.sh --model mlx-community/Qwen3-14B-4bit     # a specific model
```

The menu offers the same 15 models as the app (see the table in Step 2).
Everything below is the manual, step-by-step version of what `setup.sh` does.

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

The model must be **MLX format** — i.e. a pre-converted weight from the
[`mlx-community` organization on Hugging Face](https://huggingface.co/mlx-community).
The Qwen3-family models are the ones that **support tool calling** reliably for
agents (Xcode / OpenCode / Claude Code); the rest are great for chat and
generation but aren't the pick for agentic work. Pick one that fits your RAM;
4-bit weights ≈ (parameters in billions) × 0.55 GB.

| Model | 4-bit weight (RAM) | Max context | Thinking | Tool calling | Notes |
|-------|-------------------|-------------|----------|--------------|-------|
| `mlx-community/Qwen3.5-35B-A3B-4bit` | 18 GB | 262,144 | ✅ | ✅ | **Default.** MoE coder (3B active → fast); tool calls parse reliably. |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | 18 GB | 262,144 | ✅ | ✅ | MoE coder (3B active), newer sibling of the default. |
| `mlx-community/Qwen3.8-27B-4bit` | 14 GB | 262,144 | ✅ | ✅ | 27B mid-size option. |
| `mlx-community/Qwen3-14B-4bit` | 7 GB | 40,960 | ✅ | ✅ | Smaller; natural pick for "concurrent requests" mode. |
| `mlx-community/Qwen3.5-9B-4bit` | 6 GB | 262,144 | ✅ | ✅ | Compact daily driver. |
| `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | 4.28 GB | 32,768 | — | — | Code specialist; chat/generation only. |
| `mlx-community/Qwen3.5-4B-4bit` | 3.03 GB | 262,144 | ✅ | ✅ | Tiny + long context. |
| `mlx-community/Qwen3.5-2B-4bit` | 1.72 GB | 262,144 | ✅ | ✅ | Smallest Qwen. |
| `mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit` | 15.10 GB | 393,216 | — | — | Mistral coding specialist; chat/generation only. |
| `mlx-community/gemma-4-12B-it-qat-4bit` | 10.99 GB | 262,144 | — | — | Google, multilingual; chat/generation only. |
| `mlx-community/Ministral-3-8B-Instruct-2512-4bit` | 5.60 GB | 262,144 | — | — | Edge/on-device, multilingual; chat/generation only. |
| `mlx-community/gemma-4-e4b-it-4bit` | 5.15 GB | 131,072 | — | — | Efficient + vision; chat/generation only. |
| `mlx-community/gemma-4-e2b-it-4bit` | 3.55 GB | 131,072 | — | — | Small + vision; chat/generation only. |
| `mlx-community/Ministral-3-3B-Instruct-2512-4bit` | 2.75 GB | 262,144 | — | — | Tiny, multilingual; chat/generation only. |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | 1.81 GB | 131,072 | — | — | On-device, multilingual; chat/generation only. |

> **Use only the Qwen3-family models for agent/tool-calling work.** The rest of
> the list (Llama, Gemma, Ministral, Devstral, and Qwen2.5-Coder) are chat and
> generation models — as coding agents they emit raw tool-call JSON that
> mlx_lm.server can't parse, so OpenCode/Xcode/Claude Code just see the raw text
> (e.g. `{ "name": …, "parameters": {} }`) instead of an answer. (`Qwen3-Coder-30B-A3B`
> drops the `<tool_call>` wrapper and `Qwen2.5-Coder-14B` wraps its call in
> `<tools>` instead — same symptom.)

Download the model you picked (or run `./setup.sh`, which does this for you —
the server also auto-downloads on first launch). The repo ids are in the table
above; the default is:

```bash
hf download mlx-community/Qwen3.5-35B-A3B-4bit   # default
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

> **35B-A3B MoE — KV-cache fix.** The MoE's ~19 GB weights fit in RAM on most
> Apple Silicon Macs, but its full-precision (16-bit) KV cache overflows Metal
> GPU memory during long agent prompts — the server dies with
> `[METAL] … Insufficient Memory` → `generation thread died`. `start_server.sh`
> sets `--kv-bits 4` (and `--max-tokens 8192`) to stay in budget. If output
> quality suffers, try `KV_BITS=8 ./start_server.sh …`, but that doubles KV memory
> and may re-trigger the OOM on long prompts.

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

The model you pick in the app is served under the alias `default_model`, and
Xcode reaches it through OpenCode's `acp` server. The chain is:

```
Xcode → OpenCode (acp) → MLX-LM server (127.0.0.1:8080/v1) → default_model
```

### A. Register OpenCode as an ACP agent (in-editor assistant)

The ACP agent is OpenCode's `acp` server, so set up OpenCode first, then register
it in Xcode.

1. **Pick and download a model** — select it in the menu-bar app (or run
   `./setup.sh`), then press **Start**. The server serves *whatever model is
   loaded* as `default_model` on `http://127.0.0.1:8080/v1`.
2. **Point OpenCode at it** — the app's Install / `setup.sh` already write
   `~/.config/opencode/opencode.jsonc` using `mlx/default_model` (see "Use it in
   OpenCode" below). If you switch models, re-run that setup so the context
   length matches the new model, or edit the file by hand.
3. **Add the agent in Xcode** — open the **Add an ACP Agent** dialog and fill in:
   - **Executable**: `/path/to/opencode` (your OpenCode
     binary — find it with `which opencode`)
   - **Arguments**: `acp`
   - **Interpreter**: (empty)
   - **Environment variables**: (empty)
4. **Save it** — Xcode's in-editor chat now runs through OpenCode on your local
   model. Switch models by repeating steps 1–2; Xcode needs no changes.

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
> context length (see the model table in Step 2) so OpenCode knows how much it
> can send. The menu-bar app and `setup.sh` write this for you from each model's
> profile; this sample shows the Qwen3.5 value (262144).

---

## Use it in Claude Code

> ## ⚠️ Claude Code is crashing — use OpenCode instead
>
> Claude Code is currently crashing/hanging on the local model (empty replies,
> stalled turns, and it can wedge the server's single generation thread).
> **Do not rely on Claude Code for local work right now — use
> [OpenCode](#use-it-in-opencode) instead.** The setup below is kept so it's
> ready when this is fixed.

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

> **Why port 4001, not 4000?** Port 4000 is commonly taken by another LiteLLM
> instance. Keeping this bridge on 4001 avoids a bind collision, so the two can
> run at the same time.

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

## Which agent to use

The same local model drives every agent, but they're **not interchangeable** —
the prompt each one sends decides speed and whether caching helps.

| Agent | Prompt per turn | Speed (35B, Apple Silicon) | Use it for |
|-------|----------------|------------------------|------------|
| **OpenCode** | small — ~15k tokens | fast, prompt caches well | **Everyday local agent work — the recommended choice.** |
| **Xcode** (via OpenCode `acp`) | small | fast | In-editor assistant and agent-driven app building. |
| **Claude Code** | ~66k-token system prompt (measured; more with extra MCP servers + skills) | slow — minutes/turn, cache can't help | Occasional use, after trimming MCP servers/skills. |
| **curl / OpenAI SDK** | tiny | fast | Quick smoke test or a script. |

**Why Claude Code is slow:** it resends its system prompt every turn — ~66k
tokens on a trimmed setup (OpenCode: ~15k), up to ~85k with all MCP servers +
skills. That prompt's 4-bit KV cache fills the app's default
`--prompt-cache-bytes 6GB` cap, and the cache must hold the prompt twice (stored
+ in-flight), so every turn re-prefills the whole thing (`system: 0 sequences` in
the server log). Claude Code also sends `max_tokens=32000` on every request,
overriding the server's `--max-tokens 8192`, so cap output client-side
(`CLAUDE_CODE_MAX_OUTPUT_TOKENS`, written by the app). To make it usable: trim
MCP servers/skills, keep Thinking mode off, keep Max tokens at 8192, or raise
**Prompt cache** in Model settings. For most local work, **OpenCode is the better
default.**

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
  on Macs where the model and its KV cache don't both fit). Relaunch with
  `--kv-bits 4` (or `8`) — `start_server.sh` already does this. Reduce the
  client's context/`max_tokens` if it persists.
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

- `setup.sh` — one-command terminal setup: check/install prerequisites, download a model, write configs.
- `start_server.sh` — launches the MLX-LM server with the KV-cache + sampling fixes.
- `litellm-mlx.yaml` — LiteLLM config for the Anthropic→OpenAI bridge.
- `claude-local.sh` — launches Claude Code pointed at the local bridge.
- `MLXServer/` — native menu-bar app to start/stop the server and switch models.
- `CHANGELOG.md` — release history (versions, features, and fixes).

---

## License

This project is MIT-licensed. See the [`LICENSE`](LICENSE) file for details.
