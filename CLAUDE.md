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

There is a **second runtime path** for OptiQ-quantized models (mixed 4/8-bit per
layer with an MTP sidecar): stock `mlx_lm.server` can't load them, so the `optiq`
package registers the architecture and the server launches via
`python -c "import optiq; from mlx_lm.server import main; main()"`. This is gated
by `ModelProfile.requiresOptiQ` in `ServerController` and `OPTIQ_MODELS` in
`start_server.sh`; `setup.sh` and the app both install `mlx-optiq`.

## Repo layout

- `MLXServer/` — the **product**: a native macOS menu-bar app (Swift/SwiftUI).
  - `MLXServer/MLXServer/ServerController.swift` — owns the `mlx_lm.server` and
    LiteLLM-bridge subprocesses, the model list, settings, and the memory-safety guard.
  - `MLXServer/MLXServer/ContentView.swift` — the SwiftUI control panel.
  - `MLXServer/MLXServer/MLXServerApp.swift` — app entry / menu-bar lifecycle.
  - `MLXServer/MLXServer.xcodeproj` — the Xcode project.
  - `MLXServer/build/` — (gitignored) build products, signed `.app`, and release `.zip`.
- `setup.sh` — one-command terminal setup: check/install prerequisites, download a model, write OpenCode + Claude Code configs.
- `install.sh` — one-line `curl | bash` installer: fetches the latest GitHub release and installs `MLXServer.app` via curl/ditto, so no Gatekeeper quarantine (version-agnostic; README points at `main/install.sh`).
- `start_server.sh` — terminal launcher for `mlx_lm.server` (KV-cache + sampling fixes).
- `claude-local.sh` — launches Claude Code pointed at the local LiteLLM bridge.
- `litellm-mlx.yaml` — LiteLLM config translating Anthropic → OpenAI for the bridge.
- `.venv-litellm/` — (gitignored) isolated venv for `litellm[proxy]`.
- `README.md` — full user docs. `CHANGELOG.md` — release history.

## Two ways to run it

1. **Menu-bar app (recommended):** build `MLXServer/`, run it, click **Start**. It
   installs mlx-lm (and mlx-optiq, for OptiQ models), downloads the model, writes
   OpenCode + Claude Code config, and starts the server + bridge.
2. **Terminal:** `./setup.sh` installs the prerequisites and downloads a model,
   then `./start_server.sh` (server on 8080); for Claude Code:
   `.venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port 4001`
   and `./claude-local.sh`.

## Models & capability classification

`ServerController.availableModels` is the single source of truth for the picker
(34 models). Every model is classified by a **primary capability tag**, which must
be the *first* entry in its `highlights` array, plus optional modifiers. The tag
vocabulary is fixed — don't invent new primary tags without updating this file,
`README.md`, and `MLXServer/README.md` together.

| Primary tag | Meaning | Can it drive OpenCode / Xcode / Claude Code? |
|---|---|---|
| `Agent` | tool calling validated through mlx_lm.server's Qwen parser | **Yes — only these** |
| `Code` | strong code generation, but tool calling not validated here | No — chat / refactor only |
| `Chat` | general assistant / generation | No |
| `Reasoning` | extended reasoning / thinking | No |
| `Pentesting` | security / offensive chat | No — chat only |
| `Uncensored` | reduced-refusal (safety training removed) | No — chat only, no shell/network/secrets |

Modifier tags (add after the primary tag when true): `OptiQ` (requires the
`mlx-optiq` runtime), `Distill` (community distill, oQe quant). There is **no
`Vision` tag** — image input isn't served (see below).

**The agent-capable set is exactly the Qwen3 family — 7 models** (the only ones
with `agentNote == nil`):

| repoID | weightGB | maxContext | thinking |
|---|---|---|---|
| `mlx-community/Qwen3.5-35B-A3B-4bit` | 18 | 262144 | yes |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | 18 | 262144 | yes |
| `mlx-community/Qwen3.8-27B-4bit` | 14 | 262144 | yes |
| `mlx-community/Qwen3-14B-4bit` | 7 | 40960 | yes |
| `mlx-community/Qwen3.5-9B-4bit` | 6 | 262144 | yes |
| `mlx-community/Qwen3.5-4B-4bit` | 3.03 | 262144 | yes |
| `mlx-community/Qwen3.5-2B-4bit` | 1.72 | 262144 | yes |

Do **not** switch to `Qwen3-Coder-30B-A3B`, `Qwen3-Coder-Next`, or
`Qwen2.5-Coder-7B` for agents — they emit tool calls the server can't parse and
stall the loop. Every non-agent model carries a non-nil `agentNote` explaining
why; `agentNote == nil` is reserved for the 7 validated agent models above.

OptiQ models (`Qwen3.8-27B-{Uncensored,OBLITERATED}-OptiQ-4bit`) and all
reduced-refusal/uncensored models are chat-only: tool calling is declared but
not validated, so they get no shell/network/secrets access.

**No model serves image input — every model is text-only.** `mlx_lm.server`'s
image-processor registry (`mlx_lm/processors/__init__.py` → `PROCESSORS`) only
implements `muse_spark`, so `load_processor()` returns `None` for every model here,
`keep_images` is `False`, and an `image_url` content part raises
`ValueError("Only 'text' content type is supported.")`. Several models declare a
`vision_config` and carry vision-tower weights, but that is *latent* — it does not
work end-to-end through mlx-lm today. Do **not** label any model `Vision`, and keep
the OpenCode config text-only (`modalities` / `attachment` in `opencode.jsonc`). If
mlx-lm later gains image processors for `qwen3_5` / `gemma4` / `mistral3`, revisit.

### How to add a model (do all of these, or the picker lies to users)

1. Add one `ModelOption` to `ServerController.availableModels`.
2. Set `profile` correctly:
   - `maxContext` = the model's `max_position_embeddings`.
   - `thinkingSupported` = whether its chat template accepts `enable_thinking`.
   - `weightGB` = **decimal GB = safetensors bytes ÷ 1e9**. Do **not** use the HF
     `safetensors.total` field (unreliable — it under-reports). Read real file sizes
     from `GET https://huggingface.co/api/models/{repo}/tree/main`.
   - `rotatingKVCache: true` for Gemma 4 / Ministral 3 / Llama 3.2 / GPT-OSS
     (they have no quantized KV form, so `--kv-bits` must be skipped).
   - `requiresOptiQ: true` for OptiQ-quantized models.
3. Classify: first `highlight` = one of the six primary tags. Do **not** add a
   `Vision` tag — image input isn't served (see above). Add `Distill` / `OptiQ` as
   applicable.
4. Set a non-nil `agentNote` for **every** model that isn't a validated Qwen3-family
   agent — one sentence on what it's for and why agent work isn't validated.
5. Keep `summary` to one sentence stating the capability. `summary` and the first
   `highlight` (the primary tag) are the model's **description + tag**, surfaced in
   *both* the macOS app and the CLI picker — the two must stay in sync (step 6).
6. Mirror the model into `setup.sh` (**all 7 parallel arrays**: `MODELS_REPO`,
   `MODELS_NAME`, `MODELS_CTX`, `MODELS_WGT`, `MODELS_THINK`, **`MODELS_TAG`** =
   `highlights[0]`, **`MODELS_DESC`** = `summary`), `start_server.sh`
   (`THINKING_MODELS`; `OPTIQ_MODELS` or the rotating-KV list as needed), and the
   `README.md` model table (keep its "Agent" column accurate). The description and
   tags are a **standard, non-optional step** — a model added to the app but not to
   `MODELS_TAG` / `MODELS_DESC` shows up in the CLI with no tag or description.

## Critical invariants (do not violate)

- **Memory safety / whole-machine OOM.** The 35B model combined with "Allow
  concurrent requests" (full-precision KV cache, no byte cap) can exhaust the
  *entire Mac's* unified memory and take the whole machine down — not just the
  server. The app
  enforces this in `ServerController`: `concurrentRequestsSafe` requires
  `model.weightGB <= physicalRAMGB / 4`; `start()` hard-blocks otherwise, the
  toggle is disabled for too-large models, and launching auto-clamps the setting.
  Keep this guard intact.
- **KV-cache quantization is load-bearing.** The 35B needs `--kv-bits 4`
  (+ `--max-tokens 8192`) to fit in unified memory. Full-precision KV OOMs on
  long agent prompts.
- **LiteLLM lives in its own venv** (`.venv-litellm`): it pins `tokenizers==0.22.2`
  while mlx-lm's transformers needs `>=0.23.1`.
- **Ports.** MLX server = `8080`; LiteLLM bridge = `4001` (NOT 4000 — that's
  commonly taken by another LiteLLM instance).
- **Thinking mode stays off by default** (and that's fine). mlx-lm ≥ 0.32 keeps
  the answer clean when thinking is on — it emits the reasoning in a separate
  `reasoning` field, not inline — so OpenCode (reads `reasoning`/`reasoning_content`
  directly) and Claude Code (LiteLLM maps `reasoning` → `reasoning_content`) both
  still get a clean answer. It just costs extra reasoning tokens per turn, so keep
  it off unless you want the longer reasoning pass.
- **OpenCode `limit.output` must match the server's max tokens** (8192). OpenCode
  otherwise hard-codes 32000 and can wedge the single generation thread.
- **Sampling params matter.** `mlx_lm.server` ignores `generation_config.json` and
  defaults to greedy decoding with no repetition penalty → repetition loops. The
  scripts/app set `--temp 0.2 --top-p 0.8 --top-k 20`.
- **Prompt cache must be sized ~2× the system prompt** (`--prompt-cache-bytes`,
  Model settings). Claude Code's ~85k-token system prompt quantizes to ~6 GB,
  which fills the 6 GB default and defeats caching (`system: 0 sequences`). See
  [Agent recommendations](#agent-recommendations-which-agent-for-which-job).
- **Every release ships the Gatekeeper unblock.** The `.app` is ad-hoc signed
  only (no Apple Developer ID, not notarized), so a downloaded copy is blocked on
  first launch. **Every** release — no exceptions — must include the one-line
  unblock in **both** the GitHub release notes and the README's "Use the menu-bar
  app" section:

      /usr/bin/xattr -cr /Applications/MLXServer.app

  Use the full `/usr/bin/xattr` path — Anaconda's `xattr` (when it shadows on
  `PATH`) has no `-r` flag and fails with "option -r not recognized". See
  [Build & release](#build--release).
- **Every release ships the one-line installer.** `install.sh` on `main` fetches
  the latest release dynamically (no version hardcoded), so the Gatekeeper-free
  install path is version-agnostic and never needs a version bump. **Every**
  release — no exceptions — must keep the README and the GitHub release notes
  pointing at this one-liner, and must keep `install.sh` at the repo root on the
  default branch:

      curl -fsSL https://raw.githubusercontent.com/spyroskotsakis/mac-mlx-agent/main/install.sh | bash

  Never rename/move `install.sh` or change the default branch without updating
  every place this URL is referenced.
- **No Claude Code / AI-assistant attribution anywhere.** This project is
  human-authored and carries **no** Claude Code attribution — not in files, the
  README, the CHANGELOG, GitHub release notes, **and not in git commit messages**.
  Never add:
    - a `Co-Authored-By: Claude Code <…>` trailer to a commit,
    - a `🤖 Generated with [Claude Code](…)` footer to release notes or docs,
    - or any other AI-assistant generation/attribution line.
  If one slips in, strip it from every file, commit, and release that has it.
  (This forbids *attribution markers* only: the words "Claude Code" still appear
  throughout as the name of a supported agent — that's a product reference, not
  attribution, and stays.)

## Agent recommendations (which agent for which job)

The local model can drive several agents, but they are **not interchangeable**:
their prompt sizes differ by ~10×, which decides speed and whether the prompt
cache works at all.

| Agent | Prompt / turn | Speed (35B, Apple Silicon) | Verdict |
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

### First-launch Gatekeeper note (required in every release)

The `.app` is **ad-hoc signed only** — no Apple Developer ID, not notarized — so a
downloaded copy is blocked on first launch by macOS Gatekeeper (*"Apple could not
verify MLXServer is free of malware…"*). This is expected and **cannot be fixed in
code**: the browser stamps the downloaded zip with `com.apple.quarantine`, and only
an Apple Developer ID + notarization (a paid account) removes the block. So **every
release must ship the one-line unblock**, in *both* the GitHub release notes and the
README's "Use the menu-bar app" section:

    /usr/bin/xattr -cr /Applications/MLXServer.app

Use the full `/usr/bin/xattr` path — Anaconda's `xattr` (when it shadows on `PATH`)
has no `-r` flag and fails with "option -r not recognized". Clearing
`com.apple.quarantine` once per downloaded copy is all that's needed; a locally
built `.app` carries no quarantine flag and opens without this step.

### One-line installer (required in every release)

Every release must also ship the **one-line installer** — the Gatekeeper-free
install path. It works because `curl` + `ditto` don't stamp `com.apple.quarantine`
(unlike a browser download), so the app opens with no `xattr` step at all.
`install.sh` fetches the *latest* release via the GitHub API, so this URL is
version-agnostic and never needs a version bump:

    curl -fsSL https://raw.githubusercontent.com/spyroskotsakis/mac-mlx-agent/main/install.sh | bash

Keep `install.sh` at the repo root on the default branch (`main`); the release
notes must include this one-liner alongside the Gatekeeper unblock above.

## Key endpoints (when running)

- `GET  http://127.0.0.1:8080/v1/models` — server health / cached models.
- `POST http://127.0.0.1:8080/v1/chat/completions` — OpenAI chat + tool calling.
- `POST http://127.0.0.1:4001/v1/messages` — LiteLLM bridge (Anthropic API for Claude Code).
