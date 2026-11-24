# AGENTS.md

Agent-facing instructions for this repository. The full architecture map, model
list, and build/release procedure live in [`CLAUDE.md`](CLAUDE.md) — read it before
working here. This file restates the rules that must never be broken, for tooling
that reads `AGENTS.md` instead of `CLAUDE.md`.

## Hard rules

- **Only add MLX-compatible models.** A model may be added to the picker
  (`ServerController.availableModels` → `setup.sh` → `start_server.sh` →
  `README.md`) only if it is an MLX-format repo that `mlx_lm.server` (or the
  `mlx-optiq` runtime) actually loads: `mlx-community/*`-style `.safetensors`
  shards plus a `config.json` carrying an MLX `quantization` dict and a
  `model_type` mlx-lm supports. Never add a raw GGUF or Transformers/PyTorch-only
  model — it will not load and lies to users. Verify the repo
  (`GET https://huggingface.co/api/models/{repo}`) and its `config.json` before
  adding.

- **Every model is classified and mirrored.** Each model carries a primary
  capability tag (its first `highlight`) and a one-sentence `summary`; both must be
  mirrored into `setup.sh`'s `MODELS_TAG` / `MODELS_DESC` arrays and the `README.md`
  model table. See CLAUDE.md's "How to add a model".

- **Memory-safety guard stays intact.** A model with `weightGB > physicalRAMGB / 4`
  must not allow concurrent requests; the app hard-blocks this.

- **No duplicated backend code.** The MLX and oMLX paths share one
  implementation of common lifecycle logic — process-tree stop/exit
  confirmation, health polling, client-config writing, the memory guard, port
  checks — parameterized per backend, never copy-pasted into a second
  controller. A refactor to enable sharing is allowed only after a written
  analysis (duplication inventory, blast radius, behavior-preservation plan);
  never refactor without a demonstrated need.

- **No Claude Code / AI-assistant attribution anywhere** — not in files, docs,
  release notes, or git commit messages.

See [`CLAUDE.md`](CLAUDE.md) for the complete map: the tag vocabulary, the ports, and the release checklist.
