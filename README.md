# Mac Local AI Setup with Xcode Support

Run a fully **local** agentic AI stack on an Apple Silicon Mac — no cloud, no API
keys — and use it as the model behind your coding agents and Xcode itself.

This is a from-scratch setup based on Apple's **WWDC26 session "Run local
agentic AI on the Mac using MLX"**
([video](https://www.youtube.com/watch?v=wykPErJ8M-8)). It works with:

- **Xcode** (its built-in "Intelligence" tab → locally hosted provider)
- **Claude Code** (the CLI, pointed at the local model through a bridge)
- **OpenCode** (the open-source coding agent)

Everything runs on your own hardware. Your code never leaves your Mac.

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
- ~20 GB free disk for a 30B-class 4-bit model (less for smaller models).

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
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | ~17 GB | **Recommended.** Purpose-built coder, MoE (3B active → fast). Strong Swift + tool calling. |
| `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit` | ~9 GB | Solid, lighter coder. |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | ~20 GB | Largest general MoE (the family Apple's demo used). |
| `mlx-community/Qwen3.5-4B-8bit` | ~5 GB | Small test model from the video's slide — good for smoke-testing, weak for real coding. |

Download (or skip this — the server auto-downloads on first launch):

```bash
hf download mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
```

---

## Step 3 — Start the server

```bash
mlx_lm.server --model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
```

The server loads the model and listens on `http://127.0.0.1:8080` (port `8080`
by default). Useful flags: `--host`, `--port`, `--max-tokens`, `--temp`.

**Smoke-test it** in another terminal:

```bash
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "default_model", "messages": [{"role": "user", "content": "Hello!"}]}'
```

Endpoints exposed:
- `POST /v1/chat/completions` — OpenAI chat completions (with tool calling)
- `GET /v1/models` — returns `default_model`

---

## How to use it day-to-day

### Chat from the terminal (no server)

```bash
mlx_lm chat --model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
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

There are **two ways** to use the local model with Xcode — the video demos both.

### A. Direct Xcode integration (in-editor assistant)

Xcode 26 has a built-in "Intelligence" panel that can talk to a locally hosted
OpenAI-compatible server — exactly what MLX-LM provides.

1. Start the MLX-LM server (Step 3 above) and leave it running.
2. In Xcode, open **Settings** (⌘,).
3. Go to the **Intelligence** tab.
4. Click **Add Sub Provider** → select **Locally Hosted Provider**.
5. Set the **port to `8080`** (or whichever port you launched the server with).
6. Done — Xcode's assistant now reads project files, understands build errors,
   and makes targeted fixes using your local model.

> **Model-picker gotcha:** Xcode queries `/v1/models`, which lists *every* cached
> model, not just the loaded one. If Xcode shows a picker, choose
> **`Qwen3-Coder-30B-A3B-Instruct-4bit`** — that's the model loaded in RAM.
> Picking one of the other (VL) models makes the server try to load a second
> ~17 GB model and likely run out of memory.

### B. Agent-driven development (build the app for you)

This is what the video's "drawing iPad app from scratch" demo actually did: an
**agent** writes the code and runs `xcodebuild` to compile and fix it, while the
project is open in Xcode.

1. Open (or create) your Xcode project.
2. Launch the agent on the local model — `claude-local` (see the Claude Code
   section below) or OpenCode pointed at `mlx/default_model`.
3. Ask it to build a feature; it writes files, runs `xcodebuild`, reads the
   errors, and iterates until it compiles.

Both paths keep your code entirely on your Mac — nothing is sent to the cloud.

---

## Use it in OpenCode

[OpenCode](https://opencode.ai) is an open-source terminal coding agent. Point it
at the local server with an `opencode.json` (project root or `~/.config/opencode/`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "mlx/default_model",
  "small_model": "mlx/default_model",
  "provider": {
    "mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "MLX (local)",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {
        "default_model": {
          "name": "Default MLX Model"
        }
      }
    }
  }
}
```

`mlx/default_model` means "provider `mlx`, model `default_model`" — matching the
name the MLX-LM server serves. Start OpenCode and every interaction now runs
through your local model.

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
      model: openai/default_model          # "openai/" = OpenAI-compatible backend
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
.venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port 4000
```

### 3. Verify the bridge before touching Claude Code

```bash
curl -sS -X POST http://127.0.0.1:4000/v1/messages \
  -H "Authorization: Bearer sk-local-claude" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"default_model","max_tokens":32,"messages":[{"role":"user","content":"Say hi"}]}'
```

Success is a body starting with `{"id":"msg_…"` containing a `content` array.

### 4. Point Claude Code at the bridge

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
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
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_AUTH_TOKEN": "sk-local-claude",
    "ANTHROPIC_MODEL": "default_model",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "default_model",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

### 5. One-command launcher (bash function)

This repo is set up with a `claude-local` shell command — the same structure as a
typical DeepSeek-in-Claude-Code setup (an env file holds the endpoint, a bash
function points Claude Code at it). Only `~/.bashrc` is touched; `.zshrc` is left
alone.

`~/.config/mlx-local/claude-code.env`:
```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:4000"
export ANTHROPIC_AUTH_TOKEN="sk-local-claude"
```

In `~/.bashrc`:
```bash
claude-mlx() {
  source ~/.config/mlx-local/claude-code.env
  export ANTHROPIC_MODEL="default_model"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="default_model"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="default_model"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="default_model"
  export CLAUDE_CODE_SUBAGENT_MODEL="default_model"
  export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
  export MAX_THINKING_TOKENS=0
  claude "$@"
}
alias claude-local='claude-mlx'
```

Then, with both servers running:
```bash
source ~/.bashrc   # once per shell, or open a new terminal
claude-local       # (or claude-mlx)
```

This scopes the local model to a single command — unlike the persistent
`~/.claude/settings.json` `env` block above — so your normal Claude Code login is
left untouched.

### Caveats (be realistic)

- Anthropic does **not** support routing Claude Code to non-Claude models; this
  runs "best-effort" through the gateway.
- Tool calling is translated by LiteLLM, but the agent loop (many tools, long
  multi-turn context) is where a local model breaks first — test with a
  single-tool prompt before relying on it.
- Keep `CLAUDE_CODE_MAX_OUTPUT_TOKENS` below the backend limit, and expect the
  local model to be slower than cloud Claude.

---

## Performance notes (from the video)

- **Neural accelerators** (M5): MLX targets them automatically — ~4× faster
  matrix multiplication vs M4, which translates almost 1:1 to faster prompt
  processing (important for agents reading large codebases). No code changes.
- **Continuous batching**: the server batches concurrent requests on the GPU, so
  parallel sub-agents don't queue — they're served concurrently.
- **Distributed inference** (advanced): MLX can spread a model across multiple
  Macs over Thunderbolt/Ethernet to run models too large for one machine. This
  is covered in Apple's separate session "Explore Distributed Inference and
  Training with MLX".

---

## Troubleshooting

- **`yt-dlp`/download issues** — see `EXTRACTION.md` (this repo) for the exact
  commands that worked.
- **Port already in use** — pass `--port 8081` and update every client's URL.
- **Server says model not found** — make sure the model was downloaded to the
  default HuggingFace cache, or pass the local path instead of the HF id.
- **Slow first token** — first request compiles kernels; subsequent requests are
  faster.
- **Tool calls malformed** — ensure you picked a model that supports tool
  calling (all the Qwen3-Coder / Qwen2.5-Coder / Qwen3.6 models above do).

---

## Related files in this repo

- `EXTRACTION.md` — how the video was turned into transcript + OCR (the source
  for this guide).
- `video/` — downloaded audio/video, transcript, frames, and OCR output.
- `scripts/ocr_all.swift` — the Swift/Apple-Vision OCR CLI used for the frames.
