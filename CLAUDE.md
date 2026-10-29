# Mac Local AI Setup with Xcode Support

A fully **local** agentic AI stack for Apple Silicon: run a Qwen model with MLX-LM
behind an OpenAI-compatible HTTP API, and use it as the model for Xcode, Claude
Code, and OpenCode — no cloud, no API keys. Full user-facing docs are in
[`README.md`](README.md); this file is the agent-facing map and the invariants you
must not break.

## Architecture (4 layers)

```
Agent (Xcode / Claude Code / OpenCode / curl / OpenAI SDK)
   │  OpenAI chat-completions  (POST /v1/chat/completions)
MLX-LM server  (mlx_lm.server)  ← serves the loaded model as `default_model`
   │
MLX-LM  (pip package: load / run / quantize / fine-tune)
   │
MLX  (Apple's Metal / Neural-Engine array framework, unified memory)
```

The one fact that connects everything: the server exposes **whatever model is
loaded under the alias `default_model`** on `http://127.0.0.1:8080/v1`.

## Repo layout

- `MLXServer/` — the **product**: a native macOS menu-bar app (Swift/SwiftUI).
  - `MLXServer/MLXServer/ServerController.swift` — owns the `mlx_lm.server` and
    LiteLLM-bridge subprocesses, the model list, settings, and the memory-safety guard.
  - `MLXServer/MLXServer/ContentView.swift` — the SwiftUI control panel.
  - `MLXServer/MLXServer/MLXServerApp.swift` — app entry / menu-bar lifecycle.
  - `MLXServer/MLXServer.xcodeproj` — the Xcode project.
  - `MLXServer/build/` — (gitignored) build products, signed `.app`, and release `.zip`.
- `start_server.sh` — terminal launcher for `mlx_lm.server` (KV-cache + sampling fixes).
- `claude-local.sh` — launches Claude Code pointed at the local LiteLLM bridge.
- `litellm-mlx.yaml` — LiteLLM config translating Anthropic → OpenAI for the bridge.
- `.venv-litellm/` — (gitignored) isolated venv for `litellm[proxy]`.
- `README.md` — full user docs. `CHANGELOG.md` — release history.

## Two ways to run it

1. **Menu-bar app (recommended):** build `MLXServer/`, run it, click **Start**. It
   installs mlx-lm, downloads the model, writes OpenCode + Claude Code config, and
   starts the server + bridge.
2. **Terminal:** `./start_server.sh` (server on 8080), then for Claude Code:
   `.venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port 4001`
   and `./claude-local.sh`.

## Models

Only these (in `ServerController.availableModels`) work for **agent/tool-calling**
use. `weightGB` is the guard's conservative RAM estimate.

| repoID | weightGB | maxContext | thinking |
|---|---|---|---|
| `mlx-community/Qwen3.5-35B-A3B-4bit` | 18 | 262144 | yes |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | 18 | 262144 | yes |
| `mlx-community/Qwen3.8-27B-4bit` | 14 | 262144 | yes |
| `mlx-community/Qwen3-14B-4bit` | 7 | 40960 | yes |

Do **not** switch to `Qwen3-Coder-30B-A3B` or `Qwen2.5-Coder-14B` for agents — they
emit tool calls the server can't parse and stall the loop.

## Critical invariants (do not violate)

- **Memory safety / whole-machine OOM.** The 35B model combined with "Allow
  concurrent requests" (full-precision KV cache, no byte cap) exhausts 36 GB of
  unified memory and can take the *entire Mac* down — not just the server. The app
  enforces this in `ServerController`: `concurrentRequestsSafe` requires
  `model.weightGB <= physicalRAMGB / 4`; `start()` hard-blocks otherwise, the
  toggle is disabled for too-large models, and launching auto-clamps the setting.
  Keep this guard intact.
- **KV-cache quantization is load-bearing.** 35B on 36 GB needs `--kv-bits 4`
  (+ `--max-tokens 8192`). Full-precision KV OOMs on long agent prompts.
- **LiteLLM lives in its own venv** (`.venv-litellm`): it pins `tokenizers==0.22.2`
  while mlx-lm's transformers needs `>=0.23.1`.
- **Ports.** MLX server = `8080`; LiteLLM bridge = `4001` (NOT 4000 — that's
  commonly taken by another LiteLLM instance).
- **Thinking mode off for agents** — it emits a hidden `<think>…</think>` preamble
  instead of the answer, so Claude Code/OpenCode stall or return empty.
- **OpenCode `limit.output` must match the server's max tokens** (8192). OpenCode
  otherwise hard-codes 32000 and can wedge the single generation thread.
- **Sampling params matter.** `mlx_lm.server` ignores `generation_config.json` and
  defaults to greedy decoding with no repetition penalty → repetition loops. The
  scripts/app set `--temp 0.2 --top-p 0.8 --top-k 20`.
- **Prompt cache must be sized ~2× the system prompt** (`--prompt-cache-bytes`,
  Model settings). Claude Code's ~85k-token system prompt quantizes to ~6 GB,
  which fills the 6 GB default and defeats caching (`system: 0 sequences`). See
  [Agent recommendations](#agent-recommendations-which-agent-for-which-job).

## Agent recommendations (which agent for which job)

The local model can drive several agents, but they are **not interchangeable**:
their prompt sizes differ by ~10×, which decides speed and whether the prompt
cache works at all.

| Agent | Prompt / turn | Speed (35B, M4 Max) | Verdict |
|---|---|---|---|
| **OpenCode** | small (a few k tokens) | fast — prompt caches well | **Recommended for local agent work.** |
| **Xcode (via OpenCode `acp`)** | small | fast | Same OpenCode path. |
| **Claude Code** | ~85k-token system prompt (built-in tools + every MCP server + every skill) | slow — 6–8 min/turn, cache can't help | Occasional use only; trim MCP/skills first. |
| **curl / OpenAI SDK** | tiny | fast | Quick smoke test or a script. |

Why Claude Code is slow here: it resends its full ~85k-token system prompt on
every message, and that prompt's 4-bit KV cache is ~6 GB — exactly the size of
the default `--prompt-cache-bytes 6GB` cap. The cache therefore can't hold the
system prompt twice (stored copy + in-flight copy), the server log shows
`system: 0 sequences`, and every turn re-prefills the whole prompt. OpenCode's
small prompt caches fine.

To make Claude Code usable (if you need it):
1. **Trim MCP servers/skills** — they are the main system-prompt bloat. For local
   work you usually need zero or one of them. Disable the rest
   (`claude mcp remove <name>`, or scope them off for this project).
2. **Keep Thinking mode off** and **Max tokens at 8192** (the app defaults).
3. **Raise `--prompt-cache-bytes`** (Model settings → Prompt cache) to ~2× your
   system prompt if the Mac has spare RAM — but shrinking the prompt is the
   better fix, since a 35B model already leaves little RAM free.
4. Or just use **OpenCode**, the recommended local agent.

## Build & release

```bash
cd MLXServer
xcodebuild -project MLXServer.xcodeproj -scheme MLXServer \
  -configuration Release -destination 'platform=macOS' \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - build/Release/MLXServer.app   # ad-hoc sign
ditto -c -k --keepParent build/Release/MLXServer.app \
  build/MLXServer-<version>-macos.zip
```

The signed `.app` lands in `MLXServer/build/Release/`, the zip in `MLXServer/build/`.
Version/build are the Xcode target's `CFBundleShortVersionString` / `CFBundleVersion`
(check `MLXServer/MLXServer.xcodeproj` or the built Info.plist).

## Key endpoints (when running)

- `GET  http://127.0.0.1:8080/v1/models` — server health / cached models.
- `POST http://127.0.0.1:8080/v1/chat/completions` — OpenAI chat + tool calling.
- `POST http://127.0.0.1:4001/v1/messages` — LiteLLM bridge (Anthropic API for Claude Code).
