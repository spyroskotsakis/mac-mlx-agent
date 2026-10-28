#!/usr/bin/env bash
# Launch Claude Code pointed at the local MLX model via the LiteLLM bridge.
#
# Prerequisites (both must be running):
#   ./start_server.sh                        # MLX-LM server on 8080 (or start it
#                                            # from the MLX Server menu-bar app —
#                                            # same 8080 endpoint)
#   .venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port 4001
#
# Port 4001 (not 4000): port 4000 is used by a separate LiteLLM instance
# (~/Coding-Agent-Infra/litellm). Keep this bridge on its own port so the two
# never collide.
#
# Usage: ./claude-local.sh [claude args...]
set -euo pipefail

export ANTHROPIC_BASE_URL=http://127.0.0.1:4001
export ANTHROPIC_AUTH_TOKEN=sk-local-claude
export ANTHROPIC_MODEL=default_model
export ANTHROPIC_DEFAULT_HAIKU_MODEL=default_model
export ANTHROPIC_DEFAULT_SONNET_MODEL=default_model
export ANTHROPIC_DEFAULT_OPUS_MODEL=default_model
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
# Claude Code's own thinking budget for the request — separate from the model's
# thinking mode, which is controlled server-side by the app / start_server.sh
# (`enable_thinking`). Keep 0 here; local-model reasoning comes from that flag.
export MAX_THINKING_TOKENS=0

exec claude "$@"
