# MLX Server (menu bar app)

A small native macOS **menu-bar app** that starts and stops the local
`mlx_lm.server` for the **Qwen3.5-35B-A3B** model, so you don't have to run
`./start_server.sh` by hand. It lives in the menu bar, next to the clock.

## What it does

- **Start / Stop** the MLX-LM server (OpenAI-compatible,
  `http://127.0.0.1:8080/v1`).
- **Pick the model** — 15 models (Qwen3.5/3.6-35B-A3B, Qwen3.8-27B, Qwen3-14B,
  Qwen3.5-9B/4B/2B, Qwen2.5-Coder-7B, Devstral 24B, Gemma 4, Ministral 3, and
  Llama 3.2 3B), each with its own profile, description, and highlights.
- Shows a **live log** of the server (model load progress, requests, errors).
- Lets you override the **port** and the **`mlx_lm.server` path** under *Advanced*.
- **Model settings** — per-model **thinking mode** toggle and **max context**
  (read from each model's profile), plus temperature, top-p, top-k, and max
  tokens (applied on the next Start); **Reset to defaults** restores the shipped
  values.
- A **folder** button next to the model files and the OpenCode config opens that
  folder in Finder (the model cache, or `~/.config/opencode`).
- **OpenCode setup, automatic or manual** — writes (or shows you) a global
  OpenCode config pointing at the server (see below).
- A **Connect** tab with everything you need to call the model from custom code
  (base URL, model name, endpoints, ready-to-paste `curl` and Python examples).

The server is launched with `start_server.sh`'s defaults, all configurable in
the **Model settings** section (thinking mode, temperature, top-p, top-k, max
tokens):

```
--model <model> --host 127.0.0.1 --port <port> \
  --kv-bits 4 --max-tokens 8192 --temp 0.2 --top-p 0.8 --top-k 20 \
  --chat-template-args '{"enable_thinking":false}'
```

## Requirements check

When the panel opens it verifies **everything** the stack needs and shows a
prominent **"Missing prerequisites"** banner at the top listing what's still
needed, so a fresh machine knows at a glance what to install and where. Each item
also has its own row in the **Requirements** list with a one-click fix (or an
install instruction) when it's missing:

| Dependency | Why it's needed | Missing → the app does |
|---|---|---|
| **Python 3** | base runtime for mlx-lm, `hf`, and the server | warning + "How to install Python" instructions |
| **mlx-lm** (`mlx_lm.server`) | the local server | **Install** (`pip install mlx-lm uvicorn fastapi huggingface_hub 'brotli>=1.2.0'`) |
| **`hf` CLI** (`huggingface_hub`) | downloads models | **Install** (`pip install huggingface_hub 'brotli>=1.2.0'`) |
| **Model files** | the weights to serve | **Download** with a live progress bar |
| **OpenCode** | recommended agent | "How to install OpenCode" fold-out |
| **OpenCode config** | points OpenCode at the server | **Set up** / **Manual** |
| **Claude Code** | optional agent | "How to install Claude Code" fold-out |
| **Claude Code profile** | points Claude Code at the bridge | **Set up** |
| **LiteLLM** | Anthropic→OpenAI bridge for Claude Code | **Install** into its own venv |
| **LiteLLM config** | bridge config | **Set up** / **Update** |

The checks run when you open the panel and whenever you switch models, and
"Check status" re-runs them after you install something. Python is the one item
the app can't install for you, so its row shows clear install steps
(`xcode-select --install`, `brew install python@3.12`, or python.org) — no
Hugging Face account or `hf login` is ever needed, since the models are public.

## Concurrent requests

By default the server uses a **4-bit KV cache** (`--kv-bits 4`), which keeps big
models inside Metal memory but makes `mlx_lm.server` serve requests one at a time.

For a **smaller model**, turn on **Advanced → Allow concurrent requests**. This
drops the quantized KV cache (full precision), so the server can batch concurrent
requests in parallel (`--prompt-concurrency` / `--decode-concurrency`). It's **off
by default** because it needs more memory — enable it only when the model leaves
room to spare. The setting is remembered and only takes effect on the next Start.

## OpenCode setup (automatic or manual)

The **Integrations** section first checks whether the `opencode` CLI is
installed. If it isn't, the automatic setup button is disabled and the panel
shows the one-liner to install it:

```bash
curl -fsSL https://opencode.ai/install | bash
```

Once OpenCode is present, you choose how to set up the config that points it at
this server (`~/.config/opencode/opencode.jsonc`):

- **Automatic** — click **Set up**. It writes the config for you, using the
  app's **current port** and **selected model**, and backs up any existing
  `opencode.jsonc` to a timestamped `.bak-…` file before overwriting.
- **Manual** — click **Manual** to see the exact config text, then write it
  yourself (or click **Copy config**). Click **Verify** to re-check it.

The config sets `model: "mlx/default_model"`,
`baseURL: http://127.0.0.1:<port>/v1`, a `limit.context` matching the selected
model's **max context** (from its profile), and a `limit.output` matching the
app's configured **Max tokens** (so a mid-generation disconnect can't wedge the
single generation thread — see the main repo `README.md`).

Because the config is **port-specific**, the status re-checks the current port
every time the panel opens (and whenever you change the port):

| Status | Meaning |
|--------|---------|
| ✓ configured for port N | config points at the current port — done |
| ⚠ points at port M, not N | stale port — click **Update** to fix |
| ⚠ no config yet | missing — **Set up** or **Manual** |

Once the config correctly points at the current port, the automatic button is
hidden so a setup you did by hand can't be overwritten by an accidental click.

## Connect info (tab)

The **Connect** tab shows what any OpenAI-compatible client needs to reach the
running server, live-updated for the current port and model:

- **Base URL** — `http://127.0.0.1:<port>/v1`
- **Model** — use `default_model` (the alias `mlx_lm.server` serves the loaded
  model under, regardless of which model you selected)
- **Loaded model (HF id)** — the actual `mlx-community/…` model behind the alias
- **Endpoints** — `POST /v1/chat/completions` (chat + tool calling) and
  `GET /v1/models`
- **curl** and **Python (OpenAI SDK)** examples, with copy buttons.

`api_key` is not checked — pass any non-empty value (e.g. `"not-needed"`).

## Build & run

Open `MLXServer.xcodeproj` in Xcode and press **Run**, or build from the terminal:

```bash
xcodebuild -project MLXServer.xcodeproj -target MLXServer -configuration Debug build
```

The app runs as a **menu bar extra** (no Dock icon — `LSUIElement`). Click its
icon (a circle) next to the clock to open the control panel. The icon shape
tracks the server state:

| Icon | State |
|------|-------|
| `○` circle | stopped |
| `◌` circle.dotted | starting / stopping |
| `●` circle.fill | running |
| `!` exclamationmark.circle | failed |

## Quitting

Because it's a menu-bar-only app (no Dock icon or menu bar), you quit it from
inside the panel:

- Click **Quit MLX Server** at the bottom of the panel, or
- press **⌘Q**.

Quitting first stops the model server and every process it spawned (SIGTERM,
then SIGKILL if anything lingers), and as a final safety net sweeps the
configured port to kill any `mlx_lm.server` still listening there — so you never
leave an orphaned server holding the port.

### Can't delete the app ("it's in use")

If you try to drag `MLXServer.app` out of Applications (or empty the Trash) and
macOS says it's **in use**, that just means the app is still running — the
running process holds the `.app` bundle open. Quit it first, then delete:

1. Quit from inside the app (**Quit MLX Server** or **⌘Q**), or quit it from a
   terminal:
   ```bash
   osascript -e 'tell application "MLXServer" to quit'
   ```

2. If that doesn't work (or it already crashed and left the process behind),
   find and kill the leftover process:
   ```bash
   pkill -f '/Applications/MLXServer.app/Contents/MacOS/MLXServer'
   ```

   (If the app lives elsewhere, point the path at wherever you installed it.)

Then delete `MLXServer.app` as usual. You can confirm nothing is left running
with:

```bash
ps aux | grep -iE 'MLXServer|mlx_lm.server' | grep -v grep
```

## How it finds `mlx_lm.server`

GUI apps don't inherit your shell `PATH`, so the app auto-detects the binary by
checking common install locations (`/opt/anaconda3/bin/mlx_lm.server`,
`/opt/homebrew/bin/…`, `~/miniconda3/bin/…`, …) and falls back to asking your
login shell (`zsh -ic "command -v mlx_lm.server"`). If it still can't find it,
paste the full path into **Advanced → mlx_lm.server path** (blank = auto-detect).

## Adding more models later

Edit `ServerController.availableModels` in `MLXServer/ServerController.swift`:

```swift
static let availableModels: [ModelOption] = [
    ModelOption(repoID: "mlx-community/Qwen3.5-35B-A3B-4bit",
                displayName: "Qwen3.5-35B-A3B (4-bit)",
                profile: ModelProfile(maxContext: 262_144, thinkingSupported: true,
                                      toolCallingSupported: true, weightGB: 18)),
    ModelOption(repoID: "mlx-community/Qwen3-14B-4bit",
                displayName: "Qwen3-14B (4-bit)",
                profile: ModelProfile(maxContext: 40_960, thinkingSupported: true,
                                      toolCallingSupported: true, weightGB: 7)),
    ModelOption(repoID: "mlx-community/Your-New-Model-4bit",
                displayName: "Your New Model (4-bit)",
                profile: ModelProfile(maxContext: 32768, thinkingSupported: false,
                                      toolCallingSupported: false, weightGB: 4)),
]
```

Each model carries a **profile** with four fields:

- `maxContext` — the model's maximum context length (its
  `max_position_embeddings`); this is shown in **Model settings** and written to
  the OpenCode config's `limit.context`. This is the single per-model "max".
- `thinkingSupported` — whether the model's chat template accepts
  `enable_thinking`; when false the **Thinking mode** toggle is disabled for that
  model.
- `toolCallingSupported` — whether the model reliably emits parseable tool calls
  for coding agents (OpenCode / Claude Code). Only the Qwen3-family models set
  this true; chat models (Llama, Gemma, Ministral, Devstral, Qwen Coder) set it
  false and show a warning when selected.
- `weightGB` — approximate 4-bit weight RAM, used by the memory-safety guard.

The **Max tokens** output limit is *not* per-model — every Qwen3-family model
generates at most 32,768 tokens per response, so it lives as a single constant
(`ModelDefaults.maxOutputTokens`).

`thinking` (on/off) is a **per-model** preference: each model remembers its own
toggle state independently, defaulting to **off**.

Download the model first (the server also auto-downloads on first launch). The
selected model is remembered across launches.

> Only use a model whose tool-call format `mlx_lm.server` can actually parse —
> for agent work that's the Qwen3-family models. See the main repo `README.md`.
