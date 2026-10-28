# Changelog

All notable changes to this project are documented here, grouped by release.
Versions follow [Semantic Versioning](https://semver.org) (`MAJOR.MINOR.PATCH`).
The version is bumped in `MLXServer/MLXServer.xcodeproj` (`MARKETING_VERSION`) and
tagged in git (`vX.Y.Z`); each tag has a matching GitHub release with the built
app attached.

## [Unreleased]

(nothing yet — work in progress goes here before the next release.)

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

[1.4.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.4.1
[1.4.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.4.0
[1.3.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.3.0
[1.2.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.2.0
[1.1.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.1.1
[1.1.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.1.0
[1.0.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.0.0
