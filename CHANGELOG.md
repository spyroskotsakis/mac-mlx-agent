# Changelog

All notable changes to this project are documented here, grouped by release.
Versions follow [Semantic Versioning](https://semver.org) (`MAJOR.MINOR.PATCH`).
The version is bumped in `MLXServer/MLXServer.xcodeproj` (`MARKETING_VERSION`) and
tagged in git (`vX.Y.Z`); each tag has a matching GitHub release with the built
app attached.

## [1.13.0] — 2026-10-30

### Fixed

- **Model downloads no longer stall on the Xet backend.** `hf_transfer` is a
  no-op in `huggingface_hub` 2.3, and `hf_xet`'s replacement — the Xet CAS path —
  hangs on anonymous downloads: its `get_reconstruction` calls to
  `cas-server.xethub.hf.co` connect but never return data, so the 45s watchdog
  killed every attempt at 0 bytes. The app, `setup.sh`, and `start_server.sh` now
  set `HF_HUB_DISABLE_XET=1`, which makes `hf download` fall back to the classic
  LFS path (verified ~2–3 MB/s sustained, resuming cleanly).

- **Clearer first-run Gatekeeper note.** A downloaded build is ad-hoc signed (no
  Apple Developer ID), so macOS blocks it with *“cannot verify … may harm your
  Mac.”* The README now leads with the reliable unblock
  (`xattr -cr /Applications/MLXServer.app`) instead of right-click → Open, which
  macOS usually doesn't offer for ad-hoc builds.

- **OpenCode no longer crashes the server on image attachments.** When OpenCode's
  build agent read an image (or attached a screenshot), the MLX server returned
  `{"error": "Only 'text' content type is supported."}` (HTTP 404) and wedged the
  session. mlx_lm.server loads a vision processor for none of these models, so any
  image content is rejected. The OpenCode config the app and `setup.sh` write now
  marks the model text-only (`modalities: { input: ["text"], output: ["text"] }`,
  `attachment: false`) so OpenCode never attaches images in the first place.

## [1.12.0] — 2026-10-30

### Fixed

- **Deleting a model now removes the actual weights.** The Delete and Delete-all
  buttons used to remove only the small per-repo files and leave the multi-GB
  weights orphaned in huggingface_hub's shared blob store. They now go through
  `scan_cache_dir` + `delete_revisions`, which deletes the repo folder *and*
  sweeps the orphaned weights. The "freed X" figure (and the Delete-all
  confirmation) now reports the real GB-scale size, not a ~1000× undercount.

- **Gemma 4 / Ministral 3 / Llama 3.2 no longer crash on the first request.**
  These models use mlx_lm's sliding-window `RotatingKVCache`, which has no
  quantized form, so passing `--kv-bits 4` raised
  `NotImplementedError: RotatingKVCache Quantization NYI`. The app (and
  `start_server.sh`) now skip `--kv-bits` for those six models and run them with
  a full-precision KV cache.

- **Large model downloads no longer stall on the multi-GB weights.** Anonymous HF
  downloads could fetch the small files instantly and then make zero progress on
  `model.safetensors`, tripping the 45s stall watchdog and burning through all
  five auto-retries. Downloads now run through `hf_transfer` (the fast Rust
  downloader) when it's installed.

### Added

- **`hf_transfer` is now a prerequisite.** The app installs it alongside mlx-lm /
  `hf`, checks for it in Requirements, and shows a setup-guide step with install
  instructions when it's missing. `setup.sh` does the same.

- **Single-instance guard.** Launching the app twice now focuses the existing
  window instead of spawning a duplicate process (`main.swift` + `flock`).

- **"Delete all models" button.** Clears every cached model (weights included) in
  one step, with a confirmation showing the total on-disk size.

### Changed

- **Terminal path matches the app.** `setup.sh` and `start_server.sh` now install
  and enable `hf_transfer`, and `start_server.sh` skips `--kv-bits` for the six
  rotating-KV-cache models — the same behavior as the menu-bar app.

## [1.11.0] — 2026-10-30

### Added

- **Automatic download retry with a countdown.** When a model download fails or
  stalls (e.g. the internet drops mid-download), the app now retries on its own —
  up to 5 attempts, with a 5-second countdown shown in the panel and a
  **Retry now** button to skip the wait. `hf download` resumes from the bytes
  already on disk, so each attempt continues rather than restarting from zero.

### Fixed

- **A hung download no longer leaves the app stuck.** `hf download` can hang
  indefinitely when a connection drops (no new bytes, `isInstalling` stuck true,
  and the retry button disabled). The progress poll now detects a stalled
  download (45s with no new bytes), kills the hung process, and hands it to the
  retry logic instead of waiting forever.

## [1.10.0] — 2026-10-30

### Added

- **Agent capability flag + warning per model.** Each model now carries a
  `toolCallingSupported` flag: only the Qwen3-family models reliably emit
  parseable tool calls, so they're the ones that can drive OpenCode / Claude Code.
  Selecting a chat/generation model (Llama, Gemma, Ministral, Devstral,
  Qwen2.5-Coder) now shows a clear warning that it will emit broken tool calls
  (raw JSON like `{ "name": …, "parameters": {} }` instead of an answer) and
  points you at the Qwen models.

### Fixed

- **Stale-server reclamation no longer runs mid-generation.** `onAppear()` used to
  sweep for leftover `mlx_lm.server`/LiteLLM processes every time the panel opened,
  even while a request was in flight — logging `[Stopping N stale …]` lines in the
  middle of a generation and risking the live server. The sweep now only runs when
  the server is stopped/failed; `start()` still reclaims before it launches.

### Changed

- **Docs** — the model tables now include a "Tool calling" column, and the agent
  guidance is explicit that only the Qwen3-family models work for agent use.

## [1.9.2] — 2026-10-30

### Fixed

- **Model downloads could crash on machines with a stale `Brotli`.** `huggingface_hub`
  2.x now uses `httpx2`, whose Brotli decoder requires `brotli>=1.2.0`; with an older
  `brotli` (e.g. Anaconda's 1.1.0) the download died with
  `TypeError: process() takes no keyword arguments`. The app now pins `brotli>=1.2.0`
  in every install path (mlx-lm and `hf`), and `setup.sh` does the same.
- **False "mlx-lm (broken) — dependency conflict" warning.** The health check ran
  `mlx_lm.server --help` once at launch; a single transient failure (right after a
  stale server was reclaimed) flipped the Requirements row to "broken" until
  "Check status" re-ran it. The check now retries (3 attempts) before declaring the
  install broken.

## [1.9.1] — 2026-10-30

### Fixed

- **Launch crash** — `findPython()` referenced `ServerController.shared` during
  the singleton's own initialization, which re-entered the one-time initializer
  and aborted at startup (`BUG IN CLIENT OF LIBDISPATCH: trying to lock
  recursively`). Python is now resolved with the executable override passed in,
  so the app launches cleanly.

## [1.9.0] — 2026-10-30

### Added

- **Python 3 is now a first-class prerequisite** — detected on launch, listed in
  the Requirements list and the startup checklist, with a "How to install Python"
  fold-out (`xcode-select --install`, Homebrew, or python.org).
- **Guided "Missing prerequisites" checklist** at the top of the panel — every
  missing item shows a one-line fix and points at the one-click button / install
  instructions that resolve it. The Claude Code and LiteLLM items are marked
  optional, since OpenCode alone is enough to start.
- **Confirmation before auto-install / auto-config** — installing mlx-lm, `hf`,
  or LiteLLM, and writing the OpenCode / Claude Code / LiteLLM configs, now asks
  first (and warns when a config file is about to be overwritten, with the
  existing file backed up). Nothing touches the Python env or a config silently.
- **Manual steps for risky operations** — a "How to install mlx-lm manually"
  command and a Manual (copyable) view for the LiteLLM config, matching the
  existing OpenCode and Claude Code manual views.

### Changed

- **Dependency docs** — `README.md` and `MLXServer/README.md` now list the full
  requirement set (manual vs auto-installed) and clarify that Node.js is not a
  direct requirement and that no Hugging Face account is needed for the public
  `mlx-community` models.

## [1.8.0] — 2026-10-30

### Added

- **Eleven more models (15 total)** — Ministral 3 (8B / 3B), Gemma 4 (12B QAT /
  E4B / E2B), Llama 3.2 3B, Devstral Small 2 24B, Qwen3.5 9B / 4B / 2B, and
  Qwen2.5-Coder 7B. Each carries its real 4-bit weight size (which drives the
  memory-safety guard) and its max context, read from the Hugging Face config.
- **Per-model description** — selecting a model now shows a one-line summary,
  what it's good at, hashtag-style highlights, and a "View on Hugging Face" link.
- **Thinking guard for non-thinking models** — models whose chat template has no
  thinking step (Coder, Ministral, Gemma, Llama, Devstral) now force the
  Thinking toggle off, disable it, and warn the user (plus a system notification
  when a previous model had it on). The `enable_thinking` flag is only passed to
  models that accept it.

### Changed

- **Terminal path matches the app** — `setup.sh` now offers all 15 models (and
  shows whether each supports thinking), and `start_server.sh` only passes the
  `enable_thinking` flag to Qwen-family models. `README.md` gained the full model
  table and clearer Xcode (ACP) setup steps.

### Models (complete list)

| Model | 4-bit weight | Max context | Thinking |
| --- | --- | --- | --- |
| Qwen3.5-35B-A3B | 18 GB | 262,144 | ✅ |
| Qwen3.6-35B-A3B | 18 GB | 262,144 | ✅ |
| Qwen3.8-27B | 14 GB | 262,144 | ✅ |
| Qwen3-14B | 7 GB | 40,960 | ✅ |
| Qwen3.5-9B | 6 GB | 262,144 | ✅ |
| Qwen2.5-Coder-7B-Instruct | 4.28 GB | 32,768 | — |
| Qwen3.5-4B | 3.03 GB | 262,144 | ✅ |
| Qwen3.5-2B | 1.72 GB | 262,144 | ✅ |
| Devstral Small 2 24B Instruct | 15.10 GB | 393,216 | — |
| Gemma 4 12B IT QAT | 10.99 GB | 262,144 | — |
| Ministral 3 8B Instruct | 5.60 GB | 262,144 | — |
| Gemma 4 E4B Instruct | 5.15 GB | 131,072 | — |
| Gemma 4 E2B Instruct | 3.55 GB | 131,072 | — |
| Ministral 3 3B Instruct | 2.75 GB | 262,144 | — |
| Llama 3.2 3B Instruct | 1.81 GB | 131,072 | — |

Thinking mode is a Qwen-family feature; the other models are for chat and
generation. For agent/tool-calling work, stick with the Qwen models.

## [1.7.1] — 2026-10-29

### Fixed

- **Panel opens instantly** — the OpenCode / Claude Code / LiteLLM detection
  checks (which run `claude --version`, `litellm --version`, and login-shell
  `command -v` lookups) no longer block the main thread when the menu-bar panel
  opens. They now probe in the background with a one-at-a-time guard, so the
  window appears immediately and the status lines fill in a moment later.

## [1.7.0] — 2026-10-29

### Added

- **Version number in the header** — the panel header now shows the running
  version (e.g. `v1.6.0`) as a badge, alongside the existing footer line.
- **Update checker** — the app polls the GitHub release feed on launch (and every
  few hours while it stays open) and posts a system notification when a newer
  release is out; the panel shows an "Update available" banner with a "View
  release" button, plus a manual "Check for updates" control.

### Fixed

- **Thinking mode no longer breaks agents.** With mlx-lm ≥ 0.32, enabling
  thinking emits the reasoning in a separate `reasoning` field (not an inline
  `<think>…</think>` preamble), so the answer stays clean and both OpenCode
  (reads `reasoning`/`reasoning_content`) and Claude Code (LiteLLM maps
  `reasoning` → `reasoning_content`) still work. The toggle stays **off by
  default** — it's now just slower, not broken. Updated the in-app warning and
  docs to match.

## [1.6.0] — 2026-10-29

### Added

- **One-command terminal setup** — `setup.sh` checks every prerequisite, installs
  whatever is missing, and downloads + configures a model through an interactive
  picker (the shell equivalent of the app's Install buttons + model picker).
- **`hf` (Hugging Face CLI) prerequisite** — detected at startup, with an in-app
  Install button and manual instructions, so `hf download` works for the CLI path.
- **RAM-adaptive warnings** — the Thinking-mode and Max-tokens warnings now scale
  from the Mac's actual RAM rather than a fixed number.
- **Reset to defaults** — one button restores model, sampling, KV-cache, and
  concurrency settings.
- **Stale-server reclamation** — launching or opening the app, or pressing Start,
  now kills any leftover `mlx_lm.server`/LiteLLM bridge on *any* port (matched by
  command line, not port), so instances never pile up and compete for memory.

### Changed

- **De-hardcoded** — removed machine-specific 36 GB / M4 Max / macOS version
  references from the docs and app so the project is generic for any Apple Silicon
  Mac.
- **Generic bundle identifier** — `com.mlxserver.MLXServer`.
- **Open-source release** — added the MIT license and removed test projects.

## [1.5.0] — 2026-10-28

### Known issue

- **Claude Code is crashing on the local model** (empty replies, stalled turns,
  and it can wedge the server's single generation thread). **Use OpenCode for
  local agent work for now**; we'll flag it when Claude Code is usable again.

### Fixed

- **Out-of-memory crash on concurrent agents.** `mlx_lm.server` defaults to
  batching up to 8 prompts in parallel, so Claude Code's large system prompt +
  a second agent (OpenCode) at the same time exhausted Metal RAM and killed the
  generation thread (`[METAL] Insufficient Memory` → `generation thread died`).
  The app now forces `--prompt-concurrency 1 --decode-concurrency 1` when
  concurrent requests are off, so requests are served one at a time.
- **Prompt cache growth** is now capped (`--prompt-cache-bytes 6GB`), so a long
  session can't accumulate 10 full-precision KV caches and OOM on its own.
- **"Allow concurrent requests" now warns clearly** that it disables the
  quantized KV cache and will OOM on a 35B model.

### Added

- **Out-of-memory detection** — the app watches the server log for
  `Insufficient Memory` / `generation thread died` and shows a restart prompt
  instead of silently hanging on "Generating…".
- **Log Copy / Download buttons** — the Server log now has Copy (clipboard) and
  Download (save to a `.log` file) actions for sharing logs.
- **Thinking-mode warning** — the Thinking toggle now warns that the hidden
  reasoning step is emitted instead of the answer, so it stalls agents (Claude
  Code / OpenCode) and can leave the reply empty. Leave it off for coding agents.
- **Prompt-cache size setting** — `--prompt-cache-bytes` is now adjustable in
  Model settings (default 6 GB). Claude Code's ~85k-token system prompt needs
  ~6 GB of KV cache on its own, which fills the default and defeats caching
  (`system: 0 sequences`); raise it, or trim MCP servers/skills.
- **Agent recommendations** — documented which agent works best for which job
  (OpenCode vs Claude Code) and why Claude Code's large system prompt is slow.

## [1.4.1] — 2026-10-28

### Fixed

- **LiteLLM now installs into its own venv** (`~/.config/mlx-local/.venv-litellm`)
  instead of the mlx-lm environment. litellm pins `tokenizers==0.22.2` while
  mlx-lm's transformers needs `>=0.23.1`, so sharing an environment breaks
  `mlx_lm.server` with an `ImportError` on `huggingface_hub`. This no longer
  happens on any machine.

### Added

- **mlx-lm health check** — the app now runs `mlx_lm.server --help` to confirm the
  install actually imports, and flags a broken install as "dependency conflict"
  with a Repair button instead of failing at start time.

## [1.4.0] — 2026-10-28

### Added

- **LiteLLM dependency check**: the app now verifies `litellm` actually runs (via
  `litellm --version`), so a partial install that's missing its proxy extras is
  reported as "broken" instead of silently failing to start the bridge.
- **LiteLLM install instructions** and a Repair button for the broken case; the
  one-click installer now installs `litellm[proxy]` (which pulls in `boto3` and
  the other proxy runtime deps) rather than bare `litellm`.
- **Two-column layout** for the Server tab, so unfolding the setup fold-outs no
  longer pushes the log and footer off-screen.

### Fixed

- Removed `use_chat_completions_api` from the bridge config — it is rejected by
  current LiteLLM and caused every Claude Code request to fail with a 500 before
  the bridge could even reach the MLX server.

## [1.3.0] — 2026-10-28

### Added

- **Configurable ports**: both the MLX server port and the LiteLLM bridge port are
  now editable in Advanced (instead of hardcoded 8080 / 4001), and the bridge
  config, the Claude Code env profile, and the "How to start" commands all follow
  the configured values.
- **Pre-start port-conflict warning**: the app checks both ports before starting
  (and whenever either is changed) and warns in Advanced if another process is
  already listening, pointing the user to change the port.

### Changed

- Stopping the app now also frees the configured bridge port (not just 4001).

## [1.2.0] — 2026-10-28

### Added

- **LiteLLM bridge setup** for Claude Code: the app now checks `litellm`, can
  install it, and writes `~/.config/mlx-local/litellm-mlx.yaml` — so a user with
  only the downloaded `.app` (no repo clone) still gets a working bridge config.
- **"How to start Claude Code"** fold-out with the exact three commands (MLX
  server → LiteLLM bridge → `claude`), using app-written paths instead of repo
  paths.

### Changed

- Claude Code status now distinguishes *installed and runnable* (runs
  `claude --version`) from *installed but broken* (a shim without its native
  binary), with a reinstall hint for the broken case.
- Readiness now also requires `litellm` and the bridge config.

## [1.1.1] — 2026-10-28

### Fixed

- Claude Code detection now finds npm/nvm installs (the `bin/claude` shim exists
  even when its target isn't executable) and tries both bash and zsh when
  resolving CLIs, so an `~/.bash_profile`-based nvm setup is detected.

### Changed

- "Check status" readiness now also requires Claude Code and its bridge profile,
  and lists them in the missing-prerequisites line.

## [1.1.0] — 2026-10-28

### Added

- **Claude Code integration** — check the `claude` CLI (with fold-out install
  steps when missing) and set up a separate env profile
  (`~/.config/mlx-local/claude-code.env`) pointing Claude Code at the LiteLLM
  bridge, so `claude-local` / `claude-mlx` route to the local model as
  `default_model`.

## [1.0.0] — 2026-10-28

First tagged release of the **MLX Server** menu-bar app.

### Added

- Menu-bar app to start/stop `mlx_lm.server` with a live log and a state icon.
- Four models with per-model profiles: Qwen3.5-35B-A3B (default),
  Qwen3.6-35B-A3B, Qwen3.8-27B, and Qwen3-14B — each with its correct **max
  context** (262144 / 262144 / 262144 / 40960) and thinking support.
- Per-model **Thinking mode** toggle (default off), applied via
  `--chat-template-args '{"enable_thinking":…}'`.
- Model settings: temperature, top-p, top-k (with explainer info icons), and
  **Max tokens** as an editable field capped at the 32768 output ceiling shared
  by all Qwen3-family models.
- **Max context** display per model, read from its profile — the single source of
  truth for the per-model limit.
- **OpenCode setup**: automatic config writer (writes
  `~/.config/opencode/opencode.jsonc` with the right `limit.context` /
  `limit.output`) plus a manual view; when the `opencode` CLI is missing, a
  fold-out panel shows the install commands.
- **Connect** tab (base URL, endpoints, copyable `curl`/Python examples).
- Model download with live progress, plus delete-from-cache.
- Requirements check with one-click `mlx-lm` install, plus a **Check status**
  button that re-verifies every prerequisite and reports "ready to go" (or what's
  still missing).
- "Show in Finder" buttons for the config and model folders.
- Reset-to-defaults for model settings.
- Version + build number in the panel footer.

### Changed

- `start_server.sh` now matches the app: added the `enable_thinking` flag, the
  four-model list with per-model context, and the 32768 output-ceiling note.

[1.13.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.13.0
[1.12.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.12.0
[1.11.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.11.0
[1.10.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.10.0
[1.9.2]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.9.2
[1.9.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.9.1
[1.9.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.9.0
[1.8.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.8.0
[1.7.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.7.1
[1.7.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.7.0
[1.6.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.6.0
[1.5.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.5.0
[1.4.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.4.1
[1.4.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.4.0
[1.3.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.3.0
[1.2.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.2.0
[1.1.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.1.1
[1.1.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.1.0
[1.0.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.0.0
