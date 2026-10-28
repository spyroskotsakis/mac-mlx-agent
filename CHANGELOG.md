# Changelog

All notable changes to this project are documented here, grouped by release.
Versions follow [Semantic Versioning](https://semver.org) (`MAJOR.MINOR.PATCH`).
The version is bumped in `MLXServer/MLXServer.xcodeproj` (`MARKETING_VERSION`) and
tagged in git (`vX.Y.Z`); each tag has a matching GitHub release with the built
app attached.

## [Unreleased]

(nothing yet — work in progress goes here before the next release.)

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

[1.1.1]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.1.1
[1.1.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.1.0
[1.0.0]: https://github.com/spyroskotsakis/mac-mlx-agent/releases/tag/v1.0.0
